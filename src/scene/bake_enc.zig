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
    // Sector-figure reach (scene.LightReach / collectLightReach): bbox of the
    // features whose portrayal constructs light-sector legs/arcs (null = none)
    // and the max ground-distance leg length. Figures extend beyond their anchors
    // — up to LIGHT_AUG_REACH_TILES tiles for display-mm figures plus the ground
    // legs' per-zoom span — so buildTileMap must address the neighbouring tiles
    // they cross (else legs/arcs clip exactly at the cell-bbox tile boundary).
    light_bbox: ?[4]f64 = null,
    light_range_m: f64 = 0,
};

/// One cell's tile-addressing span for a bake pass: its raw bounds plus the
/// sector-figure reach summary (see Backend.light_bbox). buildTileMap addresses
/// the raw-bbox tile range as before, PLUS a reach ring around light_bbox whose
/// members are tagged REACH_FLAG — the cell rides those tiles for its figures
/// only (excluded from the tile-level quilting ladder / overscale scale).
pub const CellSpan = struct {
    bounds: [4]f64,
    light_bbox: ?[4]f64 = null,
    light_range_m: f64 = 0,
};

/// Tag bit on a buildTileMap contributor index: the cell joined this tile only
/// through its sector-figure reach ring (its raw bbox misses the tile). The
/// tile generator masks it off for the Backend index and excludes such cells
/// from tile-level decisions (scamin ladders, the overscale finest-scale scan)
/// so a reach-only neighbour can't perturb tiles it has no real coverage in.
pub const REACH_FLAG: u32 = 1 << 31;

/// Tag bit on a buildTileMap contributor index: this carry (finer-band) cell rode
/// a coarser band's BELOW-window extend tile (.extend_min pass) as a cross-band
/// HOLE-FILL candidate. Its bbox reaches the tile, but it must only actually
/// contribute where the in-window band leaves an M_COVR hole — TileGenCtx.gen
/// keeps it iff a sampled tile point is uncovered by the non-hole-fill cells,
/// else drops it (the tile then bakes byte-identically to the pre-hole-fill baker).
pub const HOLEFILL_FLAG: u32 = 1 << 30;

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

/// Whether ANY cell in `idxs` covers (lon,lat): real M_COVR containment, or the
/// cell's bbox when it has no M_COVR. Unlike finestCsclAt this also counts
/// cscl<=0 cells — a coverage-hole test must treat any present data as coverage
/// (an unknown-scale cell still fills the ground). Used by the cross-band
/// hole-fill admission: a coarser in-window band leaves a HOLE at a sampled point
/// none of its cells cover, and a finer out-of-window cell that DOES cover there
/// is admitted to fill it (see TileGenCtx.gen / chart.zig tileRefs).
fn coversAny(backends: []const Backend, idxs: []const u32, lon: f64, lat: f64) bool {
    for (idxs) |i| {
        const be = &backends[i];
        const covered = if (be.coverage.len > 0)
            s57.coverageContains(be.coverage, lon, lat)
        else
            (lon >= be.bounds[0] and lon <= be.bounds[2] and lat >= be.bounds[1] and lat <= be.bounds[3]);
        if (covered) return true;
    }
    return false;
}

/// A read-only coverage participant from ANOTHER pack (bake --existing): its real
/// M_COVR coverage + compilation scale, folded into the finest-cscl suppression
/// scan so THIS pack's coarser cells defer to the peer pack where it is finer
/// (cross-pack best-available). The peer emits nothing here and never rides the
/// tilemap — it only prevents this pack's overview from painting over the peer's
/// finer data (e.g. clipping its light sectors). M_COVR only (no derived bbox),
/// the conservative fills/points rule.
pub const ContextCell = struct {
    coverage: []const []const []const s57.LonLat = &.{},
    bounds: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 }, // bbox over the coverage rings
    cscl: i32 = 0,
};

