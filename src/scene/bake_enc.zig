//! Streaming banded baker: turn an ENC_ROOT (many S-57 cells) into one PMTiles
//! archive. Each cell is baked only at the Web-Mercator zooms that match its
//! compilation scale (its navigational-purpose "band"), and bands are processed
//! finest → coarsest: a tile a finer band already produced is skipped, so the
//! best-available scale wins per tile (S-52 best-band display). Mirrors the Go
//! reference's bake.BandForScale / Band.ZoomRange + BakeToPMTilesBandsStreaming.
//!
//! Band handoff: a band's FLOOR-zoom tiles (the zoom it shares with the
//! next-coarser band) are NOT baked in its own pass — they are deferred into the
//! coarser band's pass, which bakes them with BOTH bands' cells alive, carrying
//! the coarser band down scamin-aware (carryGate/`smax`) so the band boundary has
//! no blank window while the finer band's SCAMIN-gated bulk is still hidden.
//!
//! Pure engine code (no Lua): the caller parses + portrays one band's cells, calls
//! Baker.bakeBand, and frees them after the NEXT-coarser band's pass (the carry) —
//! so peak memory tracks the two largest adjacent bands, not the whole catalogue.
//! encodeTile encodes each tile immediately, so the accumulated tiles never
//! reference cell memory.

const std = @import("std");
const s57 = @import("s57");
const scene = @import("scene.zig");
const pmtiles = @import("tiles").pmtiles;
const tile = @import("tiles").tile;
const assets = @import("assets"); // displayDenomZ: the physical display-scale formula

/// A parsed + portrayed cell ready to bake. `portrayal` is the per-feature S-101
/// instruction stream (null = bake with the classify() fallback); `bounds` is
/// [west, south, east, north] degrees.
pub const Backend = struct {
    cell: s57.Cell,
    portrayal: ?[]const ?[]const u8 = null,
    portrayal_plain: ?[]const ?[]const u8 = null, // PlainBoundaries variant (areas)
    portrayal_simplified: ?[]const ?[]const u8 = null, // SimplifiedSymbols variant (points)
    geo: ?scene.GeoParts = null, // line/area geometry assembled once (buildGeoCache)
    geo_world: ?scene.GeoWorld = null, // world coords parallel to geo (cheap reprojection)
    feat_bbox: ?[]const ?[4]f64 = null, // per-feature bbox for the per-tile spatial cull
    bounds: [4]f64,
    cscl: i32 = 0, // compilation-scale denominator (1:N); 0 = unknown
    // M_COVR(CATCOV=1) coverage polygons (cell.mcovrCoverage), for per-scale cell
    // quilting: where a strictly-finer-CSCL cell's coverage contains a location, the
    // coarser cell is suppressed there (the finer owns it; coarse only fills holes).
    coverage: []const []const []const s57.LonLat = &.{},
    // The cell's distinct SCAMIN denominators, ascending (collectScamins) — the
    // scamin-ladder slice the band-handoff carry-down quantizes `smax` onto (see
    // quantizeHandoff). Empty = the cell carries no SCAMIN (quantize falls back to
    // the covering cell's raw CSCL).
    scamins: []const u32 = &.{},
    // SCAMIN standalone (scene.scamin_pts): per-feature smax caps for an overlay
    // mini-cell Backend (Baker.overlay); null for regular cells.
    feat_smax: ?[]const i64 = null,
};

/// The finest (smallest 1:N) compilation scale among `backends[idxs]` whose coverage
/// contains (lon,lat); `maxInt` when none — so `finestCsclAt(...) < my_cscl` means "a
/// strictly finer cell covers this point" (a cell never undercuts itself: its own
/// cscl isn't < its own cscl). A cell with no M_COVR uses its bbox as coverage only
/// when `include_derived` (the Go rule: derived extents count for points/lines, never
/// fills). cscl<=0 (unknown) can't be a finer owner.
fn finestCsclAt(backends: []const Backend, idxs: []const u32, lon: f64, lat: f64, include_derived: bool) i32 {
    var best: i32 = std.math.maxInt(i32);
    for (idxs) |i| {
        const be = &backends[i];
        if (be.cscl <= 0 or be.cscl >= best) continue;
        const covered = if (be.coverage.len > 0)
            s57.coverageContains(be.coverage, lon, lat)
        else
            include_derived and (lon >= be.bounds[0] and lon <= be.bounds[2] and lat >= be.bounds[1] and lat <= be.bounds[3]);
        if (covered) best = be.cscl;
    }
    return best;
}

/// A parsed cell's distinct SCAMIN denominators, sorted ascending — its slice of
/// the archive's scamin ladder, kept per Backend/cell so the band-handoff can
/// quantize `smax` onto values that really exist (see quantizeHandoff). Allocated
/// in `a` (callers use the cell's own arena so the list lives exactly as long as
/// the cell).
pub fn collectScamins(a: std.mem.Allocator, cell: *const s57.Cell) ![]const u32 {
    var vals = std.ArrayList(u32).empty;
    for (cell.features) |f| {
        const sc = scene.featureScamin(f) orelse continue;
        const v: u32 = @intCast(sc);
        // Features repeat the same handful of denominators; a linear dedup over the
        // small distinct set beats hashing per feature.
        if (std.mem.indexOfScalar(u32, vals.items, v) == null) try vals.append(a, v);
    }
    std.mem.sort(u32, vals.items, {}, std.sort.asc(u32));
    return vals.toOwnedSlice(a);
}

