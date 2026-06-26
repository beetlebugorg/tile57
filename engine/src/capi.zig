//! C ABI for libchartplotter.a — what the C++ MapLibre host links against.
//!
//! A source is one of two backends behind the same tile API:
//!   - CHARTPLOTTER_FORMAT_PMTILES:  a PMTiles archive (Zig reader)            [M5]
//!   - CHARTPLOTTER_FORMAT_S57_CELL: a raw S-57 cell, tiles generated live     [M6c]
//! CHARTPLOTTER_FORMAT_AUTO sniffs PMTiles first, then falls back to S-57. The C++
//! ChartTileSource doesn't care which — it just calls chartplotter_tile_get.
//!
//! Contract: POD across the seam (ptr/len + status codes); Zig errors, slices
//! and optionals stay inside Zig. Public header: ../../include/chartplotter.h.

const std = @import("std");
const pmtiles = @import("pmtiles.zig");
const s57 = @import("s57.zig");
const s57_mvt = @import("s57_mvt.zig");
const portray = @import("portray.zig");

const gpa = std.heap.page_allocator;

// Env access lives in C (Zig 0.16 puts env behind Io); returns the S-101 rules
// dir from CHARTPLOTTER_S101_RULES or null.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

// Keep in sync with the CHARTPLOTTER_VERSION_* macros in chartplotter.h.
const version_string = "0.1.0";

// Mirrors chartplotter_format in chartplotter.h.
const Format = enum(c_int) { auto = 0, pmtiles = 1, s57_cell = 2 };

const CellBackend = struct {
    cell: s57.Cell,
    portrayal: ?[]?[]const u8 = null, // per-feature S-101 instruction stream
    portray_arena: ?*std.heap.ArenaAllocator = null,
};

const Backend = union(enum) {
    reader: pmtiles.Reader,
    cell: CellBackend,
    cells: []CellBackend, // ENC_ROOT: several cells, overlaid per tile
};

const Source = struct {
    backend: Backend,
    data: ?[]u8, // owned archive bytes (PMTiles backend only)
    // In-memory tile cache (key = z<<48|x<<24|y -> MVT bytes). The host renders
    // continuously and MapLibre re-requests tiles, so without this every frame
    // would re-decode (PMTiles) or re-generate (cell) the same tiles. Values are
    // owned here; chartplotter_tile_get returns a fresh copy the caller frees.
    cache: std.AutoHashMap(u64, []u8),
};

fn tileKey(z: u8, x: u32, y: u32) u64 {
    return (@as(u64, z) << 48) | (@as(u64, x) << 24) | @as(u64, y);
}

