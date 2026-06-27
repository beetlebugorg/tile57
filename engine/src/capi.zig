//! C ABI for libtile57.a — what the C++ MapLibre host links against.
//!
//! A source is one of two backends behind the same tile API:
//!   - TILE57_FORMAT_PMTILES:  a PMTiles archive (Zig reader)            [M5]
//!   - TILE57_FORMAT_S57_CELL: a raw S-57 cell, tiles generated live     [M6c]
//! TILE57_FORMAT_AUTO sniffs PMTiles first, then falls back to S-57. The C++
//! ChartTileSource doesn't care which — it just calls tile57_tile_get.
//!
//! Contract: POD across the seam (ptr/len + status codes); Zig errors, slices
//! and optionals stay inside Zig. Public header: ../../include/tile57.h.

const std = @import("std");
const pmtiles = @import("pmtiles.zig");
const s57 = @import("s57");
const s57_mvt = @import("s57_mvt.zig");
const portray = @import("portray.zig");
const bake_enc = @import("bake_enc.zig");
const catalogue = @import("s100").catalogue;
const tile = @import("tile.zig");

const gpa = std.heap.page_allocator;

// Env access lives in C (Zig 0.16 puts env behind Io); returns the S-101 rules
// dir from TILE57_S101_RULES or null.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

// Keep in sync with the TILE57_VERSION_* macros in tile57.h.
const version_string = "0.1.0";

// Mirrors tile57_format in tile57.h.
const Format = enum(c_int) { auto = 0, pmtiles = 1, s57_cell = 2 };

const CellBackend = struct {
    cell: s57.Cell,
    portrayal: ?[]?[]const u8 = null, // per-feature S-101 instruction stream
    portray_arena: ?*std.heap.ArenaAllocator = null,
};

// One cell in the lazy ENC_ROOT index: its owned bytes + cheap metadata (bbox +
// navigational band), parsed + portrayed ON DEMAND the first time a requested tile
// needs it, then kept until evicted by the LRU. Lets a host open the whole NOAA
// catalogue instantly and pay only for the cells under the current view.
const LazyCell = struct {
    base: []u8,
    updates: [][]u8,
    bbox: [4]f64, // [west, south, east, north]
    band: bake_enc.Band,
    cell: ?s57.Cell = null,
    portrayal: ?[]const ?[]const u8 = null,
    arena: ?*std.heap.ArenaAllocator = null,
    tick: u64 = 0, // LRU: last tile that used this cell
};

const LazySource = struct {
    cells: []LazyCell,
    rules_dir: []u8, // owned (lazy portrayal needs it after open returns)
    tick: u64 = 0,
    loaded: usize = 0,
    max_loaded: usize = 256, // LRU budget on parsed+portrayed cells (wide views)
};

const Backend = union(enum) {
    reader: pmtiles.Reader,
    cell: CellBackend,
    cells: LazySource, // ENC_ROOT: lazy spatial index, parsed/portrayed on demand
};

fn bboxOverlap(a_: [4]f64, b_: [4]f64) bool {
    return a_[0] <= b_[2] and a_[2] >= b_[0] and a_[1] <= b_[3] and a_[3] >= b_[1];
}

// Parse + portray a lazy cell if not already loaded, and stamp its LRU tick.
fn lazyEnsureLoaded(ls: *LazySource, lc: *LazyCell) void {
    ls.tick += 1;
    lc.tick = ls.tick;
    if (lc.cell != null) return;
    var cell = s57.parseCellWithUpdates(gpa, lc.base, lc.updates) catch return;
    if (gpa.create(std.heap.ArenaAllocator)) |p| {
        p.* = std.heap.ArenaAllocator.init(gpa);
        if (portray.portrayCell(p.allocator(), &cell, ls.rules_dir)) |res| {
            lc.portrayal = res;
            lc.arena = p;
        } else |_| {
            p.deinit();
            gpa.destroy(p);
        }
    } else |_| {}
    lc.cell = cell;
    ls.loaded += 1;
}

