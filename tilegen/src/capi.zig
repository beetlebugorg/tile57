//! C ABI for libtilegen.a — what the C++ MapLibre host links against.
//!
//! A source is one of two backends behind the same tile API:
//!   - tg_open_bytes:      a PMTiles archive (Zig reader)            [M5]
//!   - tg_open_cell_bytes: a raw S-57 cell, tiles generated live     [M6c]
//! The C++ ZigTileSource doesn't care which — it just calls tg_get_tile.
//!
//! Contract: POD across the seam (ptr/len + error codes); Zig errors, slices
//! and optionals stay inside Zig. Header: ../../include/tilegen.h.

const std = @import("std");
const pmtiles = @import("pmtiles.zig");
const s57 = @import("s57.zig");
const s57_mvt = @import("s57_mvt.zig");
const portray = @import("portray.zig");

const gpa = std.heap.page_allocator;

// Env access lives in C (Zig 0.16 puts env behind Io); returns the S-101 rules
// dir or null.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

const CellBackend = struct {
    cell: s57.Cell,
    portrayal: ?[]?[]const u8 = null, // per-feature S-101 instruction stream
    portray_arena: ?*std.heap.ArenaAllocator = null,
};

const Backend = union(enum) {
    reader: pmtiles.Reader,
    cell: CellBackend,
};

const Source = struct {
    backend: Backend,
    data: ?[]u8, // owned archive bytes (PMTiles backend only)
    // In-memory tile cache (key = z<<48|x<<24|y -> MVT bytes). The host renders
    // continuously and MapLibre re-requests tiles, so without this every frame
    // would re-decode (PMTiles) or re-generate (cell) the same tiles. Values are
    // owned here; tg_get_tile returns a fresh copy the caller frees.
    cache: std.AutoHashMap(u64, []u8),
};

fn tileKey(z: u8, x: u32, y: u32) u64 {
    return (@as(u64, z) << 48) | (@as(u64, x) << 24) | @as(u64, y);
}

/// Open a PMTiles archive from in-memory bytes. Returns a handle or null.
export fn tg_open_bytes(data_ptr: [*]const u8, data_len: usize) callconv(.c) ?*Source {
    const copy = gpa.dupe(u8, data_ptr[0..data_len]) catch return null;
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

/// Open a raw S-57 cell; tiles are generated live. Returns a handle or null.
/// The bytes are only read during this call (the cell model copies what it keeps).
export fn tg_open_cell_bytes(data_ptr: [*]const u8, data_len: usize) callconv(.c) ?*Source {
    const cell = s57.parseCell(gpa, data_ptr[0..data_len]) catch return null;
    const src = gpa.create(Source) catch {
        var c = cell;
        c.deinit();
        return null;
    };
    src.* = .{ .backend = .{ .cell = .{ .cell = cell } }, .data = null, .cache = std.AutoHashMap(u64, []u8).init(gpa) };

    // Optional S-101 portrayal: if a rules directory is set, run the rules once
    // and cache per-feature instruction streams. Falls back to classify() if
    // unset or on error.
    // S-101 portrayal: rules dir from TG_S101_RULES, else the vendored official
    // catalogue submodule (works when run from the repo root). Falls back to
    // classify() if the rules aren't found.
    {
        const dir: []const u8 = if (tg_env_rules()) |dirz|
            std.mem.span(dirz)
        else
            "vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules";
        const pa = gpa.create(std.heap.ArenaAllocator) catch return src;
        pa.* = std.heap.ArenaAllocator.init(gpa);
        const cb = &src.backend.cell;
        if (portray.portrayCell(pa.allocator(), &cb.cell, dir)) |res| {
            cb.portrayal = res;
            cb.portray_arena = pa;
        } else |_| {
            pa.deinit();
            gpa.destroy(pa);
        }
    }
    return src;
}

export fn tg_close(src: ?*Source) callconv(.c) void {
    const s = src orelse return;
    switch (s.backend) {
        .reader => |*r| r.deinit(),
        .cell => |*cb| {
            cb.cell.deinit();
            if (cb.portray_arena) |pa| {
                pa.deinit();
                gpa.destroy(pa);
            }
        },
    }
    var it = s.cache.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    s.cache.deinit();
    if (s.data) |d| gpa.free(d);
    gpa.destroy(s);
}

export fn tg_min_zoom(src: ?*Source) callconv(.c) u8 {
    const s = src orelse return 0;
    return switch (s.backend) {
        .reader => |r| r.header.min_zoom,
        .cell => 0,
    };
}
export fn tg_max_zoom(src: ?*Source) callconv(.c) u8 {
    const s = src orelse return 0;
    return switch (s.backend) {
        .reader => |r| r.header.max_zoom,
        .cell => 18,
    };
}

/// Geographic bounds of the source (west,south,east,north degrees); returns true
/// when known. Lets a host frame the data with its own fit-to-window logic
/// (MapLibre's cameraForLatLngBounds) rather than a guessed center+zoom.
/// PMTiles -> the archive's stored bounds; cell -> the data extent.
export fn tg_bounds(src: ?*Source, w: *f64, s: *f64, e: *f64, n: *f64) callconv(.c) bool {
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
/// Returns 1 + out/out_len (free with tg_free) if non-empty, 0 if empty/absent,
/// negative on error.
export fn tg_get_tile(
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
        const dup = gpa.dupe(u8, cached) catch return -2;
        out.* = dup.ptr;
        out_len.* = dup.len;
        return 1;
    }

    // Miss: generate/decode once, then cache the canonical bytes (even empty, so
    // empty tiles aren't recomputed every frame).
    const bytes: []u8 = switch (s.backend) {
        .reader => |*r| (r.getTile(gpa, z, x, y) catch return -2) orelse (gpa.alloc(u8, 0) catch return -2),
        .cell => |*cb| s57_mvt.generateTile(gpa, &cb.cell, z, x, y, cb.portrayal) catch return -2,
    };
    s.cache.put(key, bytes) catch {}; // best-effort; cache owns `bytes` on success
    if (bytes.len == 0) return 0;
    const dup = gpa.dupe(u8, bytes) catch return -2;
    out.* = dup.ptr;
    out_len.* = dup.len;
    return 1;
}

export fn tg_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}