/// Lower `best` to a peer ContextCell's cscl where one strictly finer covers
/// (lon,lat) — the cross-pack extension of finestCsclAt. `best` is the finest
/// cscl from this pack's own cells; the result folds the peer packs in.
fn finestCsclCtx(context: []const ContextCell, lon: f64, lat: f64, best_in: i32) i32 {
    var best = best_in;
    for (context) |*c| {
        if (c.cscl <= 0 or c.cscl >= best) continue;
        if (lon < c.bounds[0] or lon > c.bounds[2] or lat < c.bounds[1] or lat > c.bounds[3]) continue;
        if (c.coverage.len > 0 and s57.coverageContains(c.coverage, lon, lat)) best = c.cscl;
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
    // Snap onto a NEARBY ladder rung (keeps the handoff aligned to a real client
    // crossing) — but reject a rung that overshoots cscl_fine by more than ~30%.
    // Snapping across a wide ladder gap (observed: 2.16M -> 2.999M) pushes the
    // handoff far above the covering cell's own activation scale, so carryGate's
    // escape `display_denom > handoff` never fires for displays in
    // (cscl_fine, rung) and the coarse cell is plainly suppressed there —
    // re-opening the band-floor blank the carry exists to prevent. Beyond the
    // cap, fall back to the raw crossing (a supported handoff; BakeSink folds it
    // into the manifest, so the client still gets a crossing there).
    const want_i: i64 = want;
    if (best != std.math.maxInt(i64) and best * 10 <= want_i * 13) return best;
    return want_i;
}

/// S-52 overscale factor at/above which AP(OVERSC01) marks a scale boundary.
///
/// IHO S-52 PresLib e4.0.0 Part I §10.1.10.2: '"grossly enlarged" and "grossly
/// overscale" must be taken to mean that the display scale is enlarged/overscale
/// by X2 or more with respect to the compilation scale.' (Confirmed by S-52 Ed
/// 6.1.1 §3.2.3(8b): the "overscale area" symbol identifies "any part of the
/// chart display shown at two or more times the compilation scale".)
///
/// This is the SCALE-BOUNDARY pattern, distinct from the §10.1.10.1 "overscale
/// indication" readout (the HUD "X n"), which fires from 1x (any overscale) for
/// the mariner's own deliberate zoom and must NOT draw the pattern. So the gate
/// is X2, not X1 — set to 1 for the looser IMO-PS-readout threshold.
pub const OVERSCALE_FACTOR = 2;

/// The display-scale denominator at/below which a cell of compilation scale
/// `cscl` (1:cscl) is "grossly overscale" per §10.1.10.2 — i.e. cscl /
/// OVERSCALE_FACTOR. Baked as the `oscl` gate tag: the AP(OVERSC01) hatch shows
/// while the live display denominator is finer (smaller) than this value
/// (style clause `oscl > DENOM`; resolve.osclVisible `denom < oscl`).
///
/// Baking the halved value (rather than the raw cscl quantized UP the SCAMIN
/// ladder, the old behaviour) fixes the "fires early" defect: the zoom-derived
/// clause `oscl > K/2^zoom` now flips EXACTLY at 2x and never before 1x
/// (specs/overscale.md v3 defect 1). 0 when the compilation scale is unknown.
pub fn overscaleGateDenom(cscl: i32) i64 {
    if (cscl <= 0) return 0;
    return @divTrunc(cscl, OVERSCALE_FACTOR);
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
// Diagnostic (compile-time): flip to `true` + rebuild to log every coarse (general/
// overview) cell whose FILLS end up SUPPRESSED by best-available — i.e. where land /
// depth-areas get CUT because the carry-down didn't fire. Prints cscl / gf_whole /
// display / handoff so the cause is visible (handoff >> gf_whole = a SCAMIN-ladder gap
// overshooting the band handoff). Off (dead-stripped) by default. Covers bake + live.
const carry_dbg = false; // TEMP diagnostic hook: flip to true to log land-cut suppressions
var carry_dbg_n = std.atomic.Value(usize).init(0);

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
    if (carry_dbg) {
        // Self-verifying: the first ~60 calls print UNCONDITIONALLY (proof the flag is
        // compiled + carryGate is on the bake path), then only suppressions (the land-cut
        // cases) up to a cap. If you see NO lines at all → the running binary predates
        // this edit. If you see "carryGate#.." but never sw=true → carryGate isn't the
        // suppressor and the cut is elsewhere.
        const nn = carry_dbg_n.fetchAdd(1, .monotonic);
        if (nn < 60 or ((g.suppress_whole or g.suppress_centre) and nn < 5000))
            std.debug.print("carryGate#{d} cscl={d} gf_whole={d} gf_centre={d} display={d:.0} handoff={d} sw={} sc={}\n", .{ nn, cscl, gf_whole, gf_centre, display_denom, quantizeHandoff(ladders, gf_whole), g.suppress_whole, g.suppress_centre });
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

/// The live-path fallback band for a tile whose zoom sits OUTSIDE every
/// overlapping cell's native window (chart.zig tileRefs). ABOVE every window
/// (z > the finest band's max — band maxima are monotonic in fineness, so the
/// finest band's max IS the highest window top) the FINEST band wins: its
/// content is the best available there, where the coarsest would render a
/// near-blank sliver of general/overview data beside finer coverage. Anywhere
/// else (below every window, or a gap between non-adjacent bands) the coarsest
/// fills — the baker's extend_min low-zoom fallback, which only ever extends
/// DOWNWARD.
pub fn fallbackBand(finest: Band, coarsest: Band, z: u8) Band {
    if (z > bandZooms(finest).max) return finest;
    return coarsest;
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

// Whether a SCAMIN-overlay mini cell joins tile `tbll`: its bounds padded by the
// mini's sector-figure reach — one tile for display-mm legs/arcs, the honest
// per-zoom span for ground-length directional legs (scene.lightReachTiles).
fn overlayNear(ov: *const Backend, tbll: [4]f64, z: u8, clat: f64) bool {
    const reach = scene.lightReachTiles(ov.light_range_m, z, clat);
    const pad_lon = (tbll[2] - tbll[0]) * reach;
    const pad_lat = (tbll[3] - tbll[1]) * reach;
    return ov.bounds[0] <= tbll[2] + pad_lon and ov.bounds[2] >= tbll[0] - pad_lon and
        ov.bounds[1] <= tbll[3] + pad_lat and ov.bounds[3] >= tbll[1] - pad_lat;
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
    // Cross-pack best-available (Baker.context): peer packs' coverage folded into
    // the finest-scale suppression scan so this pack's coarser cells defer where a
    // peer is finer. Read-only; emits nothing.
    context: []const ContextCell = &.{},
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
        // Decode the REACH_FLAG tags (buildTileMap): a reach-only cell rides this
        // tile for its sector figures alone — it joins the refs (so its legs/arcs
        // draw across the boundary) but stays out of the tile-level decisions
        // below (scamin ladders, the overscale finest-contributor scan).
        const raw_idxs = c.idx_lists[i];
        var idxs = scratch.alloc(u32, raw_idxs.len) catch return;
        var reach_only = scratch.alloc(bool, raw_idxs.len) catch return;
        var holefill = scratch.alloc(bool, raw_idxs.len) catch return;
        for (raw_idxs, 0..) |v, j| {
            idxs[j] = v & ~(REACH_FLAG | HOLEFILL_FLAG);
            reach_only[j] = (v & REACH_FLAG) != 0;
            holefill[j] = (v & HOLEFILL_FLAG) != 0;
        }
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
        // Cross-band hole-fill (buildTileMap HOLEFILL_FLAG, .extend_min pass): a
        // finer carry cell rode this below-window tile as a hole-fill candidate.
        // Keep it ONLY where the in-window band leaves an M_COVR hole at a sampled
        // point (centre + 4 corners); else drop it so the tile bakes exactly as it
        // did before hole-fill existed (byte-identical off the hole path).
        {
            var any_hf = false;
            for (holefill) |hf| if (hf) {
                any_hf = true;
                break;
            };
            if (any_hf) {
                // In-window coverage = admitted cells that are neither hole-fillers
                // nor reach-only riders (neither actually covers the tile ground).
                const own = scratch.alloc(u32, idxs.len) catch return;
                var own_n: usize = 0;
                for (idxs, 0..) |ix, j| {
                    if (!holefill[j] and !reach_only[j]) {
                        own[own_n] = ix;
                        own_n += 1;
                    }
                }
                const samples = [_][2]f64{
                    .{ clon, clat },
                    .{ tbll[0], tbll[1] }, .{ tbll[2], tbll[1] },
                    .{ tbll[0], tbll[3] }, .{ tbll[2], tbll[3] },
                };
                var hole = false;
                for (samples) |p| {
                    if (!coversAny(c.backends, own[0..own_n], p[0], p[1])) {
                        hole = true;
                        break;
                    }
                }
                if (!hole) {
                    // No hole here: compact the hole-fillers out; the rest of gen
                    // runs over the in-window set, byte-identical to before.
                    var n: usize = 0;
                    for (idxs, 0..) |ix, j| {
                        if (holefill[j]) continue;
                        idxs[n] = ix;
                        reach_only[n] = reach_only[j];
                        holefill[n] = holefill[j];
                        n += 1;
                    }
                    idxs = idxs[0..n];
                    reach_only = reach_only[0..n];
                    holefill = holefill[0..n];
                }
            }
        }
        // Fold peer-pack coverage (bake --existing) into the finest-scale scan so
        // this pack's coarser cells defer to a finer peer where it covers — the
        // cross-pack extension of the finest-cell suppression (finestCsclCtx). The
        // overscale hatch below (gf_tile) stays own-cells-only: the peer renders its
        // own hatch, so folding it here would double it.
        const gf_centre_d = finestCsclCtx(c.context, clon, clat, finestCsclAt(c.backends, idxs, clon, clat, true));
        var gf_whole: i32 = finestCsclCtx(c.context, clon, clat, finestCsclAt(c.backends, idxs, clon, clat, false));
        const corners = [4][2]f64{ .{ tbll[0], tbll[1] }, .{ tbll[2], tbll[1] }, .{ tbll[0], tbll[3] }, .{ tbll[2], tbll[3] } };
        for (corners) |cn| gf_whole = @max(gf_whole, finestCsclCtx(c.context, cn[0], cn[1], finestCsclAt(c.backends, idxs, cn[0], cn[1], false)));
        // The display window's shallow end for a tile at zoom z: D(z, φ_tile). The
        // participating cells' SCAMIN ladders quantize the handoff (quantizeHandoff).
        const display_denom = assets.displayDenomZ(z, clat);
        const ladders = scratch.alloc([]const u32, idxs.len) catch return;
        for (idxs, 0..) |idx, j| ladders[j] = if (reach_only[j]) &.{} else c.backends[idx].scamins;
        // Scale-boundary overscale refinement (specs/overscale.md): the finest
        // compilation scale CONTRIBUTING to this tile — over the quilting's own
        // participant list (any overlapping cell, reach-only riders excluded),
        // not point-sampled coverage. A cell hatches its OVERSC01 coverage only
        // when a strictly-finer cell also rides this tile (gf_tile < its cscl);
        // whole-view overscale (no finer data anywhere in the tile) emits no
        // hatch — the HUD readout's job. Hole-fill riders are excluded too: they
        // are finer than the in-window (coarsest-band) cell but supplement it in
        // its coverage holes at overview zoom, where it is NOT overscale — counting
        // them would stamp a spurious OVERSC01 over the overview's own areas.
        var gf_tile: i32 = std.math.maxInt(i32);
        for (idxs, 0..) |idx, j| {
            if (reach_only[j] or holefill[j]) continue;
            const cs = c.backends[idx].cscl;
            if (cs > 0 and cs < gf_tile) gf_tile = cs;
        }

        // refs + the encoded tile are transient (gzipped right below), so they ride
        // the per-thread scratch arena — reset after this tile, no per-tile mmap.
        // SCAMIN-standalone overlay (specs/scamin-standalone.md): the deduped
        // SCAMIN point mini cells join EVERY tile whose bounds they touch —
        // independent of bands/emitted-skip — gated per feature by the tile's
        // display window (scamin_floor = D(z+1, φ_tile); the CellRef clamp).
        // Padded by the mini's sector-figure reach — one tile for display-mm
        // legs/arcs (mirrors the LIGHT_AUG_REACH margin in the feature cull),
        // the honest per-zoom span for ground-length directional legs — so a
        // deduped light's figures reach the neighbouring tiles they cross.
        var n_ov: usize = 0;
        for (c.overlay) |*ov| {
            if (overlayNear(ov, tbll, z, clat)) n_ov += 1;
        }
        const refs = scratch.alloc(scene.CellRef, idxs.len + n_ov) catch return;
        for (idxs, 0..) |idx, j| {
            const be = &c.backends[idx];
            const g = carryGate(be.cscl, gf_centre_d, gf_whole, display_denom, ladders);
            // Overscale tag (S-52 §10.1.10.2): the display denominator at/below
            // which this cell is grossly overscale (cscl / OVERSCALE_FACTOR = X2).
            // A real ladder crossing (BakeSink scans emitted `oscl` into the SCAMIN
            // manifest), so the client flip is exact and never fires before 1x.
            const oscl: i64 = overscaleGateDenom(be.cscl);
            // Hatch this cell's OVERSC01 coverage only where it is the DISPLAYED
            // (best-available) data AT a scale boundary (specs/overscale.md v3):
            //   gf_tile < cscl   — a strictly-finer cell rides the tile (a scale
            //                      boundary exists; else it is whole-view overscale,
            //                      the HUD readout's job — §10.1.10.1).
            //   gf_whole >= cscl — this cell WINS the quilt at some sampled point
            //                      (its fills are not suppressed everywhere): the
            //                      PURE quilt result, before carryGate's band-floor
            //                      flip, so a coarse overview occluded by finer fills
            //                      (even when carried) contributes NO hatch.
            const wins_somewhere = gf_whole >= be.cscl; // == !pure_suppress_whole (cscl>0)
            refs[j] = .{ .cell = &be.cell, .portrayal = be.portrayal, .portrayal_plain = be.portrayal_plain, .portrayal_simplified = be.portrayal_simplified, .geo = be.geo, .geo_world = be.geo_world, .feat_bbox = be.feat_bbox, .suppress_fills = g.suppress_whole, .suppress_patterns = g.suppress_centre, .suppress_lines = g.suppress_centre, .suppress_points = g.suppress_whole, .smax = g.smax, .oscl = oscl, .overscale_hatch = !reach_only[j] and !holefill[j] and be.cscl > 0 and gf_tile < be.cscl and wins_somewhere, .skip_scamin_points = c.standalone, .light_range_m = be.light_range_m };
        }
        if (n_ov > 0) {
            const floor_denom = assets.displayDenomZ(z + 1, clat);
            var j = idxs.len;
            for (c.overlay) |*ov| {
                if (!overlayNear(ov, tbll, z, clat)) continue;
                refs[j] = .{ .cell = @constCast(&ov.cell), .portrayal = ov.portrayal, .portrayal_simplified = ov.portrayal_simplified, .feat_bbox = ov.feat_bbox, .feat_smax = ov.feat_smax, .scamin_floor = floor_denom, .light_range_m = ov.light_range_m };
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
    // Cross-pack best-available (bake --existing / tile57_bake_pmtiles context cells):
    // peer packs' M_COVR coverage + cscl, set ONCE by the driver. Folded into the
    // per-tile finest-scale suppression so this pack's overview defers where a peer
    // pack is finer (stops it painting over the peer's sectors). Emits nothing.
    context: []const ContextCell = &.{},
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
    /// Band handoff: `spans[own_len..]` are the next-FINER band's carry cells —
    /// they contribute ONLY at this band's max zoom (the finer band's deferred
    /// floor tiles, which this pass bakes with both bands' cells). The own cells'
    /// floor zoom is skipped (.defer_down — the next-coarser pass bakes it the
    /// same way) or the range is extended down to Baker.minzoom (.extend_min, the
    /// coarsest populated band). Caller frees the value lists + the map.
    ///
    /// Sector-figure reach: a cell with light figures (span.light_bbox) also
    /// joins a ring of ceil(lightReachTiles) tiles around that bbox, tagged
    /// REACH_FLAG — legs/arcs generated per tile (emitAugFigures) cross into
    /// neighbouring tiles the raw bbox never touches, and without the ring the
    /// geometry clips exactly at the cell-bbox tile boundary.
    fn buildTileMap(self: *Baker, band: Band, spans: []const CellSpan, own_len: usize, floor: FloorMode, clip: ?TileClip) !std.AutoHashMap(u64, std.ArrayList(u32)) {
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
        for (spans, 0..) |sp, i| {
            const b = sp.bounds;
            var z = zlo;
            var zend = zhi;
            // Carry (finer-band) cells normally contribute only at the deferred
            // floor (carry_z = this band's max). In the coarsest (.extend_min) pass
            // they ALSO ride the below-window extend zooms [zlo..carry_z-1] as
            // cross-band HOLE-FILL candidates (tagged HOLEFILL_FLAG; gen keeps them
            // only where the in-window band leaves an M_COVR hole). Other passes
            // keep the floor-only behaviour.
            var holefill_top: ?u8 = null;
            if (i >= own_len) {
                const cz = carry_z orelse continue;
                zend = cz;
                if (floor == .extend_min) {
                    z = zlo;
                    holefill_top = cz;
                } else {
                    z = cz;
                }
            } else if (zlo > zhi) continue;
            while (z <= zend) : (z += 1) {
                const holefill_z = if (holefill_top) |top| z < top else false;
                const tag: u32 = if (holefill_z) HOLEFILL_FLAG else 0;
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
                        try gop.value_ptr.append(self.gpa, @as(u32, @intCast(i)) | tag);
                    }
                }
                // Sector-figure reach ring: the tiles within ceil(reach) of the
                // cell's light bbox that the raw span above did NOT address. The
                // cell rides them tagged REACH_FLAG (figures only) so its legs/
                // arcs continue across the bbox tile boundary. Skipped for a
                // below-window hole-fill rider (it contributes fills only where
                // there's a coverage hole, not stray light figures at overview zoom).
                if (holefill_z) continue;
                const lb = sp.light_bbox orelse continue;
                const reach = scene.lightReachTiles(sp.light_range_m, z, (lb[1] + lb[3]) * 0.5);
                const m: u32 = @intFromFloat(@ceil(reach));
                const max_idx: u32 = @intCast((@as(u64, 1) << @intCast(z)) - 1);
                const lnw = lonLatToTile(lb[0], lb[3], z);
                const lse = lonLatToTile(lb[2], lb[1], z);
                var rxlo = lnw[0] -| m;
                var rxhi = @min(lse[0] +| m, max_idx);
                var rylo = lnw[1] -| m;
                var ryhi = @min(lse[1] +| m, max_idx);
                if (clip) |cl| {
                    const shift: u5 = @intCast(z - cl.zs);
                    rxlo = @max(rxlo, cl.sx << shift);
                    rxhi = @min(rxhi, ((cl.sx + 1) << shift) - 1);
                    rylo = @max(rylo, cl.sy << shift);
                    ryhi = @min(ryhi, ((cl.sy + 1) << shift) - 1);
                }
                var ry = rylo;
                while (ry <= ryhi) : (ry += 1) {
                    var rx = rxlo;
                    while (rx <= rxhi) : (rx += 1) {
                        if (rx >= xlo and rx <= xhi and ry >= ylo and ry <= yhi) continue; // raw span has it
                        const key = tileKey(z, rx, ry);
                        if (self.emitted.contains(key)) continue; // a finer band has it
                        const gop = try tilemap.getOrPut(key);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
                        try gop.value_ptr.append(self.gpa, @as(u32, @intCast(i)) | REACH_FLAG);
                    }
                }
            }
        }
        return tilemap;
    }

    /// Planned tile count for a band's pass (host §3 progress denominator): the
    /// distinct not-yet-emitted tiles their spans cover. A planned ESTIMATE — the
    /// caller may pass cheap peek-bboxes (+ attr-scan light reach) while the real
    /// bake uses slightly tighter loaded bounds — matching the Go baker's up-front
    /// planned count. `own_len` / `floor` mirror bakeBand (spans[own_len..] = the
    /// carry cells). 0 on OOM.
    pub fn plannedTiles(self: *Baker, band: Band, spans: []const CellSpan, own_len: usize, floor: FloorMode, clip: ?TileClip) usize {
        var tm = self.buildTileMap(band, spans, own_len, floor, clip) catch return 0;
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

        // Cell spans (drive the tile map: bounds + light-figure reach) + the
        // running union bbox for the header.
        const spans = try self.gpa.alloc(CellSpan, backends.len);
        defer self.gpa.free(spans);
        for (backends, 0..) |be, i| {
            spans[i] = .{ .bounds = be.bounds, .light_bbox = be.light_bbox, .light_range_m = be.light_range_m };
            self.union_b[0] = @min(self.union_b[0], be.bounds[0]);
            self.union_b[1] = @min(self.union_b[1], be.bounds[1]);
            self.union_b[2] = @max(self.union_b[2], be.bounds[2]);
            self.union_b[3] = @max(self.union_b[3], be.bounds[3]);
        }

        // Map this pass's not-yet-emitted tiles -> contributing cell indices.
        var tilemap = try self.buildTileMap(band, spans, own_len, floor, clip);
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
        var tg = TileGenCtx{ .keys = keys, .idx_lists = idx_lists, .results = results, .backends = backends, .gpa = self.gpa, .format = self.format, .pick_attrs = self.pick_attrs, .overlay = self.overlay, .context = self.context, .standalone = self.scamin_standalone, .progress = progress, .pctx = ctx, .base = self.count, .band_base = self.band_base, .band_total = self.band_total, .band_index = self.band_index, .band_count = self.band_count, .band_name = bname, .done = &done };
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

    /// Bake a band's FILL-DOWN tiles: the zooms BELOW its native window
    /// (bandZooms(band).min) at the areas where it is the coarsest band covering
    /// the ground. `extend_min` gives the *globally* coarsest populated band a
    /// fill to minzoom, but a location covered only by bands FINER than that one
    /// (e.g. a bay charted just by coastal/approach cells while the pack's only
    /// overview cells lie elsewhere) gets no low-zoom tiles — the district-pack
    /// "empty z6–z8 hole". The live tileRefs path fills such a tile from the
    /// coarsest cell whose bbox overlaps it (fallbackBand); this mirrors that in
    /// the banded bake so a bundle bake matches the live oracle.
    ///
    /// `coarser` = the footprints of every strictly-coarser populated band's
    /// cells (bbox + that band's max zoom). A fill-down tile is skipped where any
    /// such box with `max_z >= z` overlaps it — that coarser band produces the
    /// tile (natively or via its own fill), so it owns it (coarsest-covering
    /// wins). `backends` should already be filtered by the caller to the cells
    /// not wholly blanketed by a coarser band (coveredByCoarser) so no work is
    /// wasted loading fully-covered cells. Call AFTER the band's bakeBand pass
    /// (finest→coarsest), with the same overlay/emitted state.
    pub fn bakeFillDown(self: *Baker, band: Band, backends: []Backend, coarser: []const CoarserBox, progress: Progress, ctx: ?*anyopaque) !void {
        if (backends.len == 0) return;
        if (fillDownZooms(band, self.minzoom, self.maxzoom) == null) return;

        const spans = try self.gpa.alloc(CellSpan, backends.len);
        defer self.gpa.free(spans);
        for (backends, 0..) |be, i| {
            // These cells were already union'd into the header by their bakeBand
            // pass; re-min/max is idempotent, so union stays correct even for a
            // cell that only ever contributes fill-down tiles.
            spans[i] = .{ .bounds = be.bounds, .light_bbox = be.light_bbox, .light_range_m = be.light_range_m };
            self.union_b[0] = @min(self.union_b[0], be.bounds[0]);
            self.union_b[1] = @min(self.union_b[1], be.bounds[1]);
            self.union_b[2] = @max(self.union_b[2], be.bounds[2]);
            self.union_b[3] = @max(self.union_b[3], be.bounds[3]);
        }

        var tilemap = try self.buildFillDownMap(band, spans, coarser);
        defer {
            var vit = tilemap.valueIterator();
            while (vit.next()) |v| v.deinit(self.gpa);
            tilemap.deinit();
        }

        // Generate + collect exactly like bakeBand (kept separate so bakeBand
        // stays byte-identical; fill-down tiles are below the band's window so no
        // finer cell rides them — the overscale-hatch default of "off" is right).
        const n = tilemap.count();
        if (n == 0) return;
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

        const bname: [*:0]const u8 = @tagName(band).ptr;
        var done = std.atomic.Value(usize).init(0);
        var tg = TileGenCtx{ .keys = keys, .idx_lists = idx_lists, .results = results, .backends = backends, .gpa = self.gpa, .format = self.format, .pick_attrs = self.pick_attrs, .overlay = self.overlay, .context = self.context, .standalone = self.scamin_standalone, .progress = progress, .pctx = ctx, .base = self.count, .band_base = self.band_base, .band_total = self.band_total, .band_index = self.band_index, .band_count = self.band_count, .band_name = bname, .done = &done };
        parallelFor(self.gpa, n, &tg, TileGenCtx.gen);

        for (keys, results) |key, mvt_opt| {
            const mvt_bytes = mvt_opt orelse continue;
            defer self.gpa.free(mvt_bytes);
            try self.sink.func(self.sink.ctx, @intCast(key >> 48), @intCast((key >> 24) & 0xFFFFFF), @intCast(key & 0xFFFFFF), mvt_bytes);
            try self.emitted.put(key, {});
            self.count += 1;
        }
        if (progress) |cb| cb(ctx, 1, self.count - self.band_base, self.band_total, self.band_index, self.band_count, bname);
    }

    /// Build the fill-down tile→contributor map (see bakeFillDown): every
    /// not-yet-emitted (z,x,y) with z in [minzoom .. band.min-1] a cell's bbox
    /// covers, EXCEPT those a strictly-coarser producing band already owns.
    fn buildFillDownMap(self: *Baker, band: Band, spans: []const CellSpan, coarser: []const CoarserBox) !std.AutoHashMap(u64, std.ArrayList(u32)) {
        var tilemap = std.AutoHashMap(u64, std.ArrayList(u32)).init(self.gpa);
        errdefer {
            var vit = tilemap.valueIterator();
            while (vit.next()) |v| v.deinit(self.gpa);
            tilemap.deinit();
        }
        const fz = fillDownZooms(band, self.minzoom, self.maxzoom) orelse return tilemap;
        for (spans, 0..) |sp, i| {
            const b = sp.bounds;
            var z = fz.min;
            while (z <= fz.max) : (z += 1) {
                const nw = lonLatToTile(b[0], b[3], z);
                const se = lonLatToTile(b[2], b[1], z);
                var ty = nw[1];
                while (ty <= se[1]) : (ty += 1) {
                    var tx = nw[0];
                    while (tx <= se[0]) : (tx += 1) {
                        const key = tileKey(z, tx, ty);
                        if (self.emitted.contains(key)) continue; // a finer/coarser band has it
                        const tb = tile.tileBoundsLonLat(z, tx, ty); // [w,s,e,n]
                        var gated = false;
                        for (coarser) |cb| {
                            if (cb.max_z >= z and bboxOverlap(cb.bbox, tb)) {
                                gated = true;
                                break;
                            }
                        }
                        if (gated) continue; // the coarser band owns this tile
                        const gop = try tilemap.getOrPut(key);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
                        try gop.value_ptr.append(self.gpa, @intCast(i));
                    }
                }
            }
        }
        return tilemap;
    }
};

/// A strictly-coarser band's cell footprint for the fill-down gate: the cell's
/// bbox [w,s,e,n] and the max zoom its band produces tiles at
/// (bandZooms(band).max). A fill-down tile at zoom z is owned by the coarser
/// band where any such box with `max_z >= z` overlaps it (that band produces the
/// tile natively or via its own fill), matching the live fallbackBand
/// "coarsest-covering wins".
pub const CoarserBox = struct { bbox: [4]f64, max_z: u8 };

fn bboxOverlap(a: [4]f64, b: [4]f64) bool {
    return a[0] <= b[2] and a[2] >= b[0] and a[1] <= b[3] and a[3] >= b[1];
}

/// Whether a cell's bbox is wholly inside some single strictly-coarser cell's
/// bbox — the cheap driver-side pre-filter that skips loading a cell for the
/// fill-down pass when a coarser band certainly blankets it (the per-tile gate
/// would suppress all its fill-down tiles anyway). Conservative: a cell covered
/// only by a UNION of coarser boxes is still loaded, then contributes nothing.
pub fn coveredByCoarser(bbox: [4]f64, coarser: []const CoarserBox) bool {
    for (coarser) |c| {
        if (bbox[0] >= c.bbox[0] and bbox[2] <= c.bbox[2] and
            bbox[1] >= c.bbox[1] and bbox[3] <= c.bbox[3]) return true;
    }
    return false;
}

/// A band's fill-down zoom span under the archive clamp: [minzoom ..
/// min(maxzoom, band.min-1)] — the zooms below its native window it must fill
/// where it is the coarsest covering band. Null when the band is the coarsest
/// (min==0, nothing below) or the span is empty under the clamp.
pub fn fillDownZooms(band: Band, minzoom: u8, maxzoom: u8) ?ZoomRange {
    const fl = bandZooms(band).min;
    if (fl == 0) return null;
    const zhi = @min(maxzoom, fl - 1);
    if (minzoom > zhi) return null;
    return .{ .min = minzoom, .max = zhi };
}

test "quantizeHandoff: smallest ladder value >= cscl, raw-cscl fallback" {
    const fine = [_]u32{ 90_000, 260_000, 350_000 };
    const coarse = [_]u32{ 700_000, 1_000_000 };
    const ladders = [_][]const u32{ &fine, &coarse };
    // 200k quantizes up onto the fine cell's 260k (the crossing where its bulk
    // activates) — a +30% snap, within the nearby-rung cap.
    try std.testing.expectEqual(@as(i64, 260_000), quantizeHandoff(&ladders, 200_000));
    // An exact ladder member maps to itself.
    try std.testing.expectEqual(@as(i64, 260_000), quantizeHandoff(&ladders, 260_000));
    // Above every fine value the only rung (700k) overshoots 400k by 75% — beyond
    // the ~30% cap, so it is rejected in favour of the raw crossing (400k), keeping
    // the band-floor carry window open instead of collapsing it up a ladder gap.
    try std.testing.expectEqual(@as(i64, 400_000), quantizeHandoff(&ladders, 400_000));
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

test "fillDownZooms / coveredByCoarser" {
    // Below-window fill span = [minzoom .. band.min-1], clamped; coarsest band and
    // clamped-out spans yield null.
    try std.testing.expectEqual(@as(?ZoomRange, .{ .min = 0, .max = 8 }), fillDownZooms(.coastal, 0, 12));
    try std.testing.expectEqual(@as(?ZoomRange, .{ .min = 3, .max = 8 }), fillDownZooms(.coastal, 3, 12));
    try std.testing.expectEqual(@as(?ZoomRange, null), fillDownZooms(.overview, 0, 12)); // coarsest: nothing below
    try std.testing.expectEqual(@as(?ZoomRange, null), fillDownZooms(.coastal, 9, 12)); // minzoom >= floor
    try std.testing.expectEqual(@as(?ZoomRange, .{ .min = 8, .max = 10 }), fillDownZooms(.approach, 8, 12)); // below approach.min=11
    try std.testing.expectEqual(@as(?ZoomRange, null), fillDownZooms(.approach, 11, 12)); // clamped out (min>=floor)

    const boxes = [_]CoarserBox{.{ .bbox = .{ -80, 30, -70, 40 }, .max_z = 7 }};
    try std.testing.expect(coveredByCoarser(.{ -76, 38, -75, 39 }, &boxes)); // inside
    try std.testing.expect(!coveredByCoarser(.{ -76, 38, -69, 39 }, &boxes)); // spills east
    try std.testing.expect(!coveredByCoarser(.{ -76, 38, -75, 39 }, &.{})); // nothing coarser
}

test "fill-down map: coastal-only area fills below its window; a covering coarser band gates it" {
    const gpa = std.testing.allocator;
    var sink = CollectSink{ .a = gpa, .tiles = std.AutoHashMap(u64, []u8).init(gpa) };
    defer sink.tiles.deinit();
    var baker = Baker.init(gpa, 0, 12, .{ .ctx = &sink, .func = CollectSink.run });
    defer baker.deinit();

    // A coastal cell over a bay (~ -76.45, 38.90). Fill-down zooms are 0..8.
    const bay = [4]f64{ -76.6, 38.8, -76.3, 39.0 };
    const spans = [_]CellSpan{.{ .bounds = bay }};
    const t8 = lonLatToTile(-76.45, 38.90, 8);
    const t6 = lonLatToTile(-76.45, 38.90, 6);

    const freeMap = struct {
        fn f(m: *std.AutoHashMap(u64, std.ArrayList(u32)), g: std.mem.Allocator) void {
            var vit = m.valueIterator();
            while (vit.next()) |v| v.deinit(g);
            m.deinit();
        }
    }.f;

    // No coarser band covers the bay: every z0..8 tile it touches fills (the fix —
    // old behavior baked none of these, leaving the district-pack z6–z8 hole).
    {
        var m = try baker.buildFillDownMap(.coastal, &spans, &.{});
        defer freeMap(&m, gpa);
        try std.testing.expect(m.count() > 0);
        try std.testing.expect(m.contains(tileKey(8, t8[0], t8[1])));
        try std.testing.expect(m.contains(tileKey(6, t6[0], t6[1])));
    }

    // An OVERVIEW cell (max zoom 7) whose bbox covers the bay owns z0..7 — but not
    // z8 (7 < 8), so the coastal cell still fills the inter-band-gap zoom.
    {
        const ov = [_]CoarserBox{.{ .bbox = .{ -78, 38, -75, 40 }, .max_z = bandZooms(.overview).max }};
        var m = try baker.buildFillDownMap(.coastal, &spans, &ov);
        defer freeMap(&m, gpa);
        try std.testing.expect(m.contains(tileKey(8, t8[0], t8[1]))); // z8: not gated
        try std.testing.expect(!m.contains(tileKey(6, t6[0], t6[1]))); // z6: overview owns it
    }

    // A GENERAL cell (max zoom 9) covering the bay produces every z0..8 tile, so
    // the coastal fill-down is fully gated — the reason a subset WITH the general
    // cell present (51-/340-cell sets) never reproduces the hole.
    {
        const gen = [_]CoarserBox{.{ .bbox = .{ -78, 38, -75, 40 }, .max_z = bandZooms(.general).max }};
        var m = try baker.buildFillDownMap(.coastal, &spans, &gen);
        defer freeMap(&m, gpa);
        try std.testing.expectEqual(@as(usize, 0), m.count());
    }

    // A tile a coarser pass already emitted is never re-baked.
    {
        try baker.emitted.put(tileKey(8, t8[0], t8[1]), {});
        var m = try baker.buildFillDownMap(.coastal, &spans, &.{});
        defer freeMap(&m, gpa);
        try std.testing.expect(!m.contains(tileKey(8, t8[0], t8[1])));
    }
}

test "fill-down bake: a coastal-only bay gets low-zoom tiles the overview extend_min misses" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A coastal 1:200k cell over a bay near (0.35,0.35); the pack's only OVERVIEW
    // cell sits far away (10.5,10.5) — populated (so IT is the globally-coarsest
    // band the extend_min fill rides), but it does not cover the bay. Without
    // fill-down the bay has no tiles below coastal's window (z<9): the reported
    // district-pack z6–z8 hole.
    const scamin_attr = [_]s57.Attr{.{ .code = 133, .value = "260000" }};
    const feats = [_]s57.Feature{.{
        .rcnm = 0,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &scamin_attr,
    }};
    var bay_cell = try testCell(gpa, 0.35, 0.35, 200_000, &feats);
    defer bay_cell.deinit();
    var ov_cell = try testCell(gpa, 10.5, 10.5, 3_000_000, &feats);
    defer ov_cell.deinit();

    const ring = [_]s57.LonLat{
        s57.LonLat.init(-2, -2), s57.LonLat.init(3, -2),
        s57.LonLat.init(3, 3),   s57.LonLat.init(-2, 3),
        s57.LonLat.init(-2, -2),
    };
    const rings = [_][]const s57.LonLat{&ring};
    const cover = [_][]const []const s57.LonLat{&rings};
    const bay_bounds = [4]f64{ 0.2, 0.2, 0.5, 0.5 };
    const ov_bounds = [4]f64{ 10.2, 10.2, 10.8, 10.8 };
    const streams = [_]?[]const u8{"DrawingPriority:7;PointInstruction:BOYLAT01"};
    const scamins = [_]u32{260_000};

    var bay = Backend{ .cell = bay_cell, .portrayal = &streams, .bounds = bay_bounds, .cscl = 200_000, .coverage = &cover, .scamins = &scamins };
    var ov = Backend{ .cell = ov_cell, .portrayal = &streams, .bounds = ov_bounds, .cscl = 3_000_000, .coverage = &cover, .scamins = &scamins };

    var sink = CollectSink{ .a = a, .tiles = std.AutoHashMap(u64, []u8).init(a) };
    var baker = Baker.init(gpa, 0, 12, .{ .ctx = &sink, .func = CollectSink.run });
    defer baker.deinit();

    // Driver order (finest→coarsest): coastal native pass, coastal fill-down gated
    // by the strictly-coarser overview footprint, then the overview extend_min pass.
    const overview_box = [_]CoarserBox{.{ .bbox = ov_bounds, .max_z = bandZooms(.overview).max }};
    try baker.bakeBand(.coastal, (&bay)[0..1], 1, .defer_down, null, null, null);
    try baker.bakeFillDown(.coastal, (&bay)[0..1], &overview_box, null, null);
    try baker.bakeBand(.overview, (&ov)[0..1], 1, .extend_min, null, null, null);

    // The bay's below-window tiles now carry content (the fix). Old behavior: none.
    for ([_]u8{ 6, 7, 8 }) |z| {
        const t = lonLatToTile(0.35, 0.35, z);
        try std.testing.expect(sink.tiles.get(tileKey(z, t[0], t[1])) != null);
    }
    // The far-away overview extend_min tiles did not spill onto the bay column.
    const ov_t6 = lonLatToTile(10.5, 10.5, 6);
    const bay_t6 = lonLatToTile(0.35, 0.35, 6);
    try std.testing.expect(sink.tiles.get(tileKey(6, ov_t6[0], ov_t6[1])) != null);
    try std.testing.expect(ov_t6[0] != bay_t6[0] or ov_t6[1] != bay_t6[1]);
}

test "overscale: a coarse cell occluded everywhere by finer coverage emits NO hatch (specs/overscale.md v3 defect 2)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // IDENTICAL coverage: the fine 1:200k cell wins the quilt over the whole tile,
    // so the coarse 1:1.2M cell is the DISPLAYED data NOWHERE. Even though the
    // band-floor carry keeps a coarse copy alive at z9 (its SCAMIN-declutter fill),
    // S-52 §10.1.10.2 shows AP(OVERSC01) only on the smaller-scale ENC area that is
    // actually displayed — so the coarse cell must emit NO hatch (the old carry
    // heuristic bled one through every gap in the finer fills). The fine cell is
    // the finest contributor, so it never hatches either.
    const scamin_attr = [_]s57.Attr{.{ .code = 133, .value = "260000" }};
    const coarse_attr = [_]s57.Attr{.{ .code = 133, .value = "800000" }};
    const catcov_attr = [_]s57.Attr{.{ .code = 18, .value = "1" }}; // CATCOV=1
    const fine_feats = [_]s57.Feature{
        .{ .rcnm = 0, .rcid = 1, .prim = 1, .objl = 14, .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }}, .attrs = &scamin_attr },
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 302, .attrs = &catcov_attr },
    };
    const coarse_feats = [_]s57.Feature{
        .{ .rcnm = 0, .rcid = 1, .prim = 1, .objl = 14, .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }}, .attrs = &coarse_attr },
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 302, .attrs = &catcov_attr },
    };
    var fine_cell = try testCell(gpa, 0.35, 0.35, 200_000, &fine_feats);
    defer fine_cell.deinit();
    var coarse_cell = try testCell(gpa, 0.35, 0.35, 1_200_000, &coarse_feats);
    defer coarse_cell.deinit();

    // Both cells cover the whole tile (same big ring).
    var ring = [_]s57.LonLat{ s57.LonLat.init(-2, -2), s57.LonLat.init(3, -2), s57.LonLat.init(3, 3), s57.LonLat.init(-2, 3), s57.LonLat.init(-2, -2) };
    const rings = [_][]const s57.LonLat{&ring};
    const cover = [_][]const []const s57.LonLat{&rings};
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

    // z9 (band-floor carry) and z10 (whole-view, §10.1.10.1) must BOTH be hatch-free.
    const t9 = lonLatToTile(0.35, 0.35, 9);
    try std.testing.expectEqual(@as(usize, 0), try countOverscHatches(a, &sink, 9, t9[0], t9[1]));
    const t10 = lonLatToTile(0.35, 0.35, 10);
    try std.testing.expectEqual(@as(usize, 0), try countOverscHatches(a, &sink, 10, t10[0], t10[1]));
}