fn lazyUnload(lc: *LazyCell) void {
    if (lc.cell) |*c| c.deinit();
    lc.cell = null;
    lc.portrayal = null;
    if (lc.arena) |p| {
        p.deinit();
        gpa.destroy(p);
        lc.arena = null;
    }
}

// Evict least-recently-used loaded cells down to the budget, never touching cells
// used by the tile currently being generated (tick >= keep_from).
fn lazyEvict(ls: *LazySource, keep_from: u64) void {
    while (ls.loaded > ls.max_loaded) {
        var victim: ?*LazyCell = null;
        for (ls.cells) |*lc| {
            if (lc.cell == null or lc.tick >= keep_from) continue;
            if (victim == null or lc.tick < victim.?.tick) victim = lc;
        }
        if (victim) |v| {
            lazyUnload(v);
            ls.loaded -= 1;
        } else break;
    }
}

const Source = struct {
    backend: Backend,
    data: ?[]u8, // owned archive bytes (PMTiles backend only)
    // In-memory tile cache (key = z<<48|x<<24|y -> MVT bytes). The host renders
    // continuously and MapLibre re-requests tiles, so without this every frame
    // would re-decode (PMTiles) or re-generate (cell) the same tiles. Values are
    // owned here; tile57_tile_get returns a fresh copy the caller frees.
    cache: std.AutoHashMap(u64, []u8),
    cache_max: usize = 8192, // bound the in-memory tile cache (panning generates new tiles forever)
};

fn lazyFreeCell(lc: *LazyCell) void {
    lazyUnload(lc);
    gpa.free(lc.base);
    for (lc.updates) |u| gpa.free(u);
    if (lc.updates.len > 0) gpa.free(lc.updates);
}

// Parallel open worker: peek each cell's band + bbox and copy its bytes into a
// LazyCell. peekMeta + dupes use the (thread-safe) page allocator; cells with no
// geometry / unparseable headers are left ok=false and dropped.
const OpenWork = struct {
    inputs: []const CellInput,
    out: []LazyCell,
    ok: []bool,

    fn run(uptr: *anyopaque, i: usize) void {
        const c: *OpenWork = @ptrCast(@alignCast(uptr));
        const in = c.inputs[i];
        const meta = s57.peekMeta(gpa, in.base[0..in.base_len]) orelse return;
        const bbox = meta.bounds orelse return;
        const base = gpa.dupe(u8, in.base[0..in.base_len]) catch return;
        var ups: [][]u8 = &.{};
        const ucount: usize = if (in.updates != null and in.update_lens != null) in.update_count else 0;
        if (ucount > 0) {
            const arr = gpa.alloc([]u8, ucount) catch {
                gpa.free(base);
                return;
            };
            var k: usize = 0;
            while (k < ucount) : (k += 1) {
                arr[k] = gpa.dupe(u8, in.updates.?[k][0..in.update_lens.?[k]]) catch {
                    for (arr[0..k]) |u| gpa.free(u);
                    gpa.free(arr);
                    gpa.free(base);
                    return;
                };
            }
            ups = arr;
        }
        c.out[i] = .{ .base = base, .updates = ups, .bbox = bbox, .band = bake_enc.bandOf(meta.cscl) };
        c.ok[i] = true;
    }
};

fn tileKey(z: u8, x: u32, y: u32) u64 {
    return (@as(u64, z) << 48) | (@as(u64, x) << 24) | @as(u64, y);
}

/// Return the library version string ("0.1.0").
export fn tile57_version() callconv(.c) [*:0]const u8 {
    return version_string;
}

// Open a PMTiles archive from owned bytes (takes ownership on success, frees on
// failure). Returns null if the bytes are not a valid PMTiles archive.
fn openPmtiles(copy: []u8) ?*Source {
    const reader = pmtiles.Reader.init(gpa, copy) catch {
        gpa.free(copy);
        return null;
    };
    const src = gpa.create(Source) catch {
        var r = reader;
        r.deinit();
        gpa.free(copy);
        return null;
    };
    src.* = .{ .backend = .{ .reader = reader }, .data = copy, .cache = std.AutoHashMap(u64, []u8).init(gpa) };
    return src;
}