/// Return the library version string ("0.1.0").
export fn chartplotter_version() callconv(.c) [*:0]const u8 {
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
// CHARTPLOTTER_S101_RULES, else the vendored official catalogue (works when run
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
// Mirrors chartplotter_cell_input in chartplotter.h.
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
export fn chartplotter_source_open_cells(
    cells_ptr: [*]const CellInput,
    count: usize,
    rules_dir: ?[*:0]const u8,
) callconv(.c) ?*Source {
    const dir = resolveRulesDir(rules_dir);
    var list = std.ArrayList(CellBackend).empty;
    const inputs = cells_ptr[0..count];
    for (inputs) |in| {
        // Collect this cell's update buffers (.001…) into a slice for the parser.
        var ups = std.ArrayList([]const u8).empty;
        defer ups.deinit(gpa);
        if (in.updates) |uptr| if (in.update_lens) |ulen| {
            var k: usize = 0;
            while (k < in.update_count) : (k += 1) ups.append(gpa, uptr[k][0..ulen[k]]) catch break;
        };
        if (buildCellBackend(in.base[0..in.base_len], ups.items, dir)) |cb| {
            list.append(gpa, cb) catch {
                var c = cb;
                freeCellBackend(&c);
            };
        }
    }
    if (list.items.len == 0) {
        list.deinit(gpa);
        return null;
    }
    const owned = list.toOwnedSlice(gpa) catch {
        for (list.items) |*cb| freeCellBackend(cb);
        list.deinit(gpa);
        return null;
    };
    const src = gpa.create(Source) catch {
        for (owned) |*cb| freeCellBackend(cb);
        gpa.free(owned);
        return null;
    };
    src.* = .{ .backend = .{ .cells = owned }, .data = null, .cache = std.AutoHashMap(u64, []u8).init(gpa) };
    return src;
}

/// Open a chart tile source from in-memory bytes. `format` selects the backend
/// (CHARTPLOTTER_FORMAT_AUTO sniffs PMTiles then S-57); `rules_dir` is the S-101 rules dir
/// for cells (null = default). Bytes are copied. Returns a handle or null.
export fn chartplotter_source_open(
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

/// The resolved backend format (after a CHARTPLOTTER_FORMAT_AUTO sniff).
export fn chartplotter_source_format(src: ?*Source) callconv(.c) c_int {
    const s = src orelse return @intFromEnum(Format.auto);
    return switch (s.backend) {
        .reader => @intFromEnum(Format.pmtiles),
        .cell, .cells => @intFromEnum(Format.s57_cell),
    };
}

export fn chartplotter_source_close(src: ?*Source) callconv(.c) void {
    const s = src orelse return;
    switch (s.backend) {
        .reader => |*r| r.deinit(),
        .cell => |*cb| freeCellBackend(cb),
        .cells => |cbs| {
            for (cbs) |*cb| freeCellBackend(cb);
            gpa.free(cbs);
        },
    }
    var it = s.cache.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    s.cache.deinit();
    if (s.data) |d| gpa.free(d);
    gpa.destroy(s);
}

/// Min/max zoom served by the source (PMTiles: archive range; cell: 0..18).
export fn chartplotter_source_zoom_range(src: ?*Source, min_z: *u8, max_z: *u8) callconv(.c) void {
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
export fn chartplotter_source_bounds(src: ?*Source, w: *f64, s: *f64, e: *f64, n: *f64) callconv(.c) bool {
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
        .cells => |cbs| {
            var have = false;
            var u: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 }; // [w,s,e,n]
            for (cbs) |*cb| {
                const cbnd = cb.cell.bounds() orelse continue;
                u[0] = @min(u[0], cbnd[0]);
                u[1] = @min(u[1], cbnd[1]);
                u[2] = @max(u[2], cbnd[2]);
                u[3] = @max(u[3], cbnd[3]);
                have = true;
            }
            if (!have) return false;
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

/// Fetch tile (z,x,y) as MVT bytes (PMTiles: decompressed; cell: generated).
/// Returns CHARTPLOTTER_TILE_OK (1) + out/out_len (free with chartplotter_tile_free) if non-empty,
/// CHARTPLOTTER_TILE_EMPTY (0) if empty/absent, CHARTPLOTTER_TILE_ERROR (-1) on error.
export fn chartplotter_tile_get(
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
        .cells => |cbs| blk: {
            const refs = gpa.alloc(s57_mvt.CellRef, cbs.len) catch return -1;
            defer gpa.free(refs);
            for (cbs, 0..) |*cb, i| refs[i] = .{ .cell = &cb.cell, .portrayal = cb.portrayal };
            break :blk s57_mvt.generateTileMulti(gpa, refs, z, x, y) catch return -1;
        },
    };
    s.cache.put(key, bytes) catch {}; // best-effort; cache owns `bytes` on success
    if (bytes.len == 0) return 0;
    const dup = gpa.dupe(u8, bytes) catch return -1;
    out.* = dup.ptr;
    out_len.* = dup.len;
    return 1;
}

export fn chartplotter_tile_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

/// Drop the in-memory tile cache (bounds memory in long-running hosts).
export fn chartplotter_source_clear_cache(src: ?*Source) callconv(.c) void {
    const s = src orelse return;
    var it = s.cache.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    s.cache.clearRetainingCapacity();
}
