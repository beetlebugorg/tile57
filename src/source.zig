//! The tile57 engine API, in Zig. A `Source` is an embeddable nautical-chart
//! tile source: open it from in-memory bytes (a PMTiles archive or raw S-57 ENC
//! cells) and it serves decompressed Mapbox Vector Tiles by (z, x, y). Multi-cell
//! ENC_ROOT sources index cells cheaply and parse + portray them lazily per
//! requested tile (LRU-bounded), so a host can open the whole NOAA catalogue
//! instantly and pay only for the cells under the current view. `bakeArchive`
//! bakes an ENC_ROOT into one band-streamed PMTiles archive.
//!
//! This is the single source of truth; the C ABI (capi.zig / include/tile57.h)
//! is a thin shim over these types. The engine uses the (thread-safe) page
//! allocator internally — `tile`/`bakeArchive` return page-allocator-owned bytes;
//! free them with `freeBytes`.
//!
//! Threading: a Source is NOT internally synchronized — don't call `tile` on the
//! same Source from multiple threads concurrently (the tile cache + LRU mutate
//! without a lock). Distinct sources are independent. `openCells`/`bakeArchive`
//! parallelize internally over cores.

const std = @import("std");
const pmtiles = @import("pmtiles");
const s57 = @import("s57");
const s57_mvt = @import("s57_mvt");
const portray = @import("portray");
const bake_enc = @import("bake_enc");
const catalogue = @import("s100").catalogue;
const tile = @import("tile");

const gpa = std.heap.page_allocator;

// Env access lives in C (Zig 0.16 puts env behind Io); returns the S-101 rules
// dir from TILE57_S101_RULES or null. Provided by the portrayal C shim.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

/// Backend / on-disk format. `auto` sniffs PMTiles first, then S-57.
pub const Format = enum { auto, pmtiles, s57_cell };

/// One ENC cell: the base .000 bytes plus its sequential update files (.001…).
/// Bytes are borrowed for the duration of the call (copied where retained).
pub const CellInput = struct {
    base: []const u8,
    updates: []const []const u8 = &.{},
};

/// Progress callback for `bakeArchive`: stage 0 = loading/portraying cells,
/// stage 1 = baking tiles. C-callconv so a C host can pass one directly.
pub const Progress = ?*const fn (user: ?*anyopaque, stage: u8, done: usize, total: usize) callconv(.c) void;

/// Pre-peeked metadata for one cell in a streaming open: its geographic extent
/// and compilation scale (1:cscl). The host supplies these (cheap to compute, or
/// already known) so the source opens without reading any cell bytes.
pub const CellMeta = extern struct {
    west: f64,
    south: f64,
    east: f64,
    north: f64,
    cscl: i32,
};

/// Cell bytes returned by a streaming reader. The reader transfers OWNERSHIP of
/// malloc-allocated buffers (base + each update); the engine frees them with
/// libc free() once the cell is parsed. update arrays are parallel, length
/// update_count (0 / null for a base-only cell).
pub const CellBytes = extern struct {
    base: [*]const u8 = undefined,
    base_len: usize = 0,
    updates: ?[*]const [*]const u8 = null,
    update_lens: ?[*]const usize = null,
    update_count: usize = 0,
};

/// Streaming cell reader: fill `out` with cell `index`'s malloc'd bytes (the
/// engine frees them), returning true on success. Called on demand the first
/// time a tile needs the cell (and again after the cell is LRU-evicted), so the
/// host holds only the working set's bytes — not the whole ENC_ROOT.
pub const CellReadFn = *const fn (user: ?*anyopaque, index: usize, out: *CellBytes) callconv(.c) bool;

/// Free bytes returned by `Source.tile` / `bakeArchive` (page-allocator owned).
pub fn freeBytes(bytes: []u8) void {
    gpa.free(bytes);
}

// ---- backends ------------------------------------------------------------

const CellBackend = struct {
    cell: s57.Cell,
    portrayal: ?[]const ?[]const u8 = null, // per-feature default S-101 instruction stream
    portrayal_plain: ?[]const ?[]const u8 = null, // PlainBoundaries variant (areas)
    portrayal_simplified: ?[]const ?[]const u8 = null, // SimplifiedSymbols variant (points)
    portray_arena: ?*std.heap.ArenaAllocator = null,
};