// Resolve the S-101 rules directory: explicit argument, else
// TILE57_S101_RULES, else the vendored official catalogue (works when run
// from the repo root).
fn resolveRulesDir(rules_dir: ?[*:0]const u8) []const u8 {
    if (rules_dir) |d| return std.mem.span(d);
    if (tg_env_rules()) |dirz| return std.mem.span(dirz);
    return "vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules";
}

// Parse (+ apply S-57 updates) + portray one cell into a CellBackend (no Source
// wrapper). Reads the bytes but does not take ownership (the cell model copies
// what it keeps). Returns null if the base bytes are not a valid cell. Portrayal
// failure is non-fatal (the tile generator falls back to classify()).
fn buildCellBackend(base: []const u8, updates: []const []const u8, dir: []const u8) ?CellBackend {
    const cell = s57.parseCellWithUpdates(gpa, base, updates) catch return null;
    var cb = CellBackend{ .cell = cell };
    const pa = gpa.create(std.heap.ArenaAllocator) catch return cb;
    pa.* = std.heap.ArenaAllocator.init(gpa);
    if (portray.portrayCell(pa.allocator(), &cb.cell, dir)) |res| {
        cb.portrayal = res;
        cb.portray_arena = pa;
    } else |_| {
        pa.deinit();
        gpa.destroy(pa);
    }
    return cb;
}

fn freeCellBackend(cb: *CellBackend) void {
    cb.cell.deinit();
    if (cb.portray_arena) |pa| {
        pa.deinit();
        gpa.destroy(pa);
    }
}

// Open a single raw S-57 cell. Returns null if the bytes are not a valid cell.
fn openCell(bytes: []const u8, rules_dir: ?[*:0]const u8) ?*Source {
    var cb = buildCellBackend(bytes, &.{}, resolveRulesDir(rules_dir)) orelse return null;
    const src = gpa.create(Source) catch {
        freeCellBackend(&cb);
        return null;
    };
    src.* = .{ .backend = .{ .cell = cb }, .data = null, .cache = std.AutoHashMap(u64, []u8).init(gpa) };
    return src;
}

// One ENC cell's bytes: the base .000 plus its sequential update files (.001…).
// Mirrors tile57_cell_input in tile57.h.
const CellInput = extern struct {
    base: [*]const u8,
    base_len: usize,
    updates: ?[*]const [*]const u8,
    update_lens: ?[*]const usize,
    update_count: usize,
};

/// Open an ENC_ROOT as a multi-cell source: each input is a base cell (plus, in a
/// later step, its updates). The cells are overlaid when a tile is generated.
/// The host scans the directory and reads the files (it owns file IO); this just
/// parses + portrays each cell. Returns null if no cell parses.
export fn tile57_source_open_cells(
    cells_ptr: [*]const CellInput,
    count: usize,
    rules_dir: ?[*:0]const u8,
) callconv(.c) ?*Source {
    if (count == 0) return null;
    const dir = resolveRulesDir(rules_dir);
    const dir_copy = gpa.dupe(u8, dir) catch return null;
    const inputs = cells_ptr[0..count];

    // Build the spatial index in parallel: peek each cell's band + bbox and copy
    // its bytes. No geometry assembly, no portrayal — that happens lazily per tile.
    const tmp = gpa.alloc(LazyCell, count) catch {
        gpa.free(dir_copy);
        return null;
    };
    defer gpa.free(tmp);
    const ok = gpa.alloc(bool, count) catch {
        gpa.free(dir_copy);
        return null;
    };
    defer gpa.free(ok);
    @memset(ok, false);

    var ow = OpenWork{ .inputs = inputs, .out = tmp, .ok = ok };
    bake_enc.parallelFor(count, &ow, OpenWork.run);

    var valid: usize = 0;
    for (ok) |k| {
        if (k) valid += 1;
    }
    if (valid == 0) {
        gpa.free(dir_copy);
        return null;
    }

    const cells = gpa.alloc(LazyCell, valid) catch {
        for (tmp, ok) |*lc, k| if (k) lazyFreeCell(lc);
        gpa.free(dir_copy);
        return null;
    };
    var j: usize = 0;
    for (tmp, ok) |lc, k| if (k) {
        cells[j] = lc;
        j += 1;
    };

    const src = gpa.create(Source) catch {
        for (cells) |*lc| lazyFreeCell(lc);
        gpa.free(cells);
        gpa.free(dir_copy);
        return null;
    };
    src.* = .{
        .backend = .{ .cells = .{ .cells = cells, .rules_dir = dir_copy } },
        .data = null,
        .cache = std.AutoHashMap(u64, []u8).init(gpa),
    };
    return src;
}