test "overscale: a coarse-only patch beside finer coverage hatches at the X2 gate (S-52 §10.1.10.2)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Genuine scale boundary: the fine 1:200k cell covers only the EAST of the tile
    // (lon >= 0.5); the coarse 1:1.2M cell covers all of it. Over the west/centre
    // the coarse cell WINS the quilt (it is the displayed smaller-scale data) and,
    // with a strictly-finer cell riding the tile, it hatches its coarse-only patch.
    // The hatch carries the X2 gate tag oscl = cscl/OVERSCALE_FACTOR = 600000 (never
    // 1.2M quantized-up, defect 1) and NO smax (it wins outright, not a carry). The
    // fine cell, the finest contributor, still emits no hatch.
    const scamin_attr = [_]s57.Attr{.{ .code = 133, .value = "260000" }};
    const coarse_attr = [_]s57.Attr{.{ .code = 133, .value = "800000" }};
    const catcov_attr = [_]s57.Attr{.{ .code = 18, .value = "1" }};
    const fine_feats = [_]s57.Feature{
        .{ .rcnm = 0, .rcid = 1, .prim = 1, .objl = 14, .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }}, .attrs = &scamin_attr },
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 302, .attrs = &catcov_attr },
    };
    const coarse_feats = [_]s57.Feature{
        .{ .rcnm = 0, .rcid = 1, .prim = 1, .objl = 14, .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }}, .attrs = &coarse_attr },
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 302, .attrs = &catcov_attr },
    };
    var fine_cell = try testCell(gpa, 0.35, 0.35, 200_000, &fine_feats);
    defer fine_cell.deinit();
    var coarse_cell = try testCell(gpa, 0.35, 0.35, 1_200_000, &coarse_feats);
    defer coarse_cell.deinit();

    // Coarse covers everything; fine covers only lon >= 0.5 (east of the ~0.35
    // tile centre) so the west + centre sample points are coarse-only.
    var big = [_]s57.LonLat{ s57.LonLat.init(-2, -2), s57.LonLat.init(3, -2), s57.LonLat.init(3, 3), s57.LonLat.init(-2, 3), s57.LonLat.init(-2, -2) };
    var east = [_]s57.LonLat{ s57.LonLat.init(0.5, -2), s57.LonLat.init(3, -2), s57.LonLat.init(3, 3), s57.LonLat.init(0.5, 3), s57.LonLat.init(0.5, -2) };
    const big_rings = [_][]const s57.LonLat{&big};
    const east_rings = [_][]const s57.LonLat{&east};
    const coarse_cover = [_][]const []const s57.LonLat{&big_rings};
    const fine_cover = [_][]const []const s57.LonLat{&east_rings};
    var big_parts = [_][]s57.LonLat{&big};
    var east_parts = [_][]s57.LonLat{&east};
    const coarse_geo = [_]?[][]s57.LonLat{ null, &big_parts };
    const fine_geo = [_]?[][]s57.LonLat{ null, &east_parts };
    const bounds = [4]f64{ 0.2, 0.2, 0.5, 0.5 };
    const streams = [_]?[]const u8{ "DrawingPriority:7;PointInstruction:BOYLAT01", null };
    const fine_scamins = [_]u32{260_000};
    const coarse_scamins = [_]u32{800_000};
    var fine = Backend{ .cell = fine_cell, .portrayal = &streams, .geo = &fine_geo, .bounds = bounds, .cscl = 200_000, .coverage = &fine_cover, .scamins = &fine_scamins };
    const coarse = Backend{ .cell = coarse_cell, .portrayal = &streams, .geo = &coarse_geo, .bounds = bounds, .cscl = 1_200_000, .coverage = &coarse_cover, .scamins = &coarse_scamins };

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
            if (oscl == 100_000) { // fine 200k -> X2 gate 100000
                fine_hatch += 1;
            } else if (oscl == 600_000) { // coarse 1.2M -> X2 gate 600000
                try std.testing.expectEqual(@as(?i64, null), smax); // wins outright, not carried
                coarse_hatch += 1;
            } else return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), fine_hatch);
    try std.testing.expectEqual(@as(usize, 1), coarse_hatch);
}