// One cell in the lazy ENC_ROOT index: its owned bytes + cheap metadata (bbox +
// navigational band), parsed + portrayed ON DEMAND the first time a requested tile
// needs it, then kept until evicted by the LRU.
const LazyCell = struct {
    base: []u8,
    updates: [][]u8,
    bbox: [4]f64, // [west, south, east, north]
    band: bake_enc.Band,
    cell: ?s57.Cell = null,
    portrayal: ?[]const ?[]const u8 = null,
    portrayal_plain: ?[]const ?[]const u8 = null,
    portrayal_simplified: ?[]const ?[]const u8 = null,
    arena: ?*std.heap.ArenaAllocator = null,
    tick: u64 = 0, // LRU: last tile that used this cell
    // M_COVR(CATCOV=1) coverage polygons, assembled once from `cell` for best-band
    // suppression. Lives in cell.arena, freed (and reset) when the cell unloads.
    coverage: ?[]const []const []const s57.LonLat = null,
    // Streaming: when the source has a reader, `base`/`updates` are empty until the
    // cell is first needed (read on demand into gpa, freed on eviction), so only
    // the LRU working set's bytes are held. `index` is passed to the reader.
    streaming: bool = false,
    index: usize = 0,
};

const LazySource = struct {
    cells: []LazyCell,
    rules_dir: []u8, // owned (lazy portrayal needs it after open returns)
    tick: u64 = 0,
    loaded: usize = 0,
    max_loaded: usize = 256, // LRU budget on parsed+portrayed cells (wide views)
    reader: ?CellReadFn = null, // streaming: read a cell's bytes on demand
    reader_user: ?*anyopaque = null,
};

const Backend = union(enum) {
    reader: pmtiles.Reader,
    cell: CellBackend,
    cells: LazySource, // ENC_ROOT: lazy spatial index, parsed/portrayed on demand
};

// The cell's M_COVR (OBJL 302, CATCOV=1) data-coverage polygons, assembled +
// cached on first use. Each polygon is a list of lon/lat rings (exterior + holes).
fn lazyCellCoverage(lc: *LazyCell) []const []const []const s57.LonLat {
    if (lc.coverage) |c| return c;
    if (lc.cell) |*cell| {
        const a = cell.arena.allocator();
        var polys = std.ArrayList([]const []const s57.LonLat).empty;
        for (cell.features) |f| {
            if (f.objl != 302) continue; // M_COVR
            const cv = f.attr(18) orelse continue; // CATCOV (S-57 attr 18)
            const n = std.fmt.parseInt(i64, std.mem.trim(u8, cv, " "), 10) catch continue;
            if (n != 1) continue; // 1 = coverage available (2 = no coverage)
            const rings = cell.lineGeometryParts(a, f) catch continue;
            if (rings.len > 0) polys.append(a, rings) catch {};
        }
        lc.coverage = polys.items;
        return polys.items;
    }
    return &.{};
}

fn coverageContains(polys: []const []const []const s57.LonLat, lon: f64, lat: f64) bool {
    for (polys) |rings| if (s57.pointInRings(rings, lon, lat)) return true;
    return false;
}

// The FINEST band (largest band-max zoom) among the indexed cells whose M_COVR
// coverage contains (lon,lat); 0 = none. (Go coverageBandAt.)
fn finestCoverageBand(ls: *LazySource, idxs: []const u32, lon: f64, lat: f64) u8 {
    var best: u8 = 0;
    for (idxs) |i| {
        const nm = bake_enc.bandMaxZoom(ls.cells[i].band);
        if (nm <= best) continue;
        if (coverageContains(lazyCellCoverage(&ls.cells[i]), lon, lat)) best = nm;
    }
    return best;
}

fn bboxOverlap(a_: [4]f64, b_: [4]f64) bool {
    return a_[0] <= b_[2] and a_[2] >= b_[0] and a_[1] <= b_[3] and a_[3] >= b_[1];
}

// Free the host-malloc'd buffers a streaming reader transferred to us (libc free).
fn freeCellBytes(cb: *CellBytes) void {
    if (cb.base_len != 0) std.c.free(@constCast(@ptrCast(cb.base)));
    if (cb.updates) |ups| {
        var k: usize = 0;
        while (k < cb.update_count) : (k += 1) std.c.free(@constCast(@ptrCast(ups[k])));
        std.c.free(@constCast(@ptrCast(ups)));
    }
    if (cb.update_lens) |ul| std.c.free(@constCast(@ptrCast(ul)));
}