// Progress callback for tile57_bake_cells: stage 0 = loading/portraying cells,
// stage 1 = baking tiles. Matches bake_enc.Progress + the header typedef.
const BakeProgress = ?*const fn (user: ?*anyopaque, stage: u8, done: usize, total: usize) callconv(.c) void;

// One cell's bytes for the parallel bake worker — base + update slices into the
// host's buffers (valid for the whole tile57_bake_cells call).
const BakeSource = struct { base: []const u8, updates: []const []const u8 };

// Parallel parse+portray worker. Each index is independent: a fresh cell + its own
// portrayal arena + a per-thread Lua state (portray.zig g_ctx is thread-local).
// Uses the page allocator (thread-safe); the catalogue is warmed before the loop.
const BakeWork = struct {
    sources: []const BakeSource,
    outs: []?bake_enc.Backend,
    arenas: []?*std.heap.ArenaAllocator,
    rules_dir: []const u8,
    build_geo: bool,

    fn run(uptr: *anyopaque, i: usize) void {
        const c: *BakeWork = @ptrCast(@alignCast(uptr));
        const src = c.sources[i];
        var cell = s57.parseCellWithUpdates(gpa, src.base, src.updates) catch return;
        const b = cell.bounds() orelse {
            cell.deinit();
            return;
        };
        // One arena per cell holds both the portrayal streams and the assembled
        // geometry cache, freed together when the band is done.
        var portrayal: ?[]const ?[]const u8 = null;
        var geo: ?s57_mvt.GeoParts = null;
        const pa: ?*std.heap.ArenaAllocator = gpa.create(std.heap.ArenaAllocator) catch null;
        if (pa) |p| {
            p.* = std.heap.ArenaAllocator.init(gpa);
            portrayal = portray.portrayCell(p.allocator(), &cell, c.rules_dir) catch null;
            if (c.build_geo) geo = s57_mvt.buildGeoCache(p.allocator(), &cell) catch null;
        }
        c.outs[i] = .{ .cell = cell, .portrayal = portrayal, .geo = geo, .bounds = b };
        c.arenas[i] = pa;
    }
};