// Count AP(OVERSC01) hatch features in a baked tile (0 when the tile is absent).
fn countOverscHatches(a: std.mem.Allocator, sink: *CollectSink, z: u8, x: u32, y: u32) !usize {
    const bytes = sink.tiles.get(tileKey(z, x, y)) orelse return 0;
    const raw = try gzip.decompress(a, bytes);
    const layers = try mvt.decode(a, raw);
    var n: usize = 0;
    for (layers) |L| {
        if (!std.mem.eql(u8, L.name, "area_patterns")) continue;
        for (L.features) |f| for (f.properties) |pr| {
            if (std.mem.eql(u8, pr.key, "pattern_name") and std.mem.eql(u8, pr.value.string, "OVERSC01")) n += 1;
        };
    }
    return n;
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

test "buildTileMap reach ring: a light cell contributes one ring beyond its bbox" {
    const gpa = std.testing.allocator;
    const nop = struct {
        fn run(_: ?*anyopaque, _: u8, _: u32, _: u32, _: []const u8) anyerror!void {}
    };
    var baker = Baker.init(gpa, 13, 13, .{ .ctx = null, .func = nop.run });
    defer baker.deinit();

    // A cell spanning exactly one z13 tile near (0.02, 0.02).
    const t = lonLatToTile(0.02, 0.02, 13);
    const tb = tile.tileBoundsLonLat(13, t[0], t[1]);
    const inner = [4]f64{
        tb[0] + (tb[2] - tb[0]) * 0.25, tb[1] + (tb[3] - tb[1]) * 0.25,
        tb[0] + (tb[2] - tb[0]) * 0.75, tb[1] + (tb[3] - tb[1]) * 0.75,
    };

    // No light figures: exactly the one tile its bbox touches.
    const plain = [_]CellSpan{.{ .bounds = inner }};
    try std.testing.expectEqual(@as(usize, 1), baker.plannedTiles(.harbor, &plain, 1, .extend_min, null));

    // Display-mm figures (reach_tiles = 1): the bbox tile + its 3x3 ring.
    const lit = [_]CellSpan{.{ .bounds = inner, .light_bbox = inner }};
    try std.testing.expectEqual(@as(usize, 9), baker.plannedTiles(.harbor, &lit, 1, .extend_min, null));

    // The ring members carry REACH_FLAG; the home tile doesn't.
    var tm = try baker.buildTileMap(.harbor, &lit, 1, .extend_min, null);
    defer {
        var vit = tm.valueIterator();
        while (vit.next()) |v| v.deinit(gpa);
        tm.deinit();
    }
    var it = tm.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const home = (k >> 48) == 13 and ((k >> 24) & 0xFFFFFF) == t[0] and (k & 0xFFFFFF) == t[1];
        try std.testing.expectEqual(@as(usize, 1), e.value_ptr.items.len);
        const v = e.value_ptr.items[0];
        try std.testing.expectEqual(home, (v & REACH_FLAG) == 0);
        try std.testing.expectEqual(@as(u32, 0), v & ~REACH_FLAG);
    }

    // Ground-length legs widen the ring honestly: 9 nmi at z13 near the equator
    // ≈ 3.4 tiles -> ceil 4 -> a 9x9 block around the one-tile bbox.
    const ground = [_]CellSpan{.{ .bounds = inner, .light_bbox = inner, .light_range_m = 9.0 * 1852.0 }};
    try std.testing.expectEqual(@as(usize, 9 * 9), baker.plannedTiles(.harbor, &ground, 1, .extend_min, null));
}