// Read a streaming cell's bytes via the host reader into gpa-owned base/updates
// (freeing the host's originals). Returns false if the reader declines/fails.
fn streamRead(ls: *LazySource, lc: *LazyCell) bool {
    const rd = ls.reader orelse return false;
    var cb: CellBytes = .{};
    if (!rd(ls.reader_user, lc.index, &cb)) return false;
    const base = gpa.dupe(u8, cb.base[0..cb.base_len]) catch {
        freeCellBytes(&cb);
        return false;
    };
    var ups: [][]u8 = &.{};
    if (cb.update_count > 0 and cb.updates != null and cb.update_lens != null) {
        const arr = gpa.alloc([]u8, cb.update_count) catch {
            gpa.free(base);
            freeCellBytes(&cb);
            return false;
        };
        var k: usize = 0;
        while (k < cb.update_count) : (k += 1) {
            arr[k] = gpa.dupe(u8, cb.updates.?[k][0..cb.update_lens.?[k]]) catch {
                for (arr[0..k]) |u| gpa.free(u);
                gpa.free(arr);
                gpa.free(base);
                freeCellBytes(&cb);
                return false;
            };
        }
        ups = arr;
    }
    freeCellBytes(&cb);
    lc.base = base;
    lc.updates = ups;
    return true;
}