/// The band-handoff denominator for a coarser cell yielding to finer coverage of
/// compilation scale `cscl_fine`: the smallest SCAMIN denominator >= cscl_fine
/// among the participating cells' ladders (the crossing at which the finer cell's
/// own gated bulk activates — the exact moment the carried copy must hand off),
/// falling back to the raw cscl_fine when no ladder value reaches it. Quantizing
/// UP onto a real ladder value keeps the client's crossing ladder unchanged and
/// the handoff aligned to a crossing; an off-ladder smax would hand off late by
/// up to one ladder gap.
pub fn quantizeHandoff(ladders: []const []const u32, cscl_fine: i32) i64 {
    if (cscl_fine <= 0) return cscl_fine;
    const want: u32 = @intCast(cscl_fine);
    var best: i64 = std.math.maxInt(i64);
    for (ladders) |vals| {
        // vals is ascending: the first value >= cscl_fine is this cell's candidate.
        for (vals) |v| {
            if (v >= want) {
                if (v < best) best = v;
                break;
            }
        }
    }
    return if (best == std.math.maxInt(i64)) cscl_fine else best;
}

/// One cell's per-tile quilting decision against the finest covering finer-scale
/// coverage — shared by the baker (TileGenCtx.gen) and the live path (chart.zig
/// tileRefs) so the two can't drift. `gf_centre` / `gf_whole` are finestCsclAt
/// results (centre incl. derived extents / max over centre+corners, real M_COVR
/// only); `display_denom` is the tile's display-window shallow end D(z, φ_tile).
pub const CellGate = struct {
    suppress_centre: bool = false, // line strokes + area patterns (tile-centre rule)
    suppress_whole: bool = false, // fills + points/text (whole-tile rule)
    smax: i64 = 0, // carry-down handoff denominator tag; 0 = not carried
};

/// Scamin-aware carry-down (band handoff): where a strictly-finer-CSCL cell's
/// coverage owns the tile, the coarser cell is normally suppressed — but that is
/// SCAMIN-blind: in the window where the display is still coarser than the finer
/// cell's compilation scale (display_denom > cscl_fine), the finer content is
/// largely SCAMIN-hidden and suppression leaves a hole (the band-floor blank).
/// There the coarse cell is INCLUDED instead, tagged `smax` = the quantized
/// handoff denominator, so the client hides the copy the moment the display gets
/// finer than the handoff. The carry is skipped (plain suppression) when even the
/// quantized handoff can't display inside this tile's window (display_denom <=
/// smax) — the copy would be dead weight in the tile.
pub fn carryGate(cscl: i32, gf_centre: i32, gf_whole: i32, display_denom: f64, ladders: []const []const u32) CellGate {
    var g = CellGate{
        .suppress_centre = cscl > 0 and gf_centre < cscl, // a finer cell covers the centre
        .suppress_whole = cscl > 0 and gf_whole < cscl, // a finer cell covers the whole tile
    };
    // Prefer the whole-tile gate's handoff (fills + points, the visible bulk); a
    // centre-only carry (seam tiles) falls back to the centre gate's scale.
    if (g.suppress_whole) {
        const h = quantizeHandoff(ladders, gf_whole);
        if (display_denom > @as(f64, @floatFromInt(h))) {
            g.suppress_whole = false;
            g.smax = h;
        }
    }
    if (g.suppress_centre) {
        const h = quantizeHandoff(ladders, gf_centre);
        if (display_denom > @as(f64, @floatFromInt(h))) {
            g.suppress_centre = false;
            if (g.smax == 0) g.smax = h;
        }
    }
    return g;
}

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

/// What a band's pass does with its own FLOOR zoom (bandZooms(band).min — the
/// zoom it shares with the next-coarser band):
///   .defer_down — skip it: the caller runs the next-coarser band's pass with
///     this band's cells still alive (its carry slice, bakeBand `own_len`), so
///     the floor tiles bake there with BOTH bands' cells and the coarser band
///     carries down scamin-aware (the band handoff). No-op when the floor sits
///     outside the archive's zoom clamp (nothing here bakes it).
///   .extend_min — the other end of the ladder: this is the archive's COARSEST
///     populated band, no coarser pass exists to defer into, so it keeps its
///     floor AND fills every zoom down to Baker.minzoom (the live tileRefs
///     coarsest-band fallback — a pack without overview cells still gets
///     low-zoom tiles instead of blank basemap).
pub const FloorMode = enum { defer_down, extend_min };

/// Whether a .defer_down band's floor tiles actually land in the next-coarser
/// pass — i.e. the floor zoom survives the archive clamp. When true the caller
/// must keep this band's cells alive as the next pass's carry slice; when false
/// nothing was deferred and the cells can be freed at the end of their own pass.
pub fn floorDeferred(band: Band, minzoom: u8, maxzoom: u8) bool {
    const f = bandZooms(band).min;
    return f >= minzoom and f <= maxzoom;
}