/// Bake an ENC_ROOT (the same CellInput[] as open_cells) into ONE PMTiles archive,
/// zoom-banded per cell by compilation scale. On success returns 1 with the archive
/// bytes in out/out_len (free with tile57_tile_free); 0 if nothing was covered; -1
/// on error. `progress` (nullable) is called during the load+portray phase (stage
/// 0) and the tile-bake phase (stage 1). Streams band-by-band (finest → coarsest,
/// best-band dedup), holding only one band's parsed cells at a time — peak memory
/// tracks the largest single band, not the whole catalogue. The host still owns
/// all the input bytes for the duration of the call.
export fn tile57_bake_cells(
    cells_ptr: [*]const CellInput,
    count: usize,
    rules_dir: ?[*:0]const u8,
    minzoom: u8,
    maxzoom: u8,
    progress: BakeProgress,
    user: ?*anyopaque,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const dir = resolveRulesDir(rules_dir);
    const inputs = cells_ptr[0..count];

    // Group input indices by navigational band (cheap CSCL peek; no geometry).
    var band_idx: [bake_enc.bands_fine_to_coarse.len]std.ArrayList(usize) = undefined;
    for (&band_idx) |*bi| bi.* = std.ArrayList(usize).empty;
    defer for (&band_idx) |*bi| bi.deinit(gpa);
    for (inputs, 0..) |in, i| {
        const cscl = s57.peekScale(gpa, in.base[0..in.base_len]) orelse 0;
        band_idx[@intFromEnum(bake_enc.bandOf(cscl))].append(gpa, i) catch return -1;
    }

    catalogue.warmUp(); // warm the shared catalogue before parallel portrayal
    portray.setQuiet(true); // many threads -> suppress the per-cell stderr
    var baker = bake_enc.Baker.init(gpa, minzoom, maxzoom);
    defer baker.deinit();

    // Bake band-by-band, finest → coarsest. Parse + portray a band's cells in
    // parallel, bake, then free them before the next band so peak memory is one
    // band's worth and portrayal runs across all cores.
    var loaded: usize = 0;
    for (bake_enc.bands_fine_to_coarse) |band| {
        const idxs = band_idx[@intFromEnum(band)].items;
        if (idxs.len == 0) continue;

        // Materialize this band's sources (base + update slices into host buffers).
        var sources = std.ArrayList(BakeSource).empty;
        defer {
            for (sources.items) |s| gpa.free(s.updates);
            sources.deinit(gpa);
        }
        sources.ensureTotalCapacity(gpa, idxs.len) catch continue;
        for (idxs) |i| {
            const in = inputs[i];
            var ups = std.ArrayList([]const u8).empty;
            if (in.updates) |uptr| if (in.update_lens) |ulen| {
                var k: usize = 0;
                while (k < in.update_count) : (k += 1) ups.append(gpa, uptr[k][0..ulen[k]]) catch break;
            };
            sources.appendAssumeCapacity(.{ .base = in.base[0..in.base_len], .updates = ups.toOwnedSlice(gpa) catch &.{} });
        }

        const outs = gpa.alloc(?bake_enc.Backend, sources.items.len) catch continue;
        defer gpa.free(outs);
        @memset(outs, null);
        const pas = gpa.alloc(?*std.heap.ArenaAllocator, sources.items.len) catch continue;
        defer gpa.free(pas);
        @memset(pas, null);
        var bw = BakeWork{ .sources = sources.items, .outs = outs, .arenas = pas, .rules_dir = dir, .build_geo = bake_enc.cacheGeoForBand(band) };
        bake_enc.parallelFor(sources.items.len, &bw, BakeWork.run);
        loaded += idxs.len;
        if (progress) |cb| cb(user, 0, loaded, count);

        var backs = std.ArrayList(bake_enc.Backend).empty;
        var band_arenas = std.ArrayList(?*std.heap.ArenaAllocator).empty;
        backs.ensureTotalCapacity(gpa, outs.len) catch {};
        band_arenas.ensureTotalCapacity(gpa, outs.len) catch {};
        for (outs, pas) |o, pa| if (o) |be| {
            backs.appendAssumeCapacity(be);
            band_arenas.appendAssumeCapacity(pa);
        };
        baker.bakeBand(band, backs.items, progress, user) catch {};
        for (backs.items) |*be| be.cell.deinit();
        for (band_arenas.items) |pa| if (pa) |p| {
            p.deinit();
            gpa.destroy(p);
        };
        backs.deinit(gpa);
        band_arenas.deinit(gpa);
    }

    const archive = baker.finish() catch return -1;
    if (archive.len == 0) {
        gpa.free(archive);
        return 0;
    }
    out.* = archive.ptr;
    out_len.* = archive.len;
    return 1;
}

/// Open a chart tile source from in-memory bytes. `format` selects the backend
/// (TILE57_FORMAT_AUTO sniffs PMTiles then S-57); `rules_dir` is the S-101 rules dir
/// for cells (null = default). Bytes are copied. Returns a handle or null.
export fn tile57_source_open(
    data_ptr: [*]const u8,
    data_len: usize,
    format: c_int,
    rules_dir: ?[*:0]const u8,
) callconv(.c) ?*Source {
    const fmt: Format = switch (format) {
        @intFromEnum(Format.pmtiles) => .pmtiles,
        @intFromEnum(Format.s57_cell) => .s57_cell,
        else => .auto,
    };
    const bytes = data_ptr[0..data_len];

    if (fmt == .pmtiles or fmt == .auto) {
        const copy = gpa.dupe(u8, bytes) catch return null;
        if (openPmtiles(copy)) |src| return src; // openPmtiles freed `copy` on failure
        if (fmt == .pmtiles) return null;
    }
    // AUTO fallback or explicit S-57 cell. openCell does not take ownership, so
    // it reads the caller's bytes directly (no copy needed).
    return openCell(bytes, rules_dir);
}

