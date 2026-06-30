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
const s57_mvt = @import("s57_mvt");
const pmtiles = @import("pmtiles");
const tile = @import("tile");

/// A parsed + portrayed cell ready to bake. `portrayal` is the per-feature S-101
/// instruction stream (null = bake with the classify() fallback); `bounds` is
/// [west, south, east, north] degrees.
pub const Backend = struct {
    cell: s57.Cell,
    portrayal: ?[]const ?[]const u8 = null,
    portrayal_plain: ?[]const ?[]const u8 = null, // PlainBoundaries variant (areas)
    portrayal_simplified: ?[]const ?[]const u8 = null, // SimplifiedSymbols variant (points)
    geo: ?s57_mvt.GeoParts = null, // line/area geometry assembled once (buildGeoCache)
    geo_world: ?s57_mvt.GeoWorld = null, // world coords parallel to geo (cheap reprojection)
    feat_bbox: ?[]const ?[4]f64 = null, // per-feature bbox for the per-tile spatial cull
    bounds: [4]f64,
};

/// Native [minzoom, maxzoom] Web-Mercator span for a navigational-purpose band.
pub const ZoomRange = struct { min: u8, max: u8 };

/// Restricts a bakeBand pass to the tiles under one "super-tile" (a tile at the
/// coarser zoom `zs`): only (z,x,y) with z >= zs whose ancestor at zs is (sx,sy)
/// are generated. Lets the lazy baker process a band one spatial super-tile at a
/// time — loading only the cells overlapping it — instead of the whole band.
pub const TileClip = struct { zs: u8, sx: u32, sy: u32 };

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

/// A band's native max zoom (Go covMeta.bandMax) — the "fineness" key for
/// best-band coverage suppression. Finer bands have a LARGER value (berthing 18 …
/// overview 7), so a cell is suppressed where a band with a higher max covers it.
pub fn bandMaxZoom(band: Band) u8 {
    return bandZooms(band).max;
}

/// Best-available area suppression (Go bake.go best-available rule): a coarser-band
/// cell's AREA fills/patterns yield at tile zoom `z` wherever a strictly-finer
/// band's real M_COVR data-coverage is present. `cell_natmax` is the cell's own
/// band max; `finest_cov_natmax` is the largest band-max whose coverage contains
/// the relevant test point(s), 0 = none. Suppress only when the cell is OVERZOOMED
/// past its native band (z >= its max) AND a finer band covers, so a coarse area is
/// kept everywhere a finer chart has a genuine coverage gap.
///
/// FILLS pass `finest_cov_natmax` = the MIN over the tile centre + 4 corners (Go's
/// whole-tile fill test): suppress only where a finer band covers the WHOLE tile,
/// so a partly-covered seam tile keeps its coarse fill and the finer fill (drawn on
/// top via the band sort-key) occludes it — no seam gap, no visible cross-band fill.
/// PATTERNS pass the tile-centre value: area_patterns draw ABOVE all fills, so a
/// coarse pattern must yield wherever finer data exists or it laps over finer land;
/// a pattern dropped on a thin seam is harmless (the underlying fill remains).
pub fn coarseAreaSuppressed(cell_natmax: u8, z: u8, finest_cov_natmax: u8) bool {
    return z >= cell_natmax and cell_natmax < finest_cov_natmax;
}

/// Whether to cache assembled geometry for a band. The fine bands have many small
/// cells that each span several tiles (big reuse, modest memory); the coarse bands
/// (general/overview) have few but huge cells (little reuse, large memory), so skip
/// caching there to keep peak memory bounded.
pub fn cacheGeoForBand(band: Band) bool {
    return @intFromEnum(band) <= @intFromEnum(Band.coastal);
}