// Parse + portray a lazy cell if not already loaded, and stamp its LRU tick.
fn lazyEnsureLoaded(ls: *LazySource, lc: *LazyCell) void {
    ls.tick += 1;
    lc.tick = ls.tick;
    if (lc.cell != null) return;
    if (lc.streaming and lc.base.len == 0) {
        if (!streamRead(ls, lc)) return;
    }
    var cell = s57.parseCellWithUpdates(gpa, lc.base, lc.updates) catch return;
    if (gpa.create(std.heap.ArenaAllocator)) |p| {
        p.* = std.heap.ArenaAllocator.init(gpa);
        if (portray.portrayCellVariants(p.allocator(), &cell, ls.rules_dir)) |cp| {
            lc.portrayal = cp.base;
            lc.portrayal_plain = cp.plain;
            lc.portrayal_simplified = cp.simplified;
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
    lc.coverage = null; // backing memory lived in cell.arena, freed by c.deinit()
    lc.portrayal_plain = null;
    lc.portrayal_simplified = null;
    if (lc.arena) |p| {
        p.deinit();
        gpa.destroy(p);
        lc.arena = null;
    }
    // Streaming cells free their on-demand bytes on unload (reload re-reads), so
    // only the resident working set holds bytes.
    if (lc.streaming) {
        if (lc.base.len > 0) gpa.free(lc.base);
        for (lc.updates) |u| gpa.free(u);
        if (lc.updates.len > 0) gpa.free(lc.updates);
        lc.base = &.{};
        lc.updates = &.{};
    }
}

// Evict LRU loaded cells down to budget, never touching cells used by the tile
// currently being generated (tick >= keep_from).
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

fn lazyFreeCell(lc: *LazyCell) void {
    lazyUnload(lc); // streaming cells are already emptied here
    if (lc.base.len > 0) gpa.free(lc.base);
    for (lc.updates) |u| gpa.free(u);
    if (lc.updates.len > 0) gpa.free(lc.updates);
}

fn tileKey(z: u8, x: u32, y: u32) u64 {
    return (@as(u64, z) << 48) | (@as(u64, x) << 24) | @as(u64, y);
}

// Resolve the S-101 rules dir: explicit arg, else TILE57_S101_RULES, else "" —
// which uses the rules embedded in the binary (the Lua searcher in lua_shim.c),
// so no on-disk catalogue is required. A non-empty path overrides the embedded
// copy (read from disk).
fn resolveRulesDir(rules_dir: ?[]const u8) []const u8 {
    if (rules_dir) |d| if (d.len > 0) return d;
    if (tg_env_rules()) |dirz| return std.mem.span(dirz);
    return "";
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

// Parse (+ apply updates) + portray one cell into a CellBackend. Reads the bytes
// but does not take ownership. Portrayal failure is non-fatal (classify() fallback).
fn buildCellBackend(base: []const u8, updates: []const []const u8, dir: []const u8) ?CellBackend {
    const cell = s57.parseCellWithUpdates(gpa, base, updates) catch return null;
    var cb = CellBackend{ .cell = cell };
    const pa = gpa.create(std.heap.ArenaAllocator) catch return cb;
    pa.* = std.heap.ArenaAllocator.init(gpa);
    if (portray.portrayCellVariants(pa.allocator(), &cb.cell, dir)) |cp| {
        cb.portrayal = cp.base;
        cb.portrayal_plain = cp.plain;
        cb.portrayal_simplified = cp.simplified;
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

fn openCell(bytes: []const u8, rules_dir: ?[]const u8) ?*Source {
    var cb = buildCellBackend(bytes, &.{}, resolveRulesDir(rules_dir)) orelse return null;
    const src = gpa.create(Source) catch {
        freeCellBackend(&cb);
        return null;
    };
    src.* = .{ .backend = .{ .cell = cb }, .data = null, .cache = std.AutoHashMap(u64, []u8).init(gpa) };
    return src;
}

// Parallel open worker: peek each cell's band + bbox and copy its bytes.
const OpenWork = struct {
    inputs: []const CellInput,
    out: []LazyCell,
    ok: []bool,

    fn run(uptr: *anyopaque, i: usize, scratch: std.mem.Allocator) void {
        _ = scratch; // persistent outputs go straight to `gpa`
        const c: *OpenWork = @ptrCast(@alignCast(uptr));
        const in = c.inputs[i];
        const meta = s57.peekMeta(gpa, in.base) orelse return;
        const bbox = meta.bounds orelse return;
        const base = gpa.dupe(u8, in.base) catch return;
        var ups: [][]u8 = &.{};
        if (in.updates.len > 0) {
            const arr = gpa.alloc([]u8, in.updates.len) catch {
                gpa.free(base);
                return;
            };
            var k: usize = 0;
            while (k < in.updates.len) : (k += 1) {
                arr[k] = gpa.dupe(u8, in.updates[k]) catch {
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

/// The public tile source handle. Open with `openBytes`/`openCells`; release with
/// `deinit`.
pub const Source = struct {
    backend: Backend,
    data: ?[]u8 = null, // owned archive bytes (PMTiles backend only)
    cache: std.AutoHashMap(u64, []u8), // tile key -> MVT bytes (owned)
    cache_max: usize = 8192,

    /// Open a source from in-memory bytes. `fmt` selects the backend (`.auto`
    /// sniffs PMTiles then S-57); `rules_dir` is the S-101 rules dir for cells
    /// (null = TILE57_S101_RULES env, else the vendored default). Bytes are copied.
    pub fn openBytes(bytes: []const u8, fmt: Format, rules_dir: ?[]const u8) !*Source {
        if (fmt == .pmtiles or fmt == .auto) {
            const copy = try gpa.dupe(u8, bytes);
            if (openPmtiles(copy)) |src| return src; // openPmtiles freed `copy` on failure
            if (fmt == .pmtiles) return error.OpenFailed;
        }
        return openCell(bytes, rules_dir) orelse error.OpenFailed;
    }

    /// Open an ENC_ROOT as a multi-cell source: cells are indexed cheaply (band +
    /// bbox) in parallel and parsed/portrayed lazily per tile. All bytes are
    /// copied. Errors if no cell's header parses.
    pub fn openCells(cells_in: []const CellInput, rules_dir: ?[]const u8) !*Source {
        if (cells_in.len == 0) return error.OpenFailed;
        const dir = resolveRulesDir(rules_dir);
        const dir_copy = try gpa.dupe(u8, dir);
        errdefer gpa.free(dir_copy);

        const tmp = gpa.alloc(LazyCell, cells_in.len) catch return error.OpenFailed;
        defer gpa.free(tmp);
        const ok = gpa.alloc(bool, cells_in.len) catch return error.OpenFailed;
        defer gpa.free(ok);
        @memset(ok, false);

        var ow = OpenWork{ .inputs = cells_in, .out = tmp, .ok = ok };
        bake_enc.parallelFor(gpa, cells_in.len, &ow, OpenWork.run);

        var valid: usize = 0;
        for (ok) |k| {
            if (k) valid += 1;
        }
        if (valid == 0) return error.OpenFailed;

        const cells = gpa.alloc(LazyCell, valid) catch {
            for (tmp, ok) |*lc, k| if (k) lazyFreeCell(lc);
            return error.OpenFailed;
        };
        var j: usize = 0;
        for (tmp, ok) |lc, k| if (k) {
            cells[j] = lc;
            j += 1;
        };

        const src = gpa.create(Source) catch {
            for (cells) |*lc| lazyFreeCell(lc);
            gpa.free(cells);
            return error.OpenFailed;
        };
        src.* = .{
            .backend = .{ .cells = .{ .cells = cells, .rules_dir = dir_copy } },
            .cache = std.AutoHashMap(u64, []u8).init(gpa),
        };
        return src;
    }

    /// Open an ENC_ROOT as a streaming multi-cell source: the host supplies cheap
    /// per-cell metadata (bbox + scale) up front and a `reader` callback that
    /// returns a cell's bytes on demand. Cell bytes are read only when a tile
    /// needs them and freed on LRU eviction, so the host holds the working set's
    /// bytes — not the whole ENC_ROOT. No bytes are read at open. Errors if empty.
    pub fn openCellsStreaming(metas: []const CellMeta, reader: CellReadFn, user: ?*anyopaque, rules_dir: ?[]const u8) !*Source {
        if (metas.len == 0) return error.OpenFailed;
        const dir = resolveRulesDir(rules_dir);
        const dir_copy = try gpa.dupe(u8, dir);
        errdefer gpa.free(dir_copy);
        const cells = gpa.alloc(LazyCell, metas.len) catch return error.OpenFailed;
        for (metas, 0..) |m, i| {
            cells[i] = .{
                .base = &.{},
                .updates = &.{},
                .bbox = .{ m.west, m.south, m.east, m.north },
                .band = bake_enc.bandOf(m.cscl),
                .streaming = true,
                .index = i,
            };
        }
        const src = gpa.create(Source) catch {
            gpa.free(cells);
            return error.OpenFailed;
        };
        src.* = .{
            .backend = .{ .cells = .{ .cells = cells, .rules_dir = dir_copy, .reader = reader, .reader_user = user } },
            .cache = std.AutoHashMap(u64, []u8).init(gpa),
        };
        return src;
    }

    /// Release the source and all cached tiles.
    pub fn deinit(self: *Source) void {
        switch (self.backend) {
            .reader => |*r| r.deinit(),
            .cell => |*cb| freeCellBackend(cb),
            .cells => |*ls| {
                for (ls.cells) |*lc| lazyFreeCell(lc);
                gpa.free(ls.cells);
                gpa.free(ls.rules_dir);
            },
        }
        var it = self.cache.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        self.cache.deinit();
        if (self.data) |d| gpa.free(d);
        gpa.destroy(self);
    }

    /// The resolved backend format (after an `.auto` sniff).
    pub fn format(self: *Source) Format {
        return switch (self.backend) {
            .reader => .pmtiles,
            .cell, .cells => .s57_cell,
        };
    }

    /// Min/max zoom served (PMTiles: archive range; cell: 0..18).
    pub fn zoomRange(self: *Source) struct { min: u8, max: u8 } {
        return switch (self.backend) {
            .reader => |r| .{ .min = r.header.min_zoom, .max = r.header.max_zoom },
            .cell, .cells => .{ .min = 0, .max = 18 },
        };
    }

    /// Bitmask of navigational bands present (bit r = band rank r has a cell;
    /// 0=berthing/finest … 5=overview/coarsest). 0 for a single cell / PMTiles.
    pub fn bands(self: *Source) u32 {
        return switch (self.backend) {
            .cells => |ls| blk: {
                var mask: u32 = 0;
                for (ls.cells) |lc| mask |= @as(u32, 1) << @as(u5, @intCast(@intFromEnum(lc.band)));
                break :blk mask;
            },
            else => 0,
        };
    }

    /// Geographic bounds [west, south, east, north] degrees, or null if unknown /
    /// degenerate / near-global. PMTiles -> archive bounds; cell -> data extent.
    pub fn bounds(self: *Source) ?[4]f64 {
        var b: [4]f64 = undefined;
        switch (self.backend) {
            .reader => |r| {
                const h = r.header;
                if (h.min_lon_e7 == 0 and h.max_lon_e7 == 0 and h.min_lat_e7 == 0 and h.max_lat_e7 == 0) return null;
                b = .{
                    @as(f64, @floatFromInt(h.min_lon_e7)) / 1e7,
                    @as(f64, @floatFromInt(h.min_lat_e7)) / 1e7,
                    @as(f64, @floatFromInt(h.max_lon_e7)) / 1e7,
                    @as(f64, @floatFromInt(h.max_lat_e7)) / 1e7,
                };
            },
            .cell => |*cb| b = cb.cell.bounds() orelse return null,
            .cells => |ls| {
                if (ls.cells.len == 0) return null;
                var u: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 };
                for (ls.cells) |lc| {
                    u[0] = @min(u[0], lc.bbox[0]);
                    u[1] = @min(u[1], lc.bbox[1]);
                    u[2] = @max(u[2], lc.bbox[2]);
                    u[3] = @max(u[3], lc.bbox[3]);
                }
                b = u;
            },
        }
        if (b[2] - b[0] <= 1e-9 or b[3] - b[1] <= 1e-9) return null;
        if (b[2] - b[0] >= 359.0 or b[3] - b[1] >= 179.0) return null;
        return b;
    }

    /// A good initial camera on real data (the smallest chart cell near the data
    /// median, at a navigable zoom), for when fitting the whole source would zoom
    /// out uselessly. null for PMTiles / single cell (use fit-to-bounds).
    pub fn anchor(self: *Source) ?struct { lat: f64, lon: f64, zoom: f64 } {
        switch (self.backend) {
            .cells => |ls| {
                var cnt: usize = 0;
                for (ls.cells) |lc| {
                    if (lc.bbox[2] - lc.bbox[0] < 10.0 and lc.bbox[3] - lc.bbox[1] < 10.0) cnt += 1;
                }
                if (cnt == 0) return null;
                const lons = gpa.alloc(f64, cnt) catch return null;
                defer gpa.free(lons);
                const lats = gpa.alloc(f64, cnt) catch return null;
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
                const b = best orelse nearest orelse return null;
                return .{ .lon = (b[0] + b[2]) / 2, .lat = (b[1] + b[3]) / 2, .zoom = 12 };
            },
            else => return null,
        }
    }

    /// Fetch tile (z,x,y) as decompressed MVT bytes. Returns null for an empty /
    /// absent tile, else page-allocator-owned bytes (free with `freeBytes`).
    /// Cached per source, so re-requests are cheap and deterministic.
    pub fn tile(self: *Source, z: u8, x: u32, y: u32) !?[]u8 {
        const key = tileKey(z, x, y);
        if (self.cache.get(key)) |cached| {
            if (cached.len == 0) return null;
            return try gpa.dupe(u8, cached);
        }
        const bytes: []u8 = switch (self.backend) {
            .reader => |*r| (r.getTile(gpa, z, x, y) catch return error.TileGen) orelse try gpa.alloc(u8, 0),
            .cell => |*cb| blk_cell: {
                const one = [_]s57_mvt.CellRef{.{
                    .cell = &cb.cell,
                    .portrayal = cb.portrayal,
                    .portrayal_plain = cb.portrayal_plain,
                    .portrayal_simplified = cb.portrayal_simplified,
                }};
                var ar = std.heap.ArenaAllocator.init(gpa);
                defer ar.deinit();
                break :blk_cell s57_mvt.generateTileMulti(ar.allocator(), gpa, &one, z, x, y, .mvt) catch return error.TileGen;
            },
            .cells => |*ls| try tileFromCells(ls, z, x, y),
        };
        if (self.cache.count() >= self.cache_max) {
            var cit = self.cache.valueIterator();
            while (cit.next()) |v| gpa.free(v.*);
            self.cache.clearRetainingCapacity();
        }
        self.cache.put(key, bytes) catch {}; // best-effort; cache owns `bytes` on success
        if (bytes.len == 0) return null;
        return try gpa.dupe(u8, bytes);
    }

    /// Drop the in-memory tile cache (bounds memory in long-running hosts).
    pub fn clearCache(self: *Source) void {
        var it = self.cache.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        self.cache.clearRetainingCapacity();
    }
};

// Multi-cell tile generation: collect overlapping cells, lazily load them, apply
// best-band M_COVR suppression, and overlay coarse→fine.
fn tileFromCells(ls: *LazySource, z: u8, x: u32, y: u32) ![]u8 {
    const tb = tile.tileBoundsLonLat(z, x, y); // [w,s,e,n]
    var any_incl = false;
    var coarsest: ?bake_enc.Band = null;
    for (ls.cells) |lc| {
        if (!bboxOverlap(lc.bbox, tb)) continue;
        const zr = bake_enc.bandZooms(lc.band);
        if (z >= zr.min and z <= zr.max) any_incl = true;
        if (coarsest == null or @intFromEnum(lc.band) > @intFromEnum(coarsest.?)) coarsest = lc.band;
    }
    const cband = coarsest orelse return try gpa.alloc(u8, 0);

    var idxs = std.ArrayList(u32).empty;
    defer idxs.deinit(gpa);
    for (ls.cells, 0..) |lc, i| {
        if (!bboxOverlap(lc.bbox, tb)) continue;
        const zr = bake_enc.bandZooms(lc.band);
        const use = if (any_incl) (z >= zr.min and z <= zr.max) else (lc.band == cband);
        if (use) idxs.append(gpa, @intCast(i)) catch {};
    }
    std.mem.sort(u32, idxs.items, ls, struct {
        fn lt(l: *LazySource, a: u32, b: u32) bool {
            return @intFromEnum(l.cells[a].band) > @intFromEnum(l.cells[b].band);
        }
    }.lt);

    const keep_from = ls.tick + 1;
    for (idxs.items) |i| lazyEnsureLoaded(ls, &ls.cells[i]);

    const w = tb[0];
    const s_ = tb[1];
    const e = tb[2];
    const nlat = tb[3];
    const clon = (w + e) / 2;
    const clat = (s_ + nlat) / 2;
    const cov_centre = finestCoverageBand(ls, idxs.items, clon, clat);
    var cov_whole: u8 = cov_centre;
    for ([_][2]f64{ .{ w, nlat }, .{ e, nlat }, .{ w, s_ }, .{ e, s_ } }) |corner| {
        cov_whole = @min(cov_whole, finestCoverageBand(ls, idxs.items, corner[0], corner[1]));
    }

    var refs = std.ArrayList(s57_mvt.CellRef).empty;
    defer refs.deinit(gpa);
    for (idxs.items) |i| {
        const lc = &ls.cells[i];
        if (lc.cell) |*c| {
            const nm = bake_enc.bandMaxZoom(lc.band);
            refs.append(gpa, .{
                .cell = c,
                .portrayal = lc.portrayal,
                .portrayal_plain = lc.portrayal_plain,
                .portrayal_simplified = lc.portrayal_simplified,
                .band = @intFromEnum(lc.band),
                .suppress_fills = bake_enc.coarseAreaSuppressed(nm, z, cov_whole),
                .suppress_patterns = bake_enc.coarseAreaSuppressed(nm, z, cov_centre),
            }) catch {};
        }
    }
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const mvt = s57_mvt.generateTileMulti(ar.allocator(), gpa, refs.items, z, x, y, .mvt) catch return error.TileGen;
    lazyEvict(ls, keep_from);
    return mvt;
}

// ---- ENC_ROOT bake -------------------------------------------------------

const BakeSource = struct { base: []const u8, updates: []const []const u8 };

const BakeWork = struct {
    sources: []const BakeSource,
    outs: []?bake_enc.Backend,
    arenas: []?*std.heap.ArenaAllocator,
    rules_dir: []const u8,
    build_geo: bool,

    fn run(uptr: *anyopaque, i: usize, scratch: std.mem.Allocator) void {
        _ = scratch; // owns persistent backends via its own arenas / `gpa`
        const c: *BakeWork = @ptrCast(@alignCast(uptr));
        const src = c.sources[i];
        var cell = s57.parseCellWithUpdates(gpa, src.base, src.updates) catch return;
        const b = cell.bounds() orelse {
            cell.deinit();
            return;
        };
        var portrayal: ?[]const ?[]const u8 = null;
        var portrayal_plain: ?[]const ?[]const u8 = null;
        var portrayal_simplified: ?[]const ?[]const u8 = null;
        var geo: ?s57_mvt.GeoParts = null;
        const pa: ?*std.heap.ArenaAllocator = gpa.create(std.heap.ArenaAllocator) catch null;
        if (pa) |p| {
            p.* = std.heap.ArenaAllocator.init(gpa);
            if (portray.portrayCellVariants(p.allocator(), &cell, c.rules_dir)) |cp| {
                portrayal = cp.base;
                portrayal_plain = cp.plain;
                portrayal_simplified = cp.simplified;
            } else |_| {}
            if (c.build_geo) geo = s57_mvt.buildGeoCache(p.allocator(), &cell) catch null;
        }
        c.outs[i] = .{ .cell = cell, .portrayal = portrayal, .portrayal_plain = portrayal_plain, .portrayal_simplified = portrayal_simplified, .geo = geo, .bounds = b };
        c.arenas[i] = pa;
    }
};

/// Bake an ENC_ROOT (the same cells as `openCells`) into ONE PMTiles archive,
/// zoom-banded per cell by compilation scale. Returns the archive bytes (free
/// with `freeBytes`), or null if nothing was covered. Streams band-by-band
/// (finest → coarsest, best-band dedup), holding only one band's parsed cells at
/// a time — peak memory tracks the largest single band, not the whole catalogue.
/// `progress` (nullable) fires during the load+portray phase (stage 0) and the
/// tile-bake phase (stage 1). The caller owns the input bytes for the call.
pub fn bakeArchive(
    cells_in: []const CellInput,
    rules_dir: ?[]const u8,
    minzoom: u8,
    maxzoom: u8,
    progress: Progress,
    user: ?*anyopaque,
) !?[]u8 {
    const dir = resolveRulesDir(rules_dir);

    var band_idx: [bake_enc.bands_fine_to_coarse.len]std.ArrayList(usize) = undefined;
    for (&band_idx) |*bi| bi.* = std.ArrayList(usize).empty;
    defer for (&band_idx) |*bi| bi.deinit(gpa);
    for (cells_in, 0..) |in, i| {
        const cscl = s57.peekScale(gpa, in.base) orelse 0;
        band_idx[@intFromEnum(bake_enc.bandOf(cscl))].append(gpa, i) catch return error.BakeFailed;
    }

    catalogue.warmUp();
    portray.setQuiet(true);
    // Stream tiles into a StreamWriter (gzip+dedup, no raw-tile retention); the C
    // ABI returns bytes, so serialize the whole archive at the end.
    var sw = pmtiles.StreamWriter.init(gpa);
    defer sw.deinit();
    var baker = bake_enc.Baker.init(gpa, minzoom, maxzoom, .{ .ctx = &sw, .func = streamSink });
    defer baker.deinit();

    var loaded: usize = 0;
    for (bake_enc.bands_fine_to_coarse) |band| {
        const idxs = band_idx[@intFromEnum(band)].items;
        if (idxs.len == 0) continue;

        var sources = std.ArrayList(BakeSource).empty;
        defer {
            for (sources.items) |s| gpa.free(s.updates);
            sources.deinit(gpa);
        }
        sources.ensureTotalCapacity(gpa, idxs.len) catch continue;
        for (idxs) |i| {
            const in = cells_in[i];
            const ups = gpa.dupe([]const u8, in.updates) catch &.{};
            sources.appendAssumeCapacity(.{ .base = in.base, .updates = ups });
        }

        const outs = gpa.alloc(?bake_enc.Backend, sources.items.len) catch continue;
        defer gpa.free(outs);
        @memset(outs, null);
        const pas = gpa.alloc(?*std.heap.ArenaAllocator, sources.items.len) catch continue;
        defer gpa.free(pas);
        @memset(pas, null);
        var bw = BakeWork{ .sources = sources.items, .outs = outs, .arenas = pas, .rules_dir = dir, .build_geo = bake_enc.cacheGeoForBand(band) };
        bake_enc.parallelFor(gpa, sources.items.len, &bw, BakeWork.run);
        loaded += idxs.len;
        if (progress) |cb| cb(user, 0, loaded, cells_in.len);

        var backs = std.ArrayList(bake_enc.Backend).empty;
        var band_arenas = std.ArrayList(?*std.heap.ArenaAllocator).empty;
        backs.ensureTotalCapacity(gpa, outs.len) catch {};
        band_arenas.ensureTotalCapacity(gpa, outs.len) catch {};
        for (outs, pas) |o, pa| if (o) |be| {
            backs.appendAssumeCapacity(be);
            band_arenas.appendAssumeCapacity(pa);
        };
        baker.bakeBand(band, backs.items, null, progress, user) catch {};
        for (backs.items) |*be| be.cell.deinit();
        for (band_arenas.items) |pa| if (pa) |p| {
            p.deinit();
            gpa.destroy(p);
        };
        backs.deinit(gpa);
        band_arenas.deinit(gpa);
    }

    if (sw.num_addressed == 0) return null;
    const ub = baker.unionBounds();
    return try sw.finishBytes(.{
        .min_lon_e7 = @intFromFloat(@round(ub[0] * 1e7)),
        .min_lat_e7 = @intFromFloat(@round(ub[1] * 1e7)),
        .max_lon_e7 = @intFromFloat(@round(ub[2] * 1e7)),
        .max_lat_e7 = @intFromFloat(@round(ub[3] * 1e7)),
    });
}

// Tile sink: feed each streamed tile into the StreamWriter (the Baker frees the
// buffer after this returns; StreamWriter gzips+copies what it keeps).
fn streamSink(ctx: ?*anyopaque, z: u8, x: u32, y: u32, mvt: []const u8) anyerror!void {
    const sw: *pmtiles.StreamWriter = @ptrCast(@alignCast(ctx.?));
    try sw.add(z, x, y, mvt);
}