/// The resolved backend format (after a TILE57_FORMAT_AUTO sniff).
export fn tile57_source_format(src: ?*Source) callconv(.c) c_int {
    const s = src orelse return @intFromEnum(Format.auto);
    return switch (s.backend) {
        .reader => @intFromEnum(Format.pmtiles),
        .cell, .cells => @intFromEnum(Format.s57_cell),
    };
}

export fn tile57_source_close(src: ?*Source) callconv(.c) void {
    const s = src orelse return;
    switch (s.backend) {
        .reader => |*r| r.deinit(),
        .cell => |*cb| freeCellBackend(cb),
        .cells => |*ls| {
            for (ls.cells) |*lc| lazyFreeCell(lc);
            gpa.free(ls.cells);
            gpa.free(ls.rules_dir);
        },
    }
    var it = s.cache.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    s.cache.deinit();
    if (s.data) |d| gpa.free(d);
    gpa.destroy(s);
}

/// Min/max zoom served by the source (PMTiles: archive range; cell: 0..18).
export fn tile57_source_zoom_range(src: ?*Source, min_z: *u8, max_z: *u8) callconv(.c) void {
    const s = src orelse {
        min_z.* = 0;
        max_z.* = 0;
        return;
    };
    switch (s.backend) {
        .reader => |r| {
            min_z.* = r.header.min_zoom;
            max_z.* = r.header.max_zoom;
        },
        .cell, .cells => {
            min_z.* = 0;
            max_z.* = 18;
        },
    }
}

/// Geographic bounds of the source (west,south,east,north degrees); returns true
/// when known. Lets a host frame the data with its own fit-to-window logic
/// (MapLibre's cameraForLatLngBounds) rather than a guessed center+zoom.
/// PMTiles -> the archive's stored bounds; cell -> the data extent.
export fn tile57_source_bounds(src: ?*Source, w: *f64, s: *f64, e: *f64, n: *f64) callconv(.c) bool {
    const so = src orelse return false;
    var b: [4]f64 = undefined; // [west, south, east, north]
    switch (so.backend) {
        .reader => |r| {
            const h = r.header;
            if (h.min_lon_e7 == 0 and h.max_lon_e7 == 0 and h.min_lat_e7 == 0 and h.max_lat_e7 == 0) return false;
            b = .{
                @as(f64, @floatFromInt(h.min_lon_e7)) / 1e7,
                @as(f64, @floatFromInt(h.min_lat_e7)) / 1e7,
                @as(f64, @floatFromInt(h.max_lon_e7)) / 1e7,
                @as(f64, @floatFromInt(h.max_lat_e7)) / 1e7,
            };
        },
        .cell => |*cb| b = cb.cell.bounds() orelse return false,
        .cells => |ls| {
            if (ls.cells.len == 0) return false;
            var u: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 }; // [w,s,e,n]
            for (ls.cells) |lc| { // from the cheap index bboxes — no parse
                u[0] = @min(u[0], lc.bbox[0]);
                u[1] = @min(u[1], lc.bbox[1]);
                u[2] = @max(u[2], lc.bbox[2]);
                u[3] = @max(u[3], lc.bbox[3]);
            }
            b = u;
        },
    }
    // Reject degenerate (a point) or near-global bounds (likely unset/default).
    if (b[2] - b[0] <= 1e-9 or b[3] - b[1] <= 1e-9) return false;
    if (b[2] - b[0] >= 359.0 or b[3] - b[1] >= 179.0) return false;
    w.* = b[0];
    s.* = b[1];
    e.* = b[2];
    n.* = b[3];
    return true;
}