/// Progress callback. stage 0 = loading/portraying cells (driven by the caller),
/// stage 1 = baking tiles (driven by Baker). For stage 1 `done`/`total` are PER BAND
/// (reset each band): done = tiles baked in the current band, total = the band's
/// planned tile count when the caller set Baker.band_total (else 0 = "unknown", the
/// pre-host-§3 behaviour). The caller (bundle bake-root) sets band_base/band_total
/// per band so a host import UI can show a per-band percentage.
///
/// `band_index`/`band_count` (host §3 band label) locate the current band among the
/// bands actually being baked (0-based index, count = how many bands have cells), so
/// the host can show "band 3/6"; `band_name` is its navigational-purpose name
/// ("berthing"…"overview", a static NUL-terminated string), or null for stage 0
/// (loading spans all bands). The caller sets Baker.band_index/band_count per band.
/// C ABI safe.
pub const Progress = ?*const fn (ctx: ?*anyopaque, stage: u8, done: usize, total: usize, band_index: u8, band_count: u8, band_name: ?[*:0]const u8) callconv(.c) void;

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
    func: *const fn (*anyopaque, usize, std.mem.Allocator) void,
    gpa: std.mem.Allocator,
};

// Each worker owns ONE scratch arena, reset (capacity retained) after every item,
// so per-item working memory reuses the same pages instead of re-mmaping a fresh
// arena per call — the bake's per-tile allocations were churning millions of page
// faults. The callee must not retain anything from `scratch` past its own return.
fn parWorker(pc: *ParCtx) void {
    var arena = std.heap.ArenaAllocator.init(pc.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    while (true) {
        const i = pc.next.fetchAdd(1, .monotonic);
        if (i >= pc.n) return;
        pc.func(pc.user, i, scratch);
        _ = arena.reset(.retain_capacity);
    }
}

/// Run func(user, i, scratch) for every i in [0, n) across the CPU threads. func
/// must be safe to call concurrently for distinct i (no shared mutable state).
/// `scratch` is a per-thread arena reset between items — use it for transient
/// per-item memory; copy anything that must outlive the call into a real
/// allocator. `gpa` backs those scratch arenas. Falls back to serial when there's
/// one CPU or one item.
pub fn parallelFor(gpa: std.mem.Allocator, n: usize, user: *anyopaque, func: *const fn (*anyopaque, usize, std.mem.Allocator) void) void {
    if (n == 0) return;
    var pc = ParCtx{ .next = std.atomic.Value(usize).init(0), .n = n, .user = user, .func = func, .gpa = gpa };
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
    format: s57_mvt.TileFormat = .mvt,
    pick_attrs: bool = true, // emit the per-feature pick-report attrs (s57/cell); off = lean tiles
    // Live progress emitted from inside the parallel batch (so a big super-tile
    // shows tiles flowing rather than appearing hung). `done` counts processed
    // tiles; `base` is the emitted count before this batch.
    progress: Progress = null,
    pctx: ?*anyopaque = null,
    base: usize = 0, // self.count at this super-tile's start (cumulative)
    band_base: usize = 0, // self.count at the band's start (for the per-band done)
    band_total: usize = 0, // the band's planned tile total (0 = unknown)
    band_index: u8 = 0, // 0-based ordinal of the current band among baking bands
    band_count: u8 = 0, // number of bands being baked (for "band i/n")
    band_name: ?[*:0]const u8 = null, // the band's navigational-purpose name
    done: ?*std.atomic.Value(usize) = null,

    fn gen(uptr: *anyopaque, i: usize, scratch: std.mem.Allocator) void {
        const c: *TileGenCtx = @ptrCast(@alignCast(uptr));
        const key = c.keys[i];
        const z: u8 = @intCast(key >> 48);
        const x: u32 = @intCast((key >> 24) & 0xFFFFFF);
        const y: u32 = @intCast(key & 0xFFFFFF);
        const idxs = c.idx_lists[i];
        // refs + the encoded tile are transient (gzipped right below), so they ride
        // the per-thread scratch arena — reset after this tile, no per-tile mmap.
        const refs = scratch.alloc(s57_mvt.CellRef, idxs.len) catch return;
        for (idxs, 0..) |idx, j| refs[j] = .{ .cell = &c.backends[idx].cell, .portrayal = c.backends[idx].portrayal, .portrayal_plain = c.backends[idx].portrayal_plain, .portrayal_simplified = c.backends[idx].portrayal_simplified, .geo = c.backends[idx].geo, .geo_world = c.backends[idx].geo_world, .feat_bbox = c.backends[idx].feat_bbox };
        const mvt_bytes = s57_mvt.generateTileMulti(scratch, scratch, refs, z, x, y, c.format, c.pick_attrs) catch return;
        // Gzip here, in the worker — the expensive step done in parallel; the serial
        // collection then only dedups + writes the already-compressed tile. The
        // gzipped result must outlive the scratch reset, so it comes from `c.gpa`.
        if (mvt_bytes.len > 0) c.results[i] = pmtiles.StreamWriter.gzipTile(c.gpa, mvt_bytes) catch null;
        if (c.done) |d| {
            const n = d.fetchAdd(1, .monotonic) + 1;
            // Per-band tile bar: done = tiles done in this band so far, total = the
            // band's planned tile count (host §3). Live updates from inside the
            // parallel batch so a big super-tile shows movement.
            if (c.progress) |cb| if (n % 1024 == 0) cb(c.pctx, 1, (c.base - c.band_base) + n, c.band_total, c.band_index, c.band_count, c.band_name);
        }
    }
};

/// Accumulates the baked tiles across bands and writes the final PMTiles archive.
///
/// `gpa` MUST be a real freeing allocator (e.g. page_allocator), NOT an arena:
/// generateTileMulti creates and frees a child arena per tile, which an arena
/// backing would turn into a leak of every tile's working set.
/// Receives each baked tile as it is produced. The Baker frees `mvt` right after
/// the call, so the sink must consume/copy what it keeps. This keeps the bake
/// streaming — tiles never accumulate in the Baker — so a low-memory consumer can
/// write tile data straight to disk (see the CLI), while an in-RAM consumer can
/// still collect them (see the C ABI bake). bake_enc stays pure (no fs); the sink
/// owns any I/O.
pub const TileSink = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, z: u8, x: u32, y: u32, mvt: []const u8) anyerror!void,
};

