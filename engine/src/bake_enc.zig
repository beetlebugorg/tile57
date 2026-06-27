//! Streaming banded baker: turn an ENC_ROOT (many S-57 cells) into one PMTiles
//! archive. Each cell is baked only at the Web-Mercator zooms that match its
//! compilation scale (its navigational-purpose "band"), and bands are processed
//! finest → coarsest: a tile a finer band already produced is skipped, so the
//! best-available scale wins per tile (S-52 best-band display) and only ONE band's
//! parsed cells need to be held in memory at a time. Mirrors the Go reference's
//! bake.BandForScale / Band.ZoomRange + BakeToPMTilesBandsStreaming.
//!
//! Pure engine code (no Lua): the caller parses + portrays one band's cells, calls
//! Baker.bakeBand, then frees them before the next band — so peak memory tracks the
//! single largest band, not the whole catalogue. generateTileMulti encodes each
//! tile immediately, so the accumulated tiles never reference cell memory.

const std = @import("std");
const s57 = @import("s57");
const s57_mvt = @import("s57_mvt.zig");
const pmtiles = @import("pmtiles.zig");
const tile = @import("tile.zig");

/// A parsed + portrayed cell ready to bake. `portrayal` is the per-feature S-101
/// instruction stream (null = bake with the classify() fallback); `bounds` is
/// [west, south, east, north] degrees.
pub const Backend = struct {
    cell: s57.Cell,
    portrayal: ?[]const ?[]const u8 = null,
    geo: ?s57_mvt.GeoParts = null, // line/area geometry assembled once (buildGeoCache)
    bounds: [4]f64,
};

/// Native [minzoom, maxzoom] Web-Mercator span for a navigational-purpose band.
pub const ZoomRange = struct { min: u8, max: u8 };

/// Navigational-purpose bands, finest → coarsest (the order bands must be baked in
/// for best-band dedup). Mirrors chartplotter-go bake.Band.
pub const Band = enum(u8) { berthing = 0, harbor, approach, coastal, general, overview };

/// All bands finest → coarsest (the bakeBand call order).
pub const bands_fine_to_coarse = [_]Band{ .berthing, .harbor, .approach, .coastal, .general, .overview };

/// Map a compilation-scale denominator (CSCL, 1:N) to its band (Go BandForScale).
pub fn bandOf(cscl: i32) Band {
    const n: i64 = if (cscl <= 0) 50_000 else cscl;
    if (n <= 8_000) return .berthing;
    if (n <= 32_000) return .harbor;
    if (n <= 130_000) return .approach;
    if (n <= 500_000) return .coastal;
    if (n <= 2_300_000) return .general;
    return .overview;
}

/// A band's native zoom span (Go Band.ZoomRange). Adjacent bands overlap by one
/// zoom; best-band dedup resolves the overlap to the finer band.
pub fn bandZooms(band: Band) ZoomRange {
    return switch (band) {
        .berthing => .{ .min = 16, .max = 18 },
        .harbor => .{ .min = 13, .max = 16 },
        .approach => .{ .min = 11, .max = 13 },
        .coastal => .{ .min = 9, .max = 11 },
        .general => .{ .min = 7, .max = 9 },
        .overview => .{ .min = 0, .max = 7 },
    };
}

/// Whether to cache assembled geometry for a band. The fine bands have many small
/// cells that each span several tiles (big reuse, modest memory); the coarse bands
/// (general/overview) have few but huge cells (little reuse, large memory), so skip
/// caching there to keep peak memory bounded.
pub fn cacheGeoForBand(band: Band) bool {
    return @intFromEnum(band) <= @intFromEnum(Band.coastal);
}

/// Progress callback. stage 0 = loading/portraying cells (driven by the caller),
/// stage 1 = baking tiles (driven by Baker). `total` 0 means "unknown". C ABI safe.
pub const Progress = ?*const fn (ctx: ?*anyopaque, stage: u8, done: usize, total: usize) callconv(.c) void;

fn lonLatToTile(lon: f64, lat: f64, z: u8) [2]u32 {
    const w = tile.lonLatToWorld(lon, lat); // normalised [0,1], y down
    const scale: f64 = @floatFromInt(@as(u64, 1) << @intCast(z));
    const max_idx: f64 = scale - 1.0;
    const fx = std.math.clamp(@floor(w[0] * scale), 0.0, max_idx);
    const fy = std.math.clamp(@floor(w[1] * scale), 0.0, max_idx);
    return .{ @intFromFloat(fx), @intFromFloat(fy) };
}