/// Whether a band's pass has any zoom to bake under the archive clamp: its own
/// (floor-adjusted) range, or the deferred floor tiles its carry cells bring in.
/// The caller-side guard for running (and progress-labelling) a pass — a band
/// with no own cells still runs when the finer band deferred its floor here.
pub fn passHasWork(band: Band, minzoom: u8, maxzoom: u8, own_n: usize, carry_n: usize, floor: FloorMode) bool {
    const zr = bandZooms(band);
    if (own_n > 0) {
        var zlo = @max(minzoom, zr.min);
        const zhi = @min(maxzoom, zr.max);
        switch (floor) {
            .defer_down => if (zlo == zr.min and zlo <= zhi) {
                zlo += 1;
            },
            .extend_min => zlo = minzoom,
        }
        if (zlo <= zhi) return true;
    }
    return carry_n > 0 and zr.max >= minzoom and zr.max <= maxzoom;
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
// independent tile; encodeTile only reads the cells, so this is race-free.
const TileGenCtx = struct {
    keys: []const u64,
    idx_lists: []const []const u32,
    results: []?[]u8,
    backends: []Backend,
    gpa: std.mem.Allocator,
    format: scene.TileFormat = .mvt,
    pick_attrs: bool = true, // emit the per-feature pick-report attrs (s57/cell); off = lean tiles
    // SCAMIN standalone (Baker.overlay/scamin_standalone): the deduped SCAMIN
    // point mini cells joining EVERY tile by per-feature scale-window
    // eligibility, and the flag that makes regular cells skip their own copies.
    overlay: []const Backend = &.{},
    standalone: bool = false,
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
        // Per-scale cell quilting: where a strictly-finer-CSCL cell's M_COVR coverage
        // contains a location, the coarser cell is suppressed there (so two cells of
        // different scale that both digitise a feature don't double-draw it). The
        // finest cscl covering the tile CENTRE gates lines/patterns (+ derived bbox
        // extents); fills/points need a finer cell over ALL of centre+4 corners (no
        // derived) so a partial seam keeps the coarse fill (no no-data hole).
        // Suppression is scamin-AWARE (carryGate): where the tile's display window
        // still opens coarser than the covering finer cell's compilation scale, the
        // coarser cell rides along tagged with the `smax` handoff denominator
        // instead — the band-floor blank-window fix.
        const tbll = tile.tileBoundsLonLat(z, x, y); // [minlon, minlat, maxlon, maxlat]
        const clon = (tbll[0] + tbll[2]) * 0.5;
        const clat = (tbll[1] + tbll[3]) * 0.5;
        const gf_centre_d = finestCsclAt(c.backends, idxs, clon, clat, true);
        var gf_whole: i32 = finestCsclAt(c.backends, idxs, clon, clat, false);
        const corners = [4][2]f64{ .{ tbll[0], tbll[1] }, .{ tbll[2], tbll[1] }, .{ tbll[0], tbll[3] }, .{ tbll[2], tbll[3] } };
        for (corners) |cn| gf_whole = @max(gf_whole, finestCsclAt(c.backends, idxs, cn[0], cn[1], false));
        // The display window's shallow end for a tile at zoom z: D(z, φ_tile). The
        // participating cells' SCAMIN ladders quantize the handoff (quantizeHandoff).
        const display_denom = assets.displayDenomZ(z, clat);
        const ladders = scratch.alloc([]const u32, idxs.len) catch return;
        for (idxs, 0..) |idx, j| ladders[j] = c.backends[idx].scamins;

        // refs + the encoded tile are transient (gzipped right below), so they ride
        // the per-thread scratch arena — reset after this tile, no per-tile mmap.
        // SCAMIN-standalone overlay (specs/scamin-standalone.md): the deduped
        // SCAMIN point mini cells join EVERY tile whose bounds they touch —
        // independent of bands/emitted-skip — gated per feature by the tile's
        // display window (scamin_floor = D(z+1, φ_tile); the CellRef clamp).
        // Padded by one tile so a light's sector legs/arcs reach neighbours
        // (mirrors the LIGHT_AUG_REACH margin in the feature cull).
        const pad_lon = tbll[2] - tbll[0];
        const pad_lat = tbll[3] - tbll[1];
        var n_ov: usize = 0;
        for (c.overlay) |*ov| {
            if (ov.bounds[0] <= tbll[2] + pad_lon and ov.bounds[2] >= tbll[0] - pad_lon and
                ov.bounds[1] <= tbll[3] + pad_lat and ov.bounds[3] >= tbll[1] - pad_lat) n_ov += 1;
        }
        const refs = scratch.alloc(scene.CellRef, idxs.len + n_ov) catch return;
        for (idxs, 0..) |idx, j| {
            const be = &c.backends[idx];
            const g = carryGate(be.cscl, gf_centre_d, gf_whole, display_denom, ladders);
            // Overscale tag: the cell's compilation scale quantized UP the tile's
            // scamin ladder (like the smax handoff), so the client's discrete
            // crossing machinery fires exactly at the emitted value.
            const oscl: i64 = if (be.cscl > 0) quantizeHandoff(ladders, be.cscl) else 0;
            refs[j] = .{ .cell = &be.cell, .portrayal = be.portrayal, .portrayal_plain = be.portrayal_plain, .portrayal_simplified = be.portrayal_simplified, .geo = be.geo, .geo_world = be.geo_world, .feat_bbox = be.feat_bbox, .suppress_fills = g.suppress_whole, .suppress_patterns = g.suppress_centre, .suppress_lines = g.suppress_centre, .suppress_points = g.suppress_whole, .smax = g.smax, .oscl = oscl, .skip_scamin_points = c.standalone };
        }
        if (n_ov > 0) {
            const floor_denom = assets.displayDenomZ(z + 1, clat);
            var j = idxs.len;
            for (c.overlay) |*ov| {
                if (!(ov.bounds[0] <= tbll[2] + pad_lon and ov.bounds[2] >= tbll[0] - pad_lon and
                    ov.bounds[1] <= tbll[3] + pad_lat and ov.bounds[3] >= tbll[1] - pad_lat)) continue;
                refs[j] = .{ .cell = @constCast(&ov.cell), .portrayal = ov.portrayal, .portrayal_simplified = ov.portrayal_simplified, .feat_bbox = ov.feat_bbox, .feat_smax = ov.feat_smax, .scamin_floor = floor_denom };
                j += 1;
            }
        }
        const mvt_bytes = scene.encodeTile(scratch, scratch, refs, z, x, y, c.format, c.pick_attrs) catch return;
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
/// encodeTile creates and frees a child arena per tile, which an arena
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
    format: scene.TileFormat = .mvt, // output tile encoding (mvt default; mlt optional)
    pick_attrs: bool = true, // emit per-feature pick-report attrs (s57/cell); off = lean tiles
    // SCAMIN standalone (specs/scamin-standalone.md): the deduped SCAMIN point
    // mini cells (scene.scamin_pts, one Backend per contributing source cell),
    // set ONCE by the driver before any pass and joined into every tile by
    // per-feature scale-window eligibility. `scamin_standalone` makes regular
    // cells skip their own prim==1 SCAMIN features (the overlay owns them);
    // drivers set it whenever they built an overlay (even an empty one).
    overlay: []const Backend = &.{},
    scamin_standalone: bool = false,
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

    /// Build the tile→contributing-bounds-index map for one band's pass: every
    /// not-yet-emitted (z,x,y) over [minzoom..maxzoom]∩band, clipped to the
    /// super-tile when `clip` is set. Shared by bakeBand (to bake) and plannedTiles
    /// (to count) so the progress denominator can't drift from what's actually
    /// baked. `bounds[i]` = [w,s,e,n]; the map values index into it.
    ///
    /// Band handoff: `bounds[own_len..]` are the next-FINER band's carry cells —
    /// they contribute ONLY at this band's max zoom (the finer band's deferred
    /// floor tiles, which this pass bakes with both bands' cells). The own cells'
    /// floor zoom is skipped (.defer_down — the next-coarser pass bakes it the
    /// same way) or the range is extended down to Baker.minzoom (.extend_min, the
    /// coarsest populated band). Caller frees the value lists + the map.
    fn buildTileMap(self: *Baker, band: Band, bounds: []const [4]f64, own_len: usize, floor: FloorMode, clip: ?TileClip) !std.AutoHashMap(u64, std.ArrayList(u32)) {
        const zr = bandZooms(band);
        var zlo = @max(self.minzoom, zr.min);
        const zhi = @min(self.maxzoom, zr.max);
        switch (floor) {
            // Defer the band's own floor tiles to the next-coarser pass — but only
            // when this pass would otherwise bake them (zlo == the real floor).
            .defer_down => if (zlo == zr.min and zlo <= zhi) {
                zlo += 1;
            },
            .extend_min => zlo = self.minzoom,
        }
        // The deferred-floor zoom the carry cells (bounds[own_len..]) bake at: the
        // band's max — present only when it survives the archive's zoom clamp.
        const carry_z: ?u8 = if (zr.max >= self.minzoom and zr.max <= self.maxzoom) zr.max else null;
        var tilemap = std.AutoHashMap(u64, std.ArrayList(u32)).init(self.gpa);
        errdefer {
            var vit = tilemap.valueIterator();
            while (vit.next()) |v| v.deinit(self.gpa);
            tilemap.deinit();
        }
        for (bounds, 0..) |b, i| {
            var z = zlo;
            var zend = zhi;
            if (i >= own_len) {
                z = carry_z orelse continue;
                zend = z;
            } else if (zlo > zhi) continue;
            while (z <= zend) : (z += 1) {
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

    /// Planned tile count for a band's pass (host §3 progress denominator): the
    /// distinct not-yet-emitted tiles their bounds cover. A planned ESTIMATE — the
    /// caller may pass cheap peek-bboxes while the real bake uses slightly tighter
    /// loaded bounds — matching the Go baker's up-front planned count. `own_len` /
    /// `floor` mirror bakeBand (bounds[own_len..] = the carry cells). 0 on OOM.
    pub fn plannedTiles(self: *Baker, band: Band, bounds: []const [4]f64, own_len: usize, floor: FloorMode, clip: ?TileClip) usize {
        var tm = self.buildTileMap(band, bounds, own_len, floor, clip) catch return 0;
        defer {
            var vit = tm.valueIterator();
            while (vit.next()) |v| v.deinit(self.gpa);
            tm.deinit();
        }
        return tm.count();
    }

    /// Bake one band's pass. `backends[0..own_len]` are the band's own already-
    /// parsed+portrayed cells; `backends[own_len..]` are the next-FINER band's
    /// cells, still alive from the previous pass, contributing only at this band's
    /// max zoom — the finer band's DEFERRED floor tiles, baked here with both
    /// bands' cells so the coarser band carries down scamin-aware (band handoff).
    /// Tiles a finer band already emitted are skipped (call bands finest →
    /// coarsest). All cells must stay valid for the duration of this call; the
    /// caller may free the own cells after the NEXT-coarser pass (or now, when
    /// `floor` is .extend_min — nothing was deferred).
    pub fn bakeBand(self: *Baker, band: Band, backends: []Backend, own_len: usize, floor: FloorMode, clip: ?TileClip, progress: Progress, ctx: ?*anyopaque) !void {
        if (backends.len == 0) return;

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

        // Map this pass's not-yet-emitted tiles -> contributing cell indices.
        var tilemap = try self.buildTileMap(band, bounds, own_len, floor, clip);
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
        var tg = TileGenCtx{ .keys = keys, .idx_lists = idx_lists, .results = results, .backends = backends, .gpa = self.gpa, .format = self.format, .pick_attrs = self.pick_attrs, .overlay = self.overlay, .standalone = self.scamin_standalone, .progress = progress, .pctx = ctx, .base = self.count, .band_base = self.band_base, .band_total = self.band_total, .band_index = self.band_index, .band_count = self.band_count, .band_name = bname, .done = &done };
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

test "quantizeHandoff: smallest ladder value >= cscl, raw-cscl fallback" {
    const fine = [_]u32{ 90_000, 260_000, 350_000 };
    const coarse = [_]u32{ 700_000, 1_000_000 };
    const ladders = [_][]const u32{ &fine, &coarse };
    // 200k quantizes up onto the fine cell's 260k (the crossing where its bulk activates).
    try std.testing.expectEqual(@as(i64, 260_000), quantizeHandoff(&ladders, 200_000));
    // An exact ladder member maps to itself.
    try std.testing.expectEqual(@as(i64, 260_000), quantizeHandoff(&ladders, 260_000));
    // Above every fine value: the coarse ladder supplies the crossing.
    try std.testing.expectEqual(@as(i64, 700_000), quantizeHandoff(&ladders, 400_000));
    // No ladder value reaches it -> raw cscl (BakeSink folds it into the manifest).
    try std.testing.expectEqual(@as(i64, 2_000_000), quantizeHandoff(&ladders, 2_000_000));
    try std.testing.expectEqual(@as(i64, 200_000), quantizeHandoff(&.{}, 200_000));
}

test "carryGate: D>cscl carries with quantized smax; D<=cscl suppresses" {
    const fine = [_]u32{260_000};
    const ladders = [_][]const u32{&fine};
    const none = std.math.maxInt(i32);

    // Display window opens coarser than the covering fine cell (D=578k > 200k):
    // the coarse cell rides along tagged smax = quantizeUp(200k) = 260k.
    const carried = carryGate(1_200_000, 200_000, 200_000, 578_000.0, &ladders);
    try std.testing.expect(!carried.suppress_centre and !carried.suppress_whole);
    try std.testing.expectEqual(@as(i64, 260_000), carried.smax);

    // Display already finer than the fine cell's compilation scale: plain suppression.
    const supp = carryGate(1_200_000, 200_000, 200_000, 150_000.0, &ladders);
    try std.testing.expect(supp.suppress_centre and supp.suppress_whole);
    try std.testing.expectEqual(@as(i64, 0), supp.smax);

    // D inside (cscl, smax]: the quantized copy could never display in this tile's
    // window (the client's crossing sits at 260k), so it stays suppressed.
    const dead = carryGate(1_200_000, 200_000, 200_000, 230_000.0, &ladders);
    try std.testing.expect(dead.suppress_centre and dead.suppress_whole);
    try std.testing.expectEqual(@as(i64, 0), dead.smax);

    // No finer coverage at all: best-available, untouched and untagged.
    const plain = carryGate(1_200_000, none, none, 578_000.0, &ladders);
    try std.testing.expect(!plain.suppress_centre and !plain.suppress_whole);
    try std.testing.expectEqual(@as(i64, 0), plain.smax);

    // Seam tile: finer coverage over the centre only (whole-tile gate unmet) —
    // the centre classes carry, the whole classes were never suppressed.
    const seam = carryGate(1_200_000, 200_000, none, 578_000.0, &ladders);
    try std.testing.expect(!seam.suppress_centre and !seam.suppress_whole);
    try std.testing.expectEqual(@as(i64, 260_000), seam.smax);

    // Empty ladder: the handoff falls back to the raw covering cscl.
    const raw = carryGate(1_200_000, 200_000, 200_000, 578_000.0, &.{});
    try std.testing.expectEqual(@as(i64, 200_000), raw.smax);

    // The fine cell itself never yields to its own scale.
    const self_ok = carryGate(200_000, 200_000, 200_000, 578_000.0, &ladders);
    try std.testing.expect(!self_ok.suppress_centre and !self_ok.suppress_whole);
    try std.testing.expectEqual(@as(i64, 0), self_ok.smax);
}

test "floorDeferred / passHasWork: clamp-aware deferral + carry hosting" {
    // Coastal's floor (9) defers whenever 9 survives the clamp.
    try std.testing.expect(floorDeferred(.coastal, 0, 16));
    try std.testing.expect(!floorDeferred(.coastal, 10, 16)); // floor below minzoom
    try std.testing.expect(!floorDeferred(.coastal, 0, 8)); // floor above maxzoom

    // A deferring band with cells still has work above its floor…
    try std.testing.expect(passHasWork(.coastal, 0, 16, 3, 0, .defer_down));
    // …but a single-zoom clamp that IS the floor leaves it nothing of its own.
    try std.testing.expect(!passHasWork(.coastal, 9, 9, 3, 0, .defer_down));
    // A band with no own cells runs anyway when the finer band deferred into it.
    try std.testing.expect(passHasWork(.general, 9, 9, 0, 3, .defer_down));
    // Carry whose deferred floor (this band's max) is out of clamp: no work.
    try std.testing.expect(!passHasWork(.approach, 9, 9, 0, 3, .defer_down));
    // The coarsest populated band extends down to minzoom instead of deferring.
    try std.testing.expect(passHasWork(.general, 0, 6, 2, 0, .extend_min));
    try std.testing.expect(!passHasWork(.general, 0, 6, 2, 0, .defer_down));
}

// ---- band-handoff integration: deferral + carry through a real bake ---------

const gzip = @import("tiles").gzip;
const mvt = @import("tiles").mvt;

// Sink collecting every (z,x,y) + gzipped tile for the deferral test.
const CollectSink = struct {
    a: std.mem.Allocator,
    tiles: std.AutoHashMap(u64, []u8),

    fn run(ctx: ?*anyopaque, z: u8, x: u32, y: u32, bytes: []const u8) anyerror!void {
        const self: *CollectSink = @ptrCast(@alignCast(ctx.?));
        try self.tiles.put(tileKey(z, x, y), try self.a.dupe(u8, bytes));
    }
};

// A minimal synthetic cell: one isolated node at (lon,lat) + one point feature
// referencing it, carrying a SCAMIN attribute. Portrayal is supplied verbatim.
fn testCell(gpa: std.mem.Allocator, lon: f64, lat: f64, cscl: i32, feats: []const s57.Feature) !s57.Cell {
    var cell = s57.Cell{
        .params = .{ .cscl = cscl },
        .vectors = &.{},
        .features = feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(gpa),
        .edges = std.AutoHashMap(u32, usize).init(gpa),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(gpa),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 1, s57.LonLat.init(lon, lat));
    return cell;
}

fn findIntProp(props: []const mvt.Prop, key: []const u8) ?i64 {
    for (props) |pr| if (std.mem.eql(u8, pr.key, key)) return switch (pr.value) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => null,
    };
    return null;
}

test "band handoff: the floor tile bakes in the coarser pass with both bands' content" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Two cells at the same location near (0.35, 0.35): a coastal 1:200k with its
    // bulk gated SCAMIN 260000, and a general 1:1.2M with SCAMIN 800000. The
    // coastal M_COVR coverage blankets everything, so pre-handoff the general cell
    // was fully suppressed at the shared z9 — the blank-window bug.
    const scamin_attr = [_]s57.Attr{.{ .code = 133, .value = "260000" }}; // SCAMIN
    const fine_feats = [_]s57.Feature{.{
        .rcnm = 0,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &scamin_attr,
    }};
    const coarse_attr = [_]s57.Attr{.{ .code = 133, .value = "800000" }};
    const coarse_feats = [_]s57.Feature{.{
        .rcnm = 0,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &coarse_attr,
    }};
    var fine_cell = try testCell(gpa, 0.35, 0.35, 200_000, &fine_feats);
    defer fine_cell.deinit();
    var coarse_cell = try testCell(gpa, 0.35, 0.35, 1_200_000, &coarse_feats);
    defer coarse_cell.deinit();

    const ring = [_]s57.LonLat{
        s57.LonLat.init(-2, -2), s57.LonLat.init(3, -2),
        s57.LonLat.init(3, 3),   s57.LonLat.init(-2, 3),
        s57.LonLat.init(-2, -2),
    };
    const rings = [_][]const s57.LonLat{&ring};
    const cover = [_][]const []const s57.LonLat{&rings};
    const bounds = [4]f64{ 0.2, 0.2, 0.5, 0.5 };
    const streams = [_]?[]const u8{"DrawingPriority:7;PointInstruction:BOYLAT01"};
    const fine_scamins = [_]u32{260_000};
    const coarse_scamins = [_]u32{800_000};

    var fine = Backend{ .cell = fine_cell, .portrayal = &streams, .bounds = bounds, .cscl = 200_000, .coverage = &cover, .scamins = &fine_scamins };
    const coarse = Backend{ .cell = coarse_cell, .portrayal = &streams, .bounds = bounds, .cscl = 1_200_000, .coverage = &cover, .scamins = &coarse_scamins };

    var sink = CollectSink{ .a = a, .tiles = std.AutoHashMap(u64, []u8).init(a) };
    var baker = Baker.init(gpa, 7, 10, .{ .ctx = &sink, .func = CollectSink.run });
    defer baker.deinit();

    // Coastal pass (deferred floor): only z10 tiles may be emitted, never z9.
    try baker.bakeBand(.coastal, (&fine)[0..1], 1, .defer_down, null, null, null);
    var it = sink.tiles.keyIterator();
    while (it.next()) |k| try std.testing.expectEqual(@as(u64, 10), k.* >> 48);
    try std.testing.expect(sink.tiles.count() > 0);

    // General pass (coarsest populated): own cells + the coastal carry. The z9
    // floor tile now exists and holds BOTH bands' points.
    var both = [_]Backend{ coarse, fine };
    try baker.bakeBand(.general, &both, 1, .extend_min, null, null, null);
    const t9 = lonLatToTile(0.35, 0.35, 9);
    const bytes = sink.tiles.get(tileKey(9, t9[0], t9[1])) orelse return error.TestUnexpectedResult;
    const raw = try gzip.decompress(a, bytes);
    const layers = try mvt.decode(a, raw);
    var fine_pts: usize = 0;
    var carried_pts: usize = 0;
    for (layers) |L| {
        if (!std.mem.eql(u8, L.name, "point_symbols_scamin")) continue;
        for (L.features) |f| {
            const scamin = findIntProp(f.properties, "scamin") orelse continue;
            const smax = findIntProp(f.properties, "smax");
            if (scamin == 260_000) {
                // The fine band's own point: gated by its SCAMIN alone, never tagged.
                try std.testing.expectEqual(@as(?i64, null), smax);
                fine_pts += 1;
            } else if (scamin == 800_000) {
                // The carried general-band copy: smax = quantizeUp(cscl_fine 200k)
                // onto the fine ladder = 260000 — it hands off at the exact crossing
                // where the fine bulk activates (no double-draw window in denom space).
                try std.testing.expectEqual(@as(?i64, 260_000), smax);
                carried_pts += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fine_pts);
    try std.testing.expectEqual(@as(usize, 1), carried_pts);

    // The extend_min pass also filled below the general floor (z7 exists via the
    // coarsest-band extension even though nothing coarser was baked).
    const t7 = lonLatToTile(0.35, 0.35, 7);
    try std.testing.expect(sink.tiles.get(tileKey(7, t7[0], t7[1])) != null);
}

test "overscale: contributing cells emit OVERSC01 coverage hatches tagged quantized oscl" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // The band-handoff scenario again (coastal 1:200k + general 1:1.2M over the
    // same spot), each cell now carrying an M_COVR(CATCOV=1) area feature whose
    // polygon is supplied via the geo cache. The z9 handoff tile must carry BOTH
    // cells' AP(OVERSC01) hatches: the fine cell's tagged oscl = quantizeUp(200k)
    // = 260000 (its own ladder value, untagged smax), the carried coarse cell's
    // tagged oscl = 1200000 (no ladder value reaches 1.2M -> raw cscl) + the
    // carry handoff smax — it hides with the rest of the carried copy.
    const scamin_attr = [_]s57.Attr{.{ .code = 133, .value = "260000" }};
    const catcov_attr = [_]s57.Attr{.{ .code = 18, .value = "1" }}; // CATCOV=1
    const fine_feats = [_]s57.Feature{
        .{
            .rcnm = 0,
            .rcid = 1,
            .prim = 1,
            .objl = 14,
            .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
            .attrs = &scamin_attr,
        },
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 302, .attrs = &catcov_attr },
    };
    const coarse_attr = [_]s57.Attr{.{ .code = 133, .value = "800000" }};
    const coarse_feats = [_]s57.Feature{
        .{
            .rcnm = 0,
            .rcid = 1,
            .prim = 1,
            .objl = 14,
            .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
            .attrs = &coarse_attr,
        },
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 302, .attrs = &catcov_attr },
    };
    var fine_cell = try testCell(gpa, 0.35, 0.35, 200_000, &fine_feats);
    defer fine_cell.deinit();
    var coarse_cell = try testCell(gpa, 0.35, 0.35, 1_200_000, &coarse_feats);
    defer coarse_cell.deinit();

    var ring = [_]s57.LonLat{
        s57.LonLat.init(-2, -2), s57.LonLat.init(3, -2),
        s57.LonLat.init(3, 3),   s57.LonLat.init(-2, 3),
        s57.LonLat.init(-2, -2),
    };
    const rings = [_][]const s57.LonLat{&ring};
    const cover = [_][]const []const s57.LonLat{&rings};
    // Geo cache: the M_COVR feature (index 1) gets the same ring as its polygon.
    var mparts = [_][]s57.LonLat{&ring};
    const geo = [_]?[][]s57.LonLat{ null, &mparts };
    const bounds = [4]f64{ 0.2, 0.2, 0.5, 0.5 };
    const streams = [_]?[]const u8{ "DrawingPriority:7;PointInstruction:BOYLAT01", null };
    const fine_scamins = [_]u32{260_000};
    const coarse_scamins = [_]u32{800_000};

    var fine = Backend{ .cell = fine_cell, .portrayal = &streams, .geo = &geo, .bounds = bounds, .cscl = 200_000, .coverage = &cover, .scamins = &fine_scamins };
    const coarse = Backend{ .cell = coarse_cell, .portrayal = &streams, .geo = &geo, .bounds = bounds, .cscl = 1_200_000, .coverage = &cover, .scamins = &coarse_scamins };

    var sink = CollectSink{ .a = a, .tiles = std.AutoHashMap(u64, []u8).init(a) };
    var baker = Baker.init(gpa, 7, 10, .{ .ctx = &sink, .func = CollectSink.run });
    defer baker.deinit();
    try baker.bakeBand(.coastal, (&fine)[0..1], 1, .defer_down, null, null, null);
    var both = [_]Backend{ coarse, fine };
    try baker.bakeBand(.general, &both, 1, .extend_min, null, null, null);

    const t9 = lonLatToTile(0.35, 0.35, 9);
    const bytes = sink.tiles.get(tileKey(9, t9[0], t9[1])) orelse return error.TestUnexpectedResult;
    const raw = try gzip.decompress(a, bytes);
    const layers = try mvt.decode(a, raw);
    var fine_hatch: usize = 0;
    var coarse_hatch: usize = 0;
    for (layers) |L| {
        if (!std.mem.eql(u8, L.name, "area_patterns")) continue;
        for (L.features) |f| {
            var is_oversc = false;
            for (f.properties) |pr| if (std.mem.eql(u8, pr.key, "pattern_name")) {
                is_oversc = std.mem.eql(u8, pr.value.string, "OVERSC01");
            };
            if (!is_oversc) continue;
            const oscl = findIntProp(f.properties, "oscl") orelse return error.TestUnexpectedResult;
            const smax = findIntProp(f.properties, "smax");
            if (oscl == 260_000) {
                // Fine cell: cscl 200k quantized UP its own ladder; never carried.
                try std.testing.expectEqual(@as(?i64, null), smax);
                fine_hatch += 1;
            } else if (oscl == 1_200_000) {
                // Carried coarse cell: raw-cscl fallback + the carry handoff smax.
                try std.testing.expectEqual(@as(?i64, 260_000), smax);
                coarse_hatch += 1;
            } else return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fine_hatch);
    try std.testing.expectEqual(@as(usize, 1), coarse_hatch);
}

test "scamin standalone: one deduped feature per tile, scale-window included" {
    const scamin_pts = scene.scamin_pts;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // The acceptance shape in miniature: the SAME object (one FOID) charted in a
    // coastal 1:200k cell (SCAMIN 260000) and a general 1:1.2M cell (SCAMIN
    // 800000). Standalone model: ONE deduped feature — fine geometry/attrs,
    // effective scamin 800000 — in every tile whose window it reaches; the
    // regular band path emits NO copy of its own. Plus a coarse-only object
    // (no fine copy) capped at the fine chart's handoff (smax 260000).
    const fine_attrs = [_]s57.Attr{.{ .code = 133, .value = "260000" }};
    const fine_feats = [_]s57.Feature{.{
        .rcnm = 100,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .foid = 0xBEEF,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &fine_attrs,
    }};
    const coarse_attrs = [_]s57.Attr{.{ .code = 133, .value = "800000" }};
    const coarse_only_attrs = [_]s57.Attr{.{ .code = 133, .value = "900000" }};
    const coarse_feats = [_]s57.Feature{ .{
        .rcnm = 100,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .foid = 0xBEEF,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &coarse_attrs,
    }, .{
        .rcnm = 100,
        .rcid = 2,
        .prim = 1,
        .objl = 14,
        .foid = 0xD00D,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 2 }, .ornt = 255 }},
        .attrs = &coarse_only_attrs,
    } };
    var fine_cell = try testCell(gpa, 0.35, 0.35, 200_000, &fine_feats);
    defer fine_cell.deinit();
    var coarse_cell = try testCell(gpa, 0.35, 0.35, 1_200_000, &coarse_feats);
    defer coarse_cell.deinit();
    // The coarse-only object sits a bit away from the shared one, still covered.
    try coarse_cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 2, s57.LonLat.init(0.36, 0.36));

    const ring = [_]s57.LonLat{
        s57.LonLat.init(-2, -2), s57.LonLat.init(3, -2),
        s57.LonLat.init(3, 3),   s57.LonLat.init(-2, 3),
        s57.LonLat.init(-2, -2),
    };
    const rings = [_][]const s57.LonLat{&ring};
    const cover = [_][]const []const s57.LonLat{&rings};
    const bounds = [4]f64{ 0.2, 0.2, 0.5, 0.5 };
    const streams = [_]?[]const u8{ "DrawingPriority:7;PointInstruction:BOYLAT01", "DrawingPriority:7;PointInstruction:BOYLAT01" };
    const fine_scamins = [_]u32{260_000};
    const coarse_scamins = [_]u32{ 800_000, 900_000 };

    var fine = Backend{ .cell = fine_cell, .portrayal = streams[0..1], .bounds = bounds, .cscl = 200_000, .coverage = &cover, .scamins = &fine_scamins };
    const coarse = Backend{ .cell = coarse_cell, .portrayal = &streams, .bounds = bounds, .cscl = 1_200_000, .coverage = &cover, .scamins = &coarse_scamins };

    // Build the overlay the way the drivers do: collect recs, dedup, cap, minis.
    var recs = std.ArrayList(scamin_pts.Rec).empty;
    try recs.appendSlice(a, try scamin_pts.collectRecs(a, &fine_cell, 200_000, 0));
    try recs.appendSlice(a, try scamin_pts.collectRecs(a, &coarse_cell, 1_200_000, 1));
    try scamin_pts.dedup(gpa, recs.items);
    var minis = std.ArrayList(Backend).empty;
    const ladders = [_][]const u32{&fine_scamins};
    for (0..2) |ci| {
        var entries = std.ArrayList(scamin_pts.MiniEntry).empty;
        for (recs.items) |r| {
            if (!r.winner or r.cell != ci) continue;
            // Both points are covered by the fine 1:200k coverage; a group whose
            // finest copy is coarser than that gets the quantized cap.
            const cap = scamin_pts.capFor(if (r.foid == 0xBEEF) 200_000 else 1_200_000, 200_000, &ladders);
            try entries.append(a, .{ .feat = r.feat, .lon = r.lon, .lat = r.lat, .effective = r.effective, .smax = cap });
        }
        if (entries.items.len == 0) continue;
        const src: *const s57.Cell = if (ci == 0) &fine_cell else &coarse_cell;
        const mini = try scamin_pts.buildMini(a, src, entries.items, &streams, null);
        try minis.append(a, .{ .cell = mini.cell, .portrayal = mini.portrayal, .portrayal_simplified = mini.portrayal_simplified, .feat_bbox = mini.feat_bbox, .feat_smax = mini.feat_smax, .bounds = mini.bounds, .cscl = src.params.cscl });
    }
    // The shared object's winner is the FINE copy; the coarse-only one is capped.
    try std.testing.expectEqual(@as(usize, 2), minis.items.len);

    var sink = CollectSink{ .a = a, .tiles = std.AutoHashMap(u64, []u8).init(a) };
    var baker = Baker.init(gpa, 7, 10, .{ .ctx = &sink, .func = CollectSink.run });
    defer baker.deinit();
    baker.overlay = minis.items;
    baker.scamin_standalone = true;

    try baker.bakeBand(.coastal, (&fine)[0..1], 1, .defer_down, null, null, null);
    var both = [_]Backend{ coarse, fine };
    try baker.bakeBand(.general, &both, 1, .extend_min, null, null, null);

    // Per tile zoom: the deduped feature (scamin 800000, NO smax) appears exactly
    // once from its eligibility floor (D(z+1) <= 800k near the equator => z >= 9)
    // to maxzoom, across BOTH passes — no band handoff, no double-draw. The
    // capped coarse-only object (scamin 900000, smax 260000) rides the same
    // tiles while their windows open coarser than its cap.
    var z: u8 = 7;
    while (z <= 10) : (z += 1) {
        // Count each object in ITS OWN tile (the two points diverge into
        // different tiles at z10), summing distinct tiles once.
        var deduped: usize = 0;
        var capped: usize = 0;
        var seen = std.AutoHashMap(u64, void).init(a);
        for ([_][2]f64{ .{ 0.35, 0.35 }, .{ 0.36, 0.36 } }) |pt| {
            const t = lonLatToTile(pt[0], pt[1], z);
            const key = tileKey(z, t[0], t[1]);
            if ((try seen.getOrPut(key)).found_existing) continue;
            const bytes = sink.tiles.get(key) orelse {
                try std.testing.expect(z <= 8); // the low zooms may legitimately be empty
                continue;
            };
            const raw = try gzip.decompress(a, bytes);
            const layers = try mvt.decode(a, raw);
            for (layers) |L| {
                if (!std.mem.eql(u8, L.name, "point_symbols_scamin")) continue;
                for (L.features) |ft| {
                    const sc = findIntProp(ft.properties, "scamin") orelse continue;
                    const sm = findIntProp(ft.properties, "smax");
                    if (sc == 800_000) {
                        try std.testing.expectEqual(@as(?i64, null), sm); // never capped/carried
                        deduped += 1;
                    } else if (sc == 900_000) {
                        try std.testing.expectEqual(@as(?i64, 260_000), sm); // fine chart owns past 260k
                        capped += 1;
                    } else {
                        // The fine cell's own 260000 copy must NEVER appear — the overlay owns it.
                        try std.testing.expect(sc != 260_000);
                    }
                }
            }
        }
        const floor_denom = assets.displayDenomZ(z + 1, 0.35);
        try std.testing.expectEqual(@as(usize, if (800_000.0 >= floor_denom) 1 else 0), deduped);
        try std.testing.expectEqual(@as(usize, if (scene.scamin_pts.eligibleAt(900_000, 260_000, floor_denom)) 1 else 0), capped);
    }
    // Sanity: the window really opens during the test range (z9/z10 carry it).
    const t9 = lonLatToTile(0.35, 0.35, 9);
    try std.testing.expect(sink.tiles.get(tileKey(9, t9[0], t9[1])) != null);
    try std.testing.expect(800_000.0 >= assets.displayDenomZ(10, 0.35));
}

test "bandOf / bandZooms match the Go reference bands" {
    try std.testing.expectEqual(Band.harbor, bandOf(12_000)); // [13,16]
    try std.testing.expectEqual(@as(u8, 13), bandZooms(bandOf(12_000)).min);
    try std.testing.expectEqual(Band.overview, bandOf(3_000_000)); // [0,7]
    try std.testing.expectEqual(Band.approach, bandOf(80_000)); // [11,13]
    try std.testing.expectEqual(Band.approach, bandOf(0)); // CSCL 0 -> 50k -> approach
    try std.testing.expectEqual(Band.coastal, bandOf(200_000)); // [9,11]
}