test "ground-length directional leg bakes across every tile it crosses" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A directional light at a z13 tile centre near (0.30, 0.30) whose portrayal
    // draws a 20 km GeographicCRS leg due east — ~4.1 z13-tiles, far beyond the
    // one-tile display-mm reach. Every tile the leg crosses must carry it.
    const feats = [_]s57.Feature{.{
        .rcnm = 100,
        .rcid = 1,
        .prim = 1,
        .objl = 75,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    }};
    const home = lonLatToTile(0.30, 0.30, 13);
    const htb = tile.tileBoundsLonLat(13, home[0], home[1]);
    const anchor_lon = (htb[0] + htb[2]) * 0.5;
    const anchor_lat = (htb[1] + htb[3]) * 0.5;
    var cell = try testCell(gpa, anchor_lon, anchor_lat, 12_000, &feats);
    defer cell.deinit();

    const streams = [_]?[]const u8{
        "ViewingGroup:27070;DrawingPriority:8;LineStyle:dash,3.51,0.32,CHBLK;AugmentedRay:GeographicCRS,90.0,GeographicCRS,20000;LineInstruction:_simple_;ClearGeometry",
    };
    const fbb = [_]?[4]f64{.{ anchor_lon, anchor_lat, anchor_lon, anchor_lat }};
    // Exact reach from the streams — what the real bake paths compute.
    const lr = scene.collectLightReach(&cell, &streams);
    try std.testing.expectEqual(@as(f64, 20_000), lr.range_m);
    const bounds = [4]f64{ htb[0], htb[1], htb[2], htb[3] }; // one-tile cell bbox
    var be = Backend{
        .cell = cell,
        .portrayal = &streams,
        .feat_bbox = &fbb,
        .bounds = bounds,
        .cscl = 12_000,
        .light_bbox = lr.bbox,
        .light_range_m = lr.range_m,
    };

    var sink = CollectSink{ .a = a, .tiles = std.AutoHashMap(u64, []u8).init(a) };
    var baker = Baker.init(gpa, 13, 13, .{ .ctx = &sink, .func = CollectSink.run });
    defer baker.deinit();
    try baker.bakeBand(.harbor, (&be)[0..1], 1, .extend_min, null, null, null);

    // 20 km at z13/lat 0.3 = 4.088 tiles from the anchor (tile centre): the leg
    // crosses the home tile + 4 eastward neighbours and stops inside the 4th.
    var dx: u32 = 0;
    while (dx <= 4) : (dx += 1) {
        const bytes = sink.tiles.get(tileKey(13, home[0] + dx, home[1])) orelse return error.TestUnexpectedResult;
        const raw = try gzip.decompress(a, bytes);
        const layers = try mvt.decode(a, raw);
        var legs: usize = 0;
        for (layers) |L| {
            if (std.mem.eql(u8, L.name, "lines")) legs += L.features.len;
        }
        try std.testing.expect(legs > 0);
    }
    // One tile past the leg's end: addressed by the ceil(4.088)=5 ring but the
    // clipped geometry is empty, so no tile is emitted.
    try std.testing.expect(sink.tiles.get(tileKey(13, home[0] + 5, home[1])) == null);
}