/// A good initial camera (center lat/lon + zoom) sitting on real data, for when
/// fitting the whole source would zoom out uselessly (a continental ENC_ROOT).
/// Centers on the smallest chart cell near the data median (a harbour, over water
/// with dense data) at a navigable zoom. true when set; false (PMTiles / single
/// cell) → the caller uses fit-to-bounds.
export fn tile57_source_anchor(src: ?*Source, lat: *f64, lon: *f64, zoom: *f64) callconv(.c) bool {
    const so = src orelse return false;
    switch (so.backend) {
        .cells => |ls| {
            // Consider only "sane" cells: a normal chart's bbox spans well under
            // ~10°. This drops huge overview cells AND corrupt cells (an outlier
            // SG2D coord blows the bbox up) / IHO test cells with junk coordinates.
            var cnt: usize = 0;
            for (ls.cells) |lc| {
                if (lc.bbox[2] - lc.bbox[0] < 10.0 and lc.bbox[3] - lc.bbox[1] < 10.0) cnt += 1;
            }
            if (cnt == 0) return false;
            // Median center of the sane cells — robust to scattered outliers, lands
            // in the densest (real survey) cluster.
            const lons = gpa.alloc(f64, cnt) catch return false;
            defer gpa.free(lons);
            const lats = gpa.alloc(f64, cnt) catch return false;
            defer gpa.free(lats);
            var i: usize = 0;
            for (ls.cells) |lc| {
                if (lc.bbox[2] - lc.bbox[0] >= 10.0 or lc.bbox[3] - lc.bbox[1] >= 10.0) continue;
                lons[i] = (lc.bbox[0] + lc.bbox[2]) / 2;
                lats[i] = (lc.bbox[1] + lc.bbox[3]) / 2;
                i += 1;
            }
            std.mem.sort(f64, lons, {}, std.sort.asc(f64));
            std.mem.sort(f64, lats, {}, std.sort.asc(f64));
            const mlon = lons[cnt / 2];
            const mlat = lats[cnt / 2];
            // Within the dense cluster (near the median), open on the SMALLEST cell
            // — the most-detailed chart, i.e. a harbour/berthing cell, which sits
            // over water with dense data and fits at a high zoom (above the style's
            // minzoom). Fall back to the nearest sane cell if none are close.
            var bestArea: f64 = 1e30;
            var best: ?[4]f64 = null;
            var nbd: f64 = 1e30;
            var nearest: ?[4]f64 = null;
            for (ls.cells) |lc| {
                if (lc.bbox[2] - lc.bbox[0] >= 10.0 or lc.bbox[3] - lc.bbox[1] >= 10.0) continue;
                const cx = (lc.bbox[0] + lc.bbox[2]) / 2;
                const cy = (lc.bbox[1] + lc.bbox[3]) / 2;
                const d = (cx - mlon) * (cx - mlon) + (cy - mlat) * (cy - mlat);
                if (d < nbd) {
                    nbd = d;
                    nearest = lc.bbox;
                }
                if (@abs(cx - mlon) > 3.0 or @abs(cy - mlat) > 3.0) continue;
                const area = (lc.bbox[2] - lc.bbox[0]) * (lc.bbox[3] - lc.bbox[1]);
                if (area < bestArea) {
                    bestArea = area;
                    best = lc.bbox;
                }
            }
            const b = best orelse nearest orelse return false;
            lon.* = (b[0] + b[2]) / 2;
            lat.* = (b[1] + b[3]) / 2;
            zoom.* = 12; // harbour-area view, above the style minzoom; over water
            return true;
        },
        else => return false,
    }
}