pub const Baker = struct {
    gpa: std.mem.Allocator,
    minzoom: u8,
    maxzoom: u8,
    emitted: std.AutoHashMap(u64, void),
    sink: TileSink,
    count: usize = 0, // tiles handed to the sink (cumulative across bands)
    union_b: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 }, // w, s, e, n
    format: s57_mvt.TileFormat = .mvt, // output tile encoding (mvt default; mlt optional)
    pick_attrs: bool = true, // emit per-feature pick-report attrs (s57/cell); off = lean tiles
    // Progress denominator (host §3): the caller sets these PER BAND before baking it
    // so the tiles-stage callback can report `done`/`total` as a per-band tile bar
    // (done = self.count - band_base; total = band_total, a planned estimate from
    // plannedTiles). band_total 0 => "unknown" (callback reports total 0, as before).
    band_base: usize = 0,
    band_total: usize = 0,
    // Band label (host §3): the caller sets these per band so the progress callback
    // can report "band <index+1>/<count> <name>". band_name comes from @tagName(band)
    // inside bakeBand; index/count are the ordinal among bands that actually bake.
    band_index: u8 = 0,
    band_count: u8 = 0,

    pub fn init(gpa: std.mem.Allocator, minzoom: u8, maxzoom: u8, sink: TileSink) Baker {
        return .{
            .gpa = gpa,
            .minzoom = minzoom,
            .maxzoom = maxzoom,
            .emitted = std.AutoHashMap(u64, void).init(gpa),
            .sink = sink,
        };
    }

    pub fn deinit(self: *Baker) void {
        self.emitted.deinit();
    }

    /// Union bbox of the baked cells (w, s, e, n) — for the archive header.
    pub fn unionBounds(self: *const Baker) [4]f64 {
        return self.union_b;
    }

    /// Bake one band's already-parsed+portrayed cells. Tiles a finer band already
    /// emitted are skipped (call bands finest → coarsest). The cells must stay
    /// valid for the duration of this call; the caller may free them afterward.
    /// Build the tile→contributing-bounds-index map for one band: every not-yet-
    /// emitted (z,x,y) over [minzoom..maxzoom]∩band, clipped to the super-tile when
    /// `clip` is set. Shared by bakeBand (to bake) and plannedTiles (to count) so the
    /// progress denominator can't drift from what's actually baked. `bounds[i]` =
    /// [w,s,e,n]; the map values index into it. Caller frees the value lists + the map.
    fn buildTileMap(self: *Baker, band: Band, bounds: []const [4]f64, clip: ?TileClip) !std.AutoHashMap(u64, std.ArrayList(u32)) {
        const zr = bandZooms(band);
        const zlo = @max(self.minzoom, zr.min);
        const zhi = @min(self.maxzoom, zr.max);
        var tilemap = std.AutoHashMap(u64, std.ArrayList(u32)).init(self.gpa);
        errdefer {
            var vit = tilemap.valueIterator();
            while (vit.next()) |v| v.deinit(self.gpa);
            tilemap.deinit();
        }
        if (zlo > zhi) return tilemap;
        for (bounds, 0..) |b, i| {
            var z = zlo;
            while (z <= zhi) : (z += 1) {
                const nw = lonLatToTile(b[0], b[3], z);
                const se = lonLatToTile(b[2], b[1], z);
                // Clamp the cell's tile span to the super-tile's tile range at z
                // (clip.zs <= zlo <= z, so the shift is non-negative).
                var xlo = nw[0];
                var xhi = se[0];
                var ylo = nw[1];
                var yhi = se[1];
                if (clip) |cl| {
                    const shift: u5 = @intCast(z - cl.zs);
                    xlo = @max(xlo, cl.sx << shift);
                    xhi = @min(xhi, ((cl.sx + 1) << shift) - 1);
                    ylo = @max(ylo, cl.sy << shift);
                    yhi = @min(yhi, ((cl.sy + 1) << shift) - 1);
                }
                var ty = ylo;
                while (ty <= yhi) : (ty += 1) {
                    var tx = xlo;
                    while (tx <= xhi) : (tx += 1) {
                        const key = tileKey(z, tx, ty);
                        if (self.emitted.contains(key)) continue; // a finer band has it
                        const gop = try tilemap.getOrPut(key);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
                        try gop.value_ptr.append(self.gpa, @intCast(i));
                    }
                }
            }
        }
        return tilemap;
    }

    /// Planned tile count for a band's cells (host §3 progress denominator): the
    /// distinct not-yet-emitted tiles their bounds cover. A planned ESTIMATE — the
    /// caller may pass cheap peek-bboxes while the real bake uses slightly tighter
    /// loaded bounds — matching the Go baker's up-front planned count. 0 on OOM.
    pub fn plannedTiles(self: *Baker, band: Band, bounds: []const [4]f64, clip: ?TileClip) usize {
        var tm = self.buildTileMap(band, bounds, clip) catch return 0;
        defer {
            var vit = tm.valueIterator();
            while (vit.next()) |v| v.deinit(self.gpa);
            tm.deinit();
        }
        return tm.count();
    }

    pub fn bakeBand(self: *Baker, band: Band, backends: []Backend, clip: ?TileClip, progress: Progress, ctx: ?*anyopaque) !void {
        const zr = bandZooms(band);
        const zlo = @max(self.minzoom, zr.min);
        const zhi = @min(self.maxzoom, zr.max);
        if (zlo > zhi or backends.len == 0) return;

        // Cell bounds (drive the tile map) + the running union bbox for the header.
        const bounds = try self.gpa.alloc([4]f64, backends.len);
        defer self.gpa.free(bounds);
        for (backends, 0..) |be, i| {
            bounds[i] = be.bounds;
            self.union_b[0] = @min(self.union_b[0], be.bounds[0]);
            self.union_b[1] = @min(self.union_b[1], be.bounds[1]);
            self.union_b[2] = @max(self.union_b[2], be.bounds[2]);
            self.union_b[3] = @max(self.union_b[3], be.bounds[3]);
        }

        // Map this band's not-yet-emitted tiles -> contributing cell indices.
        var tilemap = try self.buildTileMap(band, bounds, clip);
        defer {
            var vit = tilemap.valueIterator();
            while (vit.next()) |v| v.deinit(self.gpa);
            tilemap.deinit();
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

        // The band's navigational-purpose name for the progress label (static,
        // NUL-terminated — @tagName is a comptime string literal, safe across the ABI).
        const bname: [*:0]const u8 = @tagName(band).ptr;
        var done = std.atomic.Value(usize).init(0);
        var tg = TileGenCtx{ .keys = keys, .idx_lists = idx_lists, .results = results, .backends = backends, .gpa = self.gpa, .format = self.format, .pick_attrs = self.pick_attrs, .progress = progress, .pctx = ctx, .base = self.count, .band_base = self.band_base, .band_total = self.band_total, .band_index = self.band_index, .band_count = self.band_count, .band_name = bname, .done = &done };
        parallelFor(self.gpa, n, &tg, TileGenCtx.gen);

        for (keys, results) |key, mvt_opt| {
            const mvt_bytes = mvt_opt orelse continue;
            defer self.gpa.free(mvt_bytes); // streamed: the sink copies what it keeps
            try self.sink.func(self.sink.ctx, @intCast(key >> 48), @intCast((key >> 24) & 0xFFFFFF), @intCast(key & 0xFFFFFF), mvt_bytes);
            try self.emitted.put(key, {});
            self.count += 1;
            // Per-band tile bar (host §3): done = tiles done in this band, total = the
            // band's planned count the caller set (0 = unknown -> total 0, as before).
            if (progress) |cb| if (self.count % 256 == 0) cb(ctx, 1, self.count - self.band_base, self.band_total, self.band_index, self.band_count, bname);
        }
        if (progress) |cb| cb(ctx, 1, self.count - self.band_base, self.band_total, self.band_index, self.band_count, bname);
    }
};