fn toE7(v: f64) i32 {
    return @intFromFloat(@round(v * 1e7));
}

fn tileKey(z: u8, x: u32, y: u32) u64 {
    return (@as(u64, z) << 48) | (@as(u64, x) << 24) | @as(u64, y);
}

const ParCtx = struct {
    next: std.atomic.Value(usize),
    n: usize,
    user: *anyopaque,
    func: *const fn (*anyopaque, usize) void,
};

fn parWorker(pc: *ParCtx) void {
    while (true) {
        const i = pc.next.fetchAdd(1, .monotonic);
        if (i >= pc.n) return;
        pc.func(pc.user, i);
    }
}

/// Run func(user, i) for every i in [0, n) across the CPU threads. func must be
/// safe to call concurrently for distinct i (no shared mutable state). Falls back
/// to serial when there's one CPU or one item.
pub fn parallelFor(n: usize, user: *anyopaque, func: *const fn (*anyopaque, usize) void) void {
    if (n == 0) return;
    var pc = ParCtx{ .next = std.atomic.Value(usize).init(0), .n = n, .user = user, .func = func };
    const cpus = std.Thread.getCpuCount() catch 1;
    var nthreads = @min(@max(cpus, 1), n);
    if (nthreads > 64) nthreads = 64;
    if (nthreads <= 1) return parWorker(&pc);

    var threads: [64]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < nthreads - 1) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, parWorker, .{&pc}) catch break;
    }
    parWorker(&pc); // this thread participates too
    for (threads[0..spawned]) |t| t.join();
}

// Worker context for parallel per-tile MVT generation. Each index is an
// independent tile; generateTileMulti only reads the cells, so this is race-free.
const TileGenCtx = struct {
    keys: []const u64,
    idx_lists: []const []const u32,
    results: []?[]u8,
    backends: []Backend,
    gpa: std.mem.Allocator,

    fn gen(uptr: *anyopaque, i: usize) void {
        const c: *TileGenCtx = @ptrCast(@alignCast(uptr));
        const key = c.keys[i];
        const z: u8 = @intCast(key >> 48);
        const x: u32 = @intCast((key >> 24) & 0xFFFFFF);
        const y: u32 = @intCast(key & 0xFFFFFF);
        const idxs = c.idx_lists[i];
        const refs = c.gpa.alloc(s57_mvt.CellRef, idxs.len) catch return;
        defer c.gpa.free(refs);
        for (idxs, 0..) |idx, j| refs[j] = .{ .cell = &c.backends[idx].cell, .portrayal = c.backends[idx].portrayal, .geo = c.backends[idx].geo };
        const mvt_bytes = s57_mvt.generateTileMulti(c.gpa, refs, z, x, y) catch return;
        if (mvt_bytes.len > 0) c.results[i] = mvt_bytes else c.gpa.free(mvt_bytes);
    }
};