test "lightReachTiles: ground-leg tile spans at z13/z16" {
    // 9 nmi = 16668 m at lat 39.2: ~4.4 tiles at z13, ~35 tiles at z16 (the
    // proven US4MD1EC directional-leg reach), and never below the 1-tile
    // display-mm floor.
    const m = 9.0 * 1852.0;
    try std.testing.expectApproxEqAbs(@as(f64, 4.397), scene.lightReachTiles(m, 13, 39.2), 0.05);
    try std.testing.expectApproxEqAbs(@as(f64, 35.18), scene.lightReachTiles(m, 16, 39.2), 0.4);
    try std.testing.expectEqual(@as(f64, 1.0), scene.lightReachTiles(0, 16, 39.2));
    try std.testing.expectEqual(@as(f64, 1.0), scene.lightReachTiles(100.0, 8, 39.2)); // tiny leg: mm floor wins
}

test "fallbackBand: finest above all windows, coarsest below / in gaps" {
    // The defect-3 scenario: approach (11-13) + general (7-9) coverage, z14 —
    // above every window, the finest (approach) must win, NOT near-blank general.
    try std.testing.expectEqual(Band.approach, fallbackBand(.approach, .general, 14));
    // Below every window: the coarsest fills down (extend_min behaviour).
    try std.testing.expectEqual(Band.general, fallbackBand(.approach, .general, 3));
    // A gap between non-adjacent bands (approach 11-13 vs berthing 16-18, z14):
    // not above the finest window, so the coarsest still fills.
    try std.testing.expectEqual(Band.approach, fallbackBand(.berthing, .approach, 14));
    // Above even berthing's top: finest.
    try std.testing.expectEqual(Band.berthing, fallbackBand(.berthing, .approach, 19));
}

test "bandOf / bandZooms match the Go reference bands" {
    try std.testing.expectEqual(Band.harbor, bandOf(12_000)); // [13,16]
    try std.testing.expectEqual(@as(u8, 13), bandZooms(bandOf(12_000)).min);
    try std.testing.expectEqual(Band.overview, bandOf(3_000_000)); // [0,7]
    try std.testing.expectEqual(Band.approach, bandOf(80_000)); // [11,13]
    try std.testing.expectEqual(Band.approach, bandOf(0)); // CSCL 0 -> 50k -> approach
    try std.testing.expectEqual(Band.coastal, bandOf(200_000)); // [9,11]
}