test "coarseAreaSuppressed: finer coverage suppresses overzoomed coarse area" {
    const gen = bandMaxZoom(.general); // 9
    const app = bandMaxZoom(.approach); // 13
    // z within the coarse band's native range: never suppressed.
    try std.testing.expect(!coarseAreaSuppressed(gen, 8, app));
    // z past the coarse band's max, finer (approach) coverage present: suppressed.
    try std.testing.expect(coarseAreaSuppressed(gen, 12, app));
    // z past the coarse band's max but NO finer coverage (0): kept (best-available).
    try std.testing.expect(!coarseAreaSuppressed(gen, 12, 0));
    // The finer cell itself is never suppressed by an equal-or-coarser band.
    try std.testing.expect(!coarseAreaSuppressed(app, 18, gen));
    try std.testing.expect(!coarseAreaSuppressed(app, 18, app));
}

test "bandOf / bandZooms match the Go reference bands" {
    try std.testing.expectEqual(Band.harbor, bandOf(12_000)); // [13,16]
    try std.testing.expectEqual(@as(u8, 13), bandZooms(bandOf(12_000)).min);
    try std.testing.expectEqual(Band.overview, bandOf(3_000_000)); // [0,7]
    try std.testing.expectEqual(Band.approach, bandOf(80_000)); // [11,13]
    try std.testing.expectEqual(Band.approach, bandOf(0)); // CSCL 0 -> 50k -> approach
    try std.testing.expectEqual(Band.coastal, bandOf(200_000)); // [9,11]
}