/// Accumulates the baked tiles across bands and writes the final PMTiles archive.
///
/// `gpa` MUST be a real freeing allocator (e.g. page_allocator), NOT an arena:
/// generateTileMulti creates and frees a child arena per tile, which an arena
/// backing would turn into a leak of every tile's working set.
pub const Baker = struct {
    gpa: std.mem.Allocator,
    minzoom: u8,
    maxzoom: u8,
    emitted: std.AutoHashMap(u64, void),
    tiles: std.ArrayList(pmtiles.InputTile),
    union_b: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 }, // w, s, e, n

    pub fn init(gpa: std.mem.Allocator, minzoom: u8, maxzoom: u8) Baker {
        return .{
            .gpa = gpa,
            .minzoom = minzoom,
            .maxzoom = maxzoom,
            .emitted = std.AutoHashMap(u64, void).init(gpa),
            .tiles = std.ArrayList(pmtiles.InputTile).empty,
        };
    }

    pub fn deinit(self: *Baker) void {
        for (self.tiles.items) |t| self.gpa.free(t.mvt);
        self.tiles.deinit(self.gpa);
        self.emitted.deinit();
    }

    /// Bake one band's already-parsed+portrayed cells. Tiles a finer band already
    /// emitted are skipped (call bands finest → coarsest). The cells must stay
    /// valid for the duration of this call; the caller may free them afterward.
    pub fn bakeBand(self: *Baker, band: Band, backends: []Backend, progress: Progress, ctx: ?*anyopaque) !void {
        const zr = bandZooms(band);
        const zlo = @max(self.minzoom, zr.min);
        const zhi = @min(self.maxzoom, zr.max);
        if (zlo > zhi or backends.len == 0) return;

        // Map this band's not-yet-emitted tiles -> contributing cell indices.
        var tilemap = std.AutoHashMap(u64, std.ArrayList(u32)).init(self.gpa);
        defer {
            var vit = tilemap.valueIterator();
            while (vit.next()) |v| v.deinit(self.gpa);
            tilemap.deinit();
        }
        for (backends, 0..) |be, i| {
            const b = be.bounds;
            self.union_b[0] = @min(self.union_b[0], b[0]);
            self.union_b[1] = @min(self.union_b[1], b[1]);
            self.union_b[2] = @max(self.union_b[2], b[2]);
            self.union_b[3] = @max(self.union_b[3], b[3]);
            var z = zlo;
            while (z <= zhi) : (z += 1) {
                const nw = lonLatToTile(b[0], b[3], z);
                const se = lonLatToTile(b[2], b[1], z);
                var ty = nw[1];
                while (ty <= se[1]) : (ty += 1) {
                    var tx = nw[0];
                    while (tx <= se[0]) : (tx += 1) {
                        const key = tileKey(z, tx, ty);
                        if (self.emitted.contains(key)) continue; // a finer band has it
                        const gop = try tilemap.getOrPut(key);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
                        try gop.value_ptr.append(self.gpa, @intCast(i));
                    }
                }
            }
        }

        // Generate this band's tiles in parallel (each tile independent, cells read
        // read-only), then collect serially into the shared archive state.
        const n = tilemap.count();
        const keys = try self.gpa.alloc(u64, n);
        defer self.gpa.free(keys);
        const idx_lists = try self.gpa.alloc([]const u32, n);
        defer self.gpa.free(idx_lists);
        {
            var it = tilemap.iterator();
            var j: usize = 0;
            while (it.next()) |e| : (j += 1) {
                keys[j] = e.key_ptr.*;
                idx_lists[j] = e.value_ptr.items;
            }
        }
        const results = try self.gpa.alloc(?[]u8, n);
        defer self.gpa.free(results);
        @memset(results, null);

        var tg = TileGenCtx{ .keys = keys, .idx_lists = idx_lists, .results = results, .backends = backends, .gpa = self.gpa };
        parallelFor(n, &tg, TileGenCtx.gen);

        for (keys, results) |key, mvt_opt| {
            const mvt_bytes = mvt_opt orelse continue;
            try self.tiles.append(self.gpa, .{
                .z = @intCast(key >> 48),
                .x = @intCast((key >> 24) & 0xFFFFFF),
                .y = @intCast(key & 0xFFFFFF),
                .mvt = mvt_bytes,
            });
            try self.emitted.put(key, {});
            if (progress) |cb| if (self.tiles.items.len % 256 == 0) cb(ctx, 1, self.tiles.items.len, 0);
        }
        if (progress) |cb| cb(ctx, 1, self.tiles.items.len, 0);
    }

    /// Write the accumulated tiles as a PMTiles archive (owned by the caller; free
    /// with `gpa`). A 0-length slice when nothing was baked.
    pub fn finish(self: *Baker) ![]u8 {
        if (self.tiles.items.len == 0) return self.gpa.alloc(u8, 0);
        const opts = pmtiles.WriteOptions{
            .min_lon_e7 = toE7(self.union_b[0]),
            .min_lat_e7 = toE7(self.union_b[1]),
            .max_lon_e7 = toE7(self.union_b[2]),
            .max_lat_e7 = toE7(self.union_b[3]),
        };
        return pmtiles.write(self.gpa, self.tiles.items, opts);
    }
};

test "bandOf / bandZooms match the Go reference bands" {
    try std.testing.expectEqual(Band.harbor, bandOf(12_000)); // [13,16]
    try std.testing.expectEqual(@as(u8, 13), bandZooms(bandOf(12_000)).min);
    try std.testing.expectEqual(Band.overview, bandOf(3_000_000)); // [0,7]
    try std.testing.expectEqual(Band.approach, bandOf(80_000)); // [11,13]
    try std.testing.expectEqual(Band.approach, bandOf(0)); // CSCL 0 -> 50k -> approach
    try std.testing.expectEqual(Band.coastal, bandOf(200_000)); // [9,11]
}