/// Fetch tile (z,x,y) as MVT bytes (PMTiles: decompressed; cell: generated).
/// Returns TILE57_TILE_OK (1) + out/out_len (free with tile57_tile_free) if non-empty,
/// TILE57_TILE_EMPTY (0) if empty/absent, TILE57_TILE_ERROR (-1) on error.
export fn tile57_tile_get(
    src: ?*Source,
    z: u8,
    x: u32,
    y: u32,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const s = src orelse return -1;
    const key = tileKey(z, x, y);

    // Cache hit: hand back a fresh copy (empty slice cached == empty tile).
    if (s.cache.get(key)) |cached| {
        if (cached.len == 0) return 0;
        const dup = gpa.dupe(u8, cached) catch return -1;
        out.* = dup.ptr;
        out_len.* = dup.len;
        return 1;
    }

    // Miss: generate/decode once, then cache the canonical bytes (even empty, so
    // empty tiles aren't recomputed every frame).
    const bytes: []u8 = switch (s.backend) {
        .reader => |*r| (r.getTile(gpa, z, x, y) catch return -1) orelse (gpa.alloc(u8, 0) catch return -1),
        .cell => |*cb| s57_mvt.generateTile(gpa, &cb.cell, z, x, y, cb.portrayal) catch return -1,
        .cells => |*ls| blk: {
            const tb = tile.tileBoundsLonLat(z, x, y); // [w,s,e,n]
            // Collect every overlapping cell whose native band range includes z, so
            // a finer cell that covers only part of the tile doesn't blank out the
            // coarser cell that fills the rest (a best-band single-pick left gaps).
            // If no band's range includes z (a coverage gap — e.g. zoomed out below
            // the finest band present), overzoom the coarsest overlapping band.
            var any_incl = false;
            var coarsest: ?bake_enc.Band = null;
            for (ls.cells) |lc| {
                if (!bboxOverlap(lc.bbox, tb)) continue;
                const zr = bake_enc.bandZooms(lc.band);
                if (z >= zr.min and z <= zr.max) any_incl = true;
                if (coarsest == null or @intFromEnum(lc.band) > @intFromEnum(coarsest.?)) coarsest = lc.band;
            }
            const cband = coarsest orelse break :blk (gpa.alloc(u8, 0) catch return -1);

            var idxs = std.ArrayList(u32).empty;
            defer idxs.deinit(gpa);
            for (ls.cells, 0..) |lc, i| {
                if (!bboxOverlap(lc.bbox, tb)) continue;
                const zr = bake_enc.bandZooms(lc.band);
                const use = if (any_incl) (z >= zr.min and z <= zr.max) else (lc.band == cband);
                if (use) idxs.append(gpa, @intCast(i)) catch {};
            }
            // Draw coarse -> fine so finer charts overlay coarser at band overlaps.
            std.mem.sort(u32, idxs.items, ls, struct {
                fn lt(l: *LazySource, a: u32, b: u32) bool {
                    return @intFromEnum(l.cells[a].band) > @intFromEnum(l.cells[b].band);
                }
            }.lt);

            const keep_from = ls.tick + 1; // cells loaded for this tile aren't evicted below
            var refs = std.ArrayList(s57_mvt.CellRef).empty;
            defer refs.deinit(gpa);
            for (idxs.items) |i| {
                lazyEnsureLoaded(ls, &ls.cells[i]);
                if (ls.cells[i].cell) |*c| refs.append(gpa, .{ .cell = c, .portrayal = ls.cells[i].portrayal }) catch {};
            }
            const mvt = s57_mvt.generateTileMulti(gpa, refs.items, z, x, y) catch return -1;
            lazyEvict(ls, keep_from);
            break :blk mvt;
        },
    };
    // Bound memory: a long pan session generates new tiles indefinitely. Re-requests
    // are short-circuited by the etag/notModified path before this, so dropping the
    // cache only forces a (cheap, deterministic) regen of the rare non-priorEtag
    // re-request — never a re-parse/flicker.
    if (s.cache.count() >= s.cache_max) {
        var cit = s.cache.valueIterator();
        while (cit.next()) |v| gpa.free(v.*);
        s.cache.clearRetainingCapacity();
    }
    s.cache.put(key, bytes) catch {}; // best-effort; cache owns `bytes` on success
    if (bytes.len == 0) return 0;
    const dup = gpa.dupe(u8, bytes) catch return -1;
    out.* = dup.ptr;
    out_len.* = dup.len;
    return 1;
}

export fn tile57_tile_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

/// Drop the in-memory tile cache (bounds memory in long-running hosts).
export fn tile57_source_clear_cache(src: ?*Source) callconv(.c) void {
    const s = src orelse return;
    var it = s.cache.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    s.cache.clearRetainingCapacity();
}
