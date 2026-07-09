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
//! the coarser band down (retired — the coverage-clipped composite owns the
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
const geometry = @import("geo"); // Martinez boolean for the coverage-clipped composite

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
    // tilejson scamin ladder's per-cell slice (client filter-gate crossings).
    scamins: []const u32 = &.{},
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

// The cross-band coverage oracle, ONCE. `finestCsclAt`/`coversAny` used to be
// re-coded byte-for-byte on the live path (chart.zig `finestCsclAtLive`/
// `coversAnyLive`) — the single largest bake-vs-live drift source. Both sides now
// call these generics with a small duck-typed accessor (`ctx`) that exposes the
// only things that differed: `cscl(i) i32`, `coverage(i) []const []const []const
// s57.LonLat`, `bounds(i) [4]f64`. Byte-identical to the old pair by construction.

/// The finest (smallest 1:N) compilation scale among `idxs` whose coverage
/// contains (lon,lat); `maxInt` when none — so `finestCsclAtCtx(...) < my_cscl`
/// means "a strictly finer cell covers this point" (a cell never undercuts
/// itself: its own cscl isn't < its own cscl). A cell with no M_COVR uses its
/// bbox as coverage only when `include_derived` (the Go rule: derived extents
/// count for points/lines, never fills). cscl<=0 (unknown) can't be a finer owner.
pub fn finestCsclAtCtx(ctx: anytype, idxs: []const u32, lon: f64, lat: f64, include_derived: bool) i32 {
    var best: i32 = std.math.maxInt(i32);
    for (idxs) |i| {
        const cscl = ctx.cscl(i);
        if (cscl <= 0 or cscl >= best) continue;
        const cov = ctx.coverage(i);
        const covered = if (cov.len > 0)
            s57.coverageContains(cov, lon, lat)
        else dv: {
            const bb = ctx.bounds(i);
            break :dv include_derived and (lon >= bb[0] and lon <= bb[2] and lat >= bb[1] and lat <= bb[3]);
        };
        if (covered) best = cscl;
    }
    return best;
}

/// Whether ANY cell in `idxs` covers (lon,lat): real M_COVR containment, or the
/// cell's bbox when it has no M_COVR. Unlike finestCsclAtCtx this also counts
/// cscl<=0 cells — a coverage-hole test must treat any present data as coverage
/// (an unknown-scale cell still fills the ground). Used by the cross-band
/// hole-fill admission: a coarser in-window band leaves a HOLE at a sampled point
/// none of its cells cover, and a finer out-of-window cell that DOES cover there
/// is admitted to fill it (see TileGenCtx.gen / chart.zig tileRefs).
pub fn coversAnyCtx(ctx: anytype, idxs: []const u32, lon: f64, lat: f64) bool {
    for (idxs) |i| {
        const cov = ctx.coverage(i);
        const covered = if (cov.len > 0)
            s57.coverageContains(cov, lon, lat)
        else dv: {
            const bb = ctx.bounds(i);
            break :dv (lon >= bb[0] and lon <= bb[2] and lat >= bb[1] and lat <= bb[3]);
        };
        if (covered) return true;
    }
    return false;
}

/// The baker's own-cell accessor for the shared oracle above.
const BackendCov = struct {
    backends: []const Backend,
    pub inline fn cscl(self: BackendCov, i: u32) i32 {
        return self.backends[i].cscl;
    }
    pub inline fn coverage(self: BackendCov, i: u32) []const []const []const s57.LonLat {
        return self.backends[i].coverage;
    }
    pub inline fn bounds(self: BackendCov, i: u32) [4]f64 {
        return self.backends[i].bounds;
    }
    pub inline fn name(self: BackendCov, i: u32) []const u8 {
        return self.backends[i].cell.name;
    }
    pub inline fn date(self: BackendCov, i: u32) []const u8 {
        return self.backends[i].cell.dsid.isdt;
    }
};

fn finestCsclAt(backends: []const Backend, idxs: []const u32, lon: f64, lat: f64, include_derived: bool) i32 {
    return finestCsclAtCtx(BackendCov{ .backends = backends }, idxs, lon, lat, include_derived);
}

fn coversAny(backends: []const Backend, idxs: []const u32, lon: f64, lat: f64) bool {
    return coversAnyCtx(BackendCov{ .backends = backends }, idxs, lon, lat);
}

// Whether (date da, name na) orders strictly before (db, nb) in the equal-scale
// clip order: newer DSID issue/update date first (YYYYMMDD compares lexically; a
// dated cell orders before an undated one), then cell name ascending - total and
// deterministic for distinct cells, so bake output is byte-stable. Public so the
// ownership partition assigns the same tie-break winner as the bake.
pub fn ordersBeforeKeys(da: []const u8, na: []const u8, db: []const u8, nb: []const u8) bool {
    if (!std.mem.eql(u8, da, db)) return std.mem.lessThan(u8, db, da); // newer first
    return std.mem.lessThan(u8, na, nb);
}

fn ordersBefore(ctx: anytype, a_idx: u32, b_idx: u32) bool {
    return ordersBeforeKeys(ctx.date(a_idx), ctx.name(a_idx), ctx.date(b_idx), ctx.name(b_idx));
}

/// coverClipForCell's per-tile verdict — the cheap FULL/EMPTY/SEAM classifier
/// (spec §2.2) in front of the Martinez boolean:
///   .none  — no finer/earlier coverage touches this tile: emit unclipped (the
///            overwhelmingly common case; zero geometry cost).
///   .full  — some one covering cell's coverage contains the WHOLE tile: the
///            cell contributes nothing here, skip it entirely.
///   .rings — a coverage EDGE crosses the tile (a true seam): the exact
///            projected+unioned subtrahend, Martinez runs only here.
pub const CoverClip = union(enum) { none, full, rings: []const []const mvt.Point };

// Does segment a-b intersect the axis-aligned lon/lat rect [w,s,e,n]?
// Conservative-fast: endpoint-in-rect, else standard slab rejection + a
// crossing test against each rect edge via orientation signs.
fn segTouchesRect(ax: f64, ay: f64, bx: f64, by: f64, w: f64, so: f64, e: f64, n: f64) bool {
    if (ax >= w and ax <= e and ay >= so and ay <= n) return true;
    if (bx >= w and bx <= e and by >= so and by <= n) return true;
    if (@max(ax, bx) < w or @min(ax, bx) > e or @max(ay, by) < so or @min(ay, by) > n) return false;
    // The segment's bbox overlaps the rect but no endpoint is inside: it crosses
    // iff the rect's corners are not all on one side of the segment line.
    const dx = bx - ax;
    const dy = by - ay;
    const s1 = dx * (so - ay) - dy * (w - ax);
    const s2 = dx * (so - ay) - dy * (e - ax);
    const s3 = dx * (n - ay) - dy * (e - ax);
    const s4 = dx * (n - ay) - dy * (w - ax);
    const any_pos = s1 > 0 or s2 > 0 or s3 > 0 or s4 > 0;
    const any_neg = s1 < 0 or s2 < 0 or s3 < 0 or s4 < 0;
    return any_pos and any_neg;
}

// Does any edge of `rings` touch the lon/lat rect?
fn ringsTouchRect(rings: []const []const s57.LonLat, w: f64, so: f64, e: f64, n: f64) bool {
    for (rings) |ring| {
        if (ring.len < 2) continue;
        var j = ring.len - 1;
        for (ring, 0..) |p, k| {
            const q = ring[j];
            j = k;
            if (segTouchesRect(p.lon(), p.lat(), q.lon(), q.lat(), w, so, e, n)) return true;
        }
    }
    return false;
}

/// The finer-scale coverage to subtract from cell `cscl_self`'s fills in tile
/// (z,x,y): the union of every strictly-finer cell's M_COVR (CATCOV=1), projected
/// into the tile's i32 space and box-clipped, as a clean ring set. This is the
/// coverage-clipped best-available composite's exact subtrahend
/// (specs/cross-band-composition-redesign.md) — it replaces the point-sampled
/// whole-tile suppress_whole with true geometry, so a coarse fill is cut exactly
/// where a finer cell owns the ground (no seam double-draw) and kept everywhere
/// else, including inside a finer no-data hole (no blank). null = nothing finer
/// covers this tile (the cell is finest here → draw everything). Allocated in `a`
/// (the per-tile scratch), so it lives exactly as long as the tile.
pub fn coverClipForCell(a: std.mem.Allocator, ctx: anytype, idxs: []const u32, reach_only: ?[]const bool, self_idx: u32, z: u8, x: u32, y: u32, box: tile.Box) CoverClip {
    // No-M_COVR / unknown-scale cells (cscl <= 0) follow the asymmetric rule
    // (spec §2.1/Q1): they render their own content but ARE clipped by finer
    // real coverage — at bandOf's default scale, the same one their band floor
    // uses — while never clipping others (the `cscl <= 0` skip below: a derived
    // bbox must not cut coarser cells across its empty corners).
    const raw_self = ctx.cscl(self_idx);
    const cscl_self: i32 = if (raw_self > 0) raw_self else 50_000;
    // Cheap FULL/EMPTY/SEAM classification in lon/lat BEFORE any projection or
    // boolean: most tiles are either fully inside one covering cell (drop the
    // whole cell) or touched by no covering edge (emit unclipped) — a rider
    // deep inside or far outside the finer coverage costs a few segment/rect
    // tests instead of a per-tile Martinez union.
    const tbll = tile.tileBoundsLonLat(z, x, y);
    // Pad by the tile buffer so the box-clipped operands the SEAM path builds
    // agree with the classification (BUFFER/EXTENT of the tile span per side).
    const pad_x = (tbll[2] - tbll[0]) * (@as(f64, @floatFromInt(tile.BUFFER)) / @as(f64, @floatFromInt(tile.EXTENT)));
    const pad_y = (tbll[3] - tbll[1]) * (@as(f64, @floatFromInt(tile.BUFFER)) / @as(f64, @floatFromInt(tile.EXTENT)));
    const w = tbll[0] - pad_x;
    const so = tbll[1] - pad_y;
    const e = tbll[2] + pad_x;
    const n = tbll[3] + pad_y;
    const cx = (tbll[0] + tbll[2]) * 0.5;
    const cy = (tbll[1] + tbll[3]) * 0.5;
    var any_seam = false;
    for (idxs, 0..) |idx, j| {
        if (reach_only) |ro| if (ro[j]) continue;
        if (idx == self_idx) continue;
        const cscl = ctx.cscl(idx);
        if (cscl <= 0 or cscl > cscl_self) continue;
        if (cscl == cscl_self and !ordersBefore(ctx, idx, self_idx)) continue;
        const b = ctx.bounds(idx);
        if (b[0] > e or b[2] < w or b[1] > n or b[3] < so) continue;
        for (ctx.coverage(idx)) |rings| {
            if (ringsTouchRect(rings, w, so, e, n)) {
                any_seam = true;
            } else if (s57.pointInRings(rings, cx, cy)) {
                // No edge in the (padded) tile and the centre is inside: the
                // whole tile is covered by this cell — nothing of self survives.
                return .full;
            }
        }
        if (any_seam) break;
    }
    if (!any_seam) return .none;

    var covers = std.ArrayList(geometry.boolean.Polygon).empty;
    for (idxs, 0..) |idx, j| {
        if (reach_only) |ro| if (ro[j]) continue;
        if (idx == self_idx) continue;
        const cscl = ctx.cscl(idx);
        if (cscl <= 0 or cscl > cscl_self) continue; // coarser never clips finer
        // Strictly finer coverage always clips. EQUAL-scale neighbours clip by a
        // deterministic total order — NEWER compilation first (DSID issue date,
        // refreshed by each applied update), cell name as the final tie — so two
        // adjacent same-band cells that both chart a seam object emit exactly one
        // copy AND the newer survey wins the double-owned strip (spec §2.1/Q4:
        // F(cell c) = union of M_COVR of all cells ordered strictly before c).
        if (cscl == cscl_self and !ordersBefore(ctx, idx, self_idx)) continue;
        for (ctx.coverage(idx)) |rings| {
            var poly = std.ArrayList([]const geometry.boolean.Pt).empty;
            for (rings) |ring| {
                if (ring.len < 3) continue;
                const proj = a.alloc(mvt.Point, ring.len) catch return .none;
                for (ring, 0..) |pt, k| proj[k] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
                const clipped = tile.clipPolygon(a, proj, box) catch continue;
                if (clipped.len < 3) continue;
                const bring = a.alloc(geometry.boolean.Pt, clipped.len) catch return .none;
                for (clipped, 0..) |cp, k| bring[k] = .{ .x = cp.x, .y = cp.y };
                poly.append(a, bring) catch return .none;
            }
            if (poly.items.len > 0) covers.append(a, poly.items) catch return .none;
        }
    }
    if (covers.items.len == 0) return .none;
    const uni = geometry.boolean.unionAll(a, covers.items) catch return .none;
    if (uni.len == 0) return .none;
    const out = a.alloc([]const mvt.Point, uni.len) catch return .none;
    for (uni, 0..) |r, i| {
        const mr = a.alloc(mvt.Point, r.len) catch return .none;
        for (r, 0..) |bp, k| mr[k] = .{ .x = @intCast(bp.x), .y = @intCast(bp.y) };
        out[i] = mr;
    }
    return .{ .rings = out };
}

/// Whether the finer coverage `cover_clip` covers the ENTIRE tile box — i.e. this
/// coarser cell owns none of it (box minus coverage is empty). Used only for the
/// overscale-hatch "wins somewhere" gate.
pub fn tileFullyCovered(a: std.mem.Allocator, cover_clip: []const []const mvt.Point, box: tile.Box) bool {
    const boxring = [_]geometry.boolean.Pt{
        .{ .x = box.min, .y = box.min }, .{ .x = box.max, .y = box.min },
        .{ .x = box.max, .y = box.max }, .{ .x = box.min, .y = box.max },
    };
    const subj = [_][]const geometry.boolean.Pt{&boxring};
    var clip = std.ArrayList([]const geometry.boolean.Pt).empty;
    for (cover_clip) |r| {
        const br = a.alloc(geometry.boolean.Pt, r.len) catch return false;
        for (r, 0..) |p, k| br[k] = .{ .x = p.x, .y = p.y };
        clip.append(a, br) catch return false;
    }
    const rem = geometry.boolean.compute(a, &subj, clip.items, .diff) catch return false;
    return rem.len == 0;
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
/// feed the tilejson scamin ladder (client filter-gate crossings). Allocated
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

/// The effScamin floor for a cell (spec §4): the display denominator of the
/// cell's band-floor zoom under the client's static gate constant
/// (assets.scaminGateK at the equator — the largest K over all latitudes, so
/// the clamp holds everywhere). A feature's emitted `scamin` is floored here so
/// an aggressive SCAMIN cannot blank a point between the cell's floor tier and
/// its own activation zoom — the finer cell owns that ground geometrically, so
/// nothing else can show there. Tiles below the floor don't exist, so lifting a
/// smaller scamin up to the floor denominator changes nothing below it.
pub fn effScaminFloor(cscl: i32) i64 {
    // cscl <= 0 (no M_COVR / unknown scale) uses bandOf's same 1:50k default —
    // such a cell is now clipped by finer coverage (asymmetric rule, Q1), so
    // the band-floor visibility clamp applies to it identically.
    const floor_z = bandZooms(bandOf(cscl)).min;
    // The coarsest band has no coarser copy to hand off from, so no blank
    // window can open — leave its SCAMINs raw (a z0 clamp would disable
    // decluttering at world view entirely).
    if (floor_z == 0) return 0;
    const k = assets.scaminGateK(0);
    return @intFromFloat(@ceil(k / @as(f64, @floatFromInt(@as(u64, 1) << @intCast(floor_z)))));
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

/// Overscale fill-up depth DEFAULT: how many zooms past its native max a
/// band's own cells keep baking (only where nothing finer already emitted).
/// Every extension zoom ~4x that band's tile count over its uncovered
/// footprint (measured: +2 turned a 5.6k-tile approach pass into 41k), so the
/// default is ONE crisp overscale zoom; TILE57_FILLUP_DZ=0..2 overrides per
/// bake (Baker.fillup_dz). 0 never blanks — the client camera stops at the
/// probed data depth and MapLibre stretches one level past it.
pub const FILLUP_DZ: u8 = 1;

/// Absolute fill-up ceiling: extension zooms never exceed this. The fill-up
/// serves the MID-ZOOM seam where a coarse chart is the finest coverage (the
/// blank bay at z12-15); letting fine bands extend too (harbor→z17-18,
/// berthing→z19-20) quadruples the tile count per extra zoom across every
/// harbor footprint for content nobody needs — a district pack ballooned from
/// ~800k to 13M+ planned tiles. A band's NATIVE window is never clamped by
/// this; past its data the camera stops at the probed depth instead.
pub const FILLUP_CEIL: u8 = 15;

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

/// Run func(user, i, scratch) for every i in [0, n) SERIALLY on the calling thread (a per-thread
/// scratch arena reset between items, exactly like parallelFor with one thread). Tile generation
/// uses this: the parallel unit is the CELL (chart.bakeCellsParallel runs one worker per cell), so
/// per-cell tile-gen stays single-threaded and W workers stay W threads — no nested thread pool.
pub fn serialFor(gpa: std.mem.Allocator, n: usize, user: *anyopaque, func: *const fn (*anyopaque, usize, std.mem.Allocator) void) void {
    if (n == 0) return;
    var pc = ParCtx{ .next = std.atomic.Value(usize).init(0), .n = n, .user = user, .func = func, .gpa = gpa };
    parWorker(&pc);
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
        const tbll = tile.tileBoundsLonLat(z, x, y); // [minlon, minlat, maxlon, maxlat]
        const box = tile.Box.default(tile.EXTENT, tile.BUFFER); // tile-space clip box (coverage projection)
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
                    .{ tbll[0], tbll[1] },
                    .{ tbll[2], tbll[1] },
                    .{ tbll[0], tbll[3] },
                    .{ tbll[2], tbll[3] },
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
        // The point-sampled cross-band quilting (finestCsclAt over centre+corners
        // → carryGate → suppress_whole/centre/smax) is GONE — the coverage-clipped
        // composite (coverClipForCell + subtractCoverage + coveredByFiner) does it
        // exactly per-feature. All that remains here is the overscale scale-boundary
        // scan: the finest compilation scale CONTRIBUTING to this tile.
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
        const refs = scratch.alloc(scene.CellRef, idxs.len) catch return;
        var nrefs: usize = 0;
        for (idxs, 0..) |idx, j| {
            const be = &c.backends[idx];
            // The exact best-available composite: subtract the finer cells' M_COVR
            // from this cell's fills/patterns, and (in scene.appendCellFeatures) drop
            // its points/strokes wherever a finer cell owns the ground. cover_clip is
            // the ONE cross-band mechanism — no carryGate / suppress_whole / smax.
            // The FULL/EMPTY/SEAM classifier keeps the common cases free: .full
            // (a covering cell owns the whole tile) skips the cell entirely,
            // .none emits it unclipped, and only true seam tiles run Martinez.
            const clip = coverClipForCell(scratch, BackendCov{ .backends = c.backends }, idxs, reach_only, idx, z, x, y, box);
            if (clip == .full) continue;
            const cover_clip: ?[]const []const mvt.Point = switch (clip) {
                .rings => |r| r,
                else => null,
            };
            // Overscale (S-52 §10.1.10.2): the X2 gate denominator. Hatch this cell's
            // OVERSC01 coverage only where it is the DISPLAYED data AT a scale boundary
            // — a strictly-finer cell rides the tile (gf_tile < cscl) AND this cell
            // still owns some of it (its fills aren't fully clipped away).
            const oscl: i64 = overscaleGateDenom(be.cscl);
            const wins_somewhere = cover_clip == null or !tileFullyCovered(scratch, cover_clip.?, box);
            refs[nrefs] = .{ .cell = &be.cell, .portrayal = be.portrayal, .portrayal_plain = be.portrayal_plain, .portrayal_simplified = be.portrayal_simplified, .geo = be.geo, .geo_world = be.geo_world, .feat_bbox = be.feat_bbox, .suppress_fills = false, .suppress_patterns = false, .cover_clip = cover_clip, .suppress_lines = false, .suppress_points = false, .oscl = oscl, .overscale_hatch = !reach_only[j] and !holefill[j] and be.cscl > 0 and gf_tile < be.cscl and wins_somewhere, .eff_scamin_floor = effScaminFloor(be.cscl), .light_range_m = be.light_range_m };
            nrefs += 1;
        }
        const mvt_bytes = scene.encodeTile(scratch, scratch, refs[0..nrefs], z, x, y, c.format, c.pick_attrs) catch return;
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
    // Coarse riders for the NEXT bakeBand call: backends[rider_start..] are
    // strictly-coarser cells that JOIN the pass's tiles wherever their bbox
    // overlaps — the composite clips them to the ground finer coverage leaves —
    // but never enumerate tiles of their own. Set by the driver before
    // bakeBand; consumed (reset to null) by it. null = no riders.
    rider_start: ?usize = null,
    // Overscale fill-up depth for this bake (see FILLUP_DZ; drivers may override
    // from TILE57_FILLUP_DZ).
    fillup_dz: u8 = FILLUP_DZ,
    count: usize = 0, // tiles handed to the sink (cumulative across bands)
    union_b: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 }, // w, s, e, n
    format: scene.TileFormat = .mvt, // output tile encoding (mvt default; mlt optional)
    pick_attrs: bool = true, // emit per-feature pick-report attrs (s57/cell); off = lean tiles
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
        // Capped overscale fill-up (spec §3, bounded): a band's OWN cells also
        // enumerate FILLUP_DZ zooms past the band's native max. Finest bakes
        // first + emitted-skip, so the extension lands only on coarse-only
        // ground — rendered overscaled (~X4 at +2, the client HUD warns) instead
        // of the single-source deep-zoom hole (blank water past a band's window
        // wherever nothing finer covers). Past the cap the server 404s absent
        // tiles and MapLibre stretches the deepest ancestor.
        const zext: u8 = @min(self.maxzoom, @max(zr.max, @min(zr.max +| self.fillup_dz, FILLUP_CEIL)));
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
        const rider_lo = @min(self.rider_start orelse spans.len, spans.len);
        for (spans[0..rider_lo], 0..) |sp, i| {
            const b = sp.bounds;
            var z = zlo;
            var zend = zext;
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
            } else if (zlo > zext) continue;
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
        // Coarse riders (spans[rider_lo..]): join every ALREADY-mapped tile their
        // bbox overlaps as extra contributors. The composite clips them to the
        // ground the finer coverage leaves (the finer-band bbox-edge tiles that
        // used to lack the coarser neighbour's content), and a rider that wins a
        // hole beyond X2 hatches OVERSC01 like any overscale-displayed cell.
        if (rider_lo < spans.len) {
            var rit = tilemap.iterator();
            while (rit.next()) |e| {
                const key = e.key_ptr.*;
                const tz: u8 = @intCast(key >> 48);
                const tx: u32 = @intCast((key >> 24) & 0xFFFFFF);
                const ty: u32 = @intCast(key & 0xFFFFFF);
                const tbll = tile.tileBoundsLonLat(tz, tx, ty);
                for (spans[rider_lo..], rider_lo..) |sp, i| {
                    const b = sp.bounds;
                    if (b[0] > tbll[2] or b[2] < tbll[0] or b[1] > tbll[3] or b[3] < tbll[1]) continue;
                    try e.value_ptr.append(self.gpa, @intCast(i));
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
        defer self.rider_start = null; // one-shot (see the field)
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
        var tg = TileGenCtx{ .keys = keys, .idx_lists = idx_lists, .results = results, .backends = backends, .gpa = self.gpa, .format = self.format, .pick_attrs = self.pick_attrs, .context = self.context, .progress = progress, .pctx = ctx, .base = self.count, .band_base = self.band_base, .band_total = self.band_total, .band_index = self.band_index, .band_count = self.band_count, .band_name = bname, .done = &done };
        serialFor(self.gpa, n, &tg, TileGenCtx.gen);

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
        var tg = TileGenCtx{ .keys = keys, .idx_lists = idx_lists, .results = results, .backends = backends, .gpa = self.gpa, .format = self.format, .pick_attrs = self.pick_attrs, .context = self.context, .progress = progress, .pctx = ctx, .base = self.count, .band_base = self.band_base, .band_total = self.band_total, .band_index = self.band_index, .band_count = self.band_count, .band_name = bname, .done = &done };
        serialFor(self.gpa, n, &tg, TileGenCtx.gen);

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

test "composite floor tile: the finer cell owns the ground (no carried smax copy)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Two cells at the same location near (0.35, 0.35): a coastal 1:200k with its
    // bulk gated SCAMIN 260000, and a general 1:1.2M with SCAMIN 800000, both
    // with the SAME blanket M_COVR. Under the coverage-clipped composite the
    // fine cell owns all the ground it covers at the shared z9 floor tile: its
    // own point emits untagged, and the coarse copy is geometrically clipped
    // (coveredByFiner) — never carried with an smax handoff tag.
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
    // Per-feature bbox of the single point — the composite's coveredByFiner test
    // keys on it (a real bake gets this from portrayCell).
    const pt_bbox = [_]?[4]f64{.{ 0.35, 0.35, 0.35, 0.35 }};

    var fine = Backend{ .cell = fine_cell, .portrayal = &streams, .bounds = bounds, .cscl = 200_000, .coverage = &cover, .scamins = &fine_scamins, .feat_bbox = &pt_bbox };
    const coarse = Backend{ .cell = coarse_cell, .portrayal = &streams, .bounds = bounds, .cscl = 1_200_000, .coverage = &cover, .scamins = &coarse_scamins, .feat_bbox = &pt_bbox };

    var sink = CollectSink{ .a = a, .tiles = std.AutoHashMap(u64, []u8).init(a) };
    var baker = Baker.init(gpa, 7, 10, .{ .ctx = &sink, .func = CollectSink.run });
    defer baker.deinit();

    // Coastal pass (deferred floor): only z10 tiles may be emitted, never z9.
    try baker.bakeBand(.coastal, (&fine)[0..1], 1, .defer_down, null, null, null);
    var it = sink.tiles.keyIterator();
    while (it.next()) |k| try std.testing.expectEqual(@as(u64, 10), k.* >> 48);
    try std.testing.expect(sink.tiles.count() > 0);

    // General pass (coarsest populated): own cells + the coastal carry. The z9
    // floor tile exists; only the FINE cell's point survives the composite.
    var both = [_]Backend{ coarse, fine };
    try baker.bakeBand(.general, &both, 1, .extend_min, null, null, null);
    const t9 = lonLatToTile(0.35, 0.35, 9);
    const bytes = sink.tiles.get(tileKey(9, t9[0], t9[1])) orelse return error.TestUnexpectedResult;
    const raw = try gzip.decompress(a, bytes);
    const layers = try mvt.decode(a, raw);
    var fine_pts: usize = 0;
    var coarse_pts: usize = 0;
    for (layers) |L| {
        // v2 schema: SCAMIN points fold into the merged `point_symbols` layer; the
        // scamin-prop filter below selects the SCAMIN-bearing ones.
        if (!std.mem.eql(u8, L.name, "point_symbols")) continue;
        for (L.features) |f| {
            const scamin = findIntProp(f.properties, "scamin") orelse continue;
            const smax = findIntProp(f.properties, "smax");
            if (scamin == @max(260_000, effScaminFloor(200_000))) {
                // The fine band's own point, its SCAMIN clamped to the coastal
                // floor denominator (effScamin, spec §4): it shows the moment
                // its tile exists, closing the band-floor blank window the
                // deleted carry-down used to paper over. Never smax-tagged.
                try std.testing.expectEqual(@as(?i64, null), smax);
                fine_pts += 1;
            } else if (scamin == 800_000) {
                coarse_pts += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fine_pts);
    // The coarse copy is GEOMETRICALLY clipped (the fine cell's M_COVR contains
    // its position — coveredByFiner), not carried with an smax tag: the
    // coverage-clipped composite replaced the scamin-aware carry-down.
    try std.testing.expectEqual(@as(usize, 0), coarse_pts);

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

test "ordersBefore: newer DSID date first, name breaks ties, dated beats undated" {
    const Ctx = struct {
        dates: []const []const u8,
        names: []const []const u8,
        pub fn date(self: @This(), i: u32) []const u8 {
            return self.dates[i];
        }
        pub fn name(self: @This(), i: u32) []const u8 {
            return self.names[i];
        }
    };
    const ctx = Ctx{
        .dates = &.{ "20240101", "20250601", "20250601", "" },
        .names = &.{ "US5AAAAA", "US5BBBBB", "US5CCCCC", "US5DDDDD" },
    };
    try std.testing.expect(ordersBefore(ctx, 1, 0)); // newer date wins
    try std.testing.expect(!ordersBefore(ctx, 0, 1));
    try std.testing.expect(ordersBefore(ctx, 1, 2)); // same date -> name asc
    try std.testing.expect(!ordersBefore(ctx, 2, 1));
    try std.testing.expect(ordersBefore(ctx, 0, 3)); // dated beats undated
}

test "coarse rider fills a finer pass's tile beyond the fine coverage" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A harbor cell whose M_COVR covers only lon < 0.4, and a coarser approach
    // cell charted at 0.45 — inside the harbor cell's BBOX (so the harbor pass
    // enumerates the tile) but outside its coverage. As a rider the approach
    // point must appear in the harbor pass's tile (the finer-band bbox-edge
    // hole); the harbor's own point emits as usual.
    const fine_feats = [_]s57.Feature{.{
        .rcnm = 0,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    }};
    const coarse_feats = [_]s57.Feature{.{
        .rcnm = 0,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    }};
    var fine_cell = try testCell(gpa, 0.3, 0.35, 20_000, &fine_feats);
    defer fine_cell.deinit();
    var coarse_cell = try testCell(gpa, 0.45, 0.35, 80_000, &coarse_feats);
    defer coarse_cell.deinit();

    const fine_ring = [_]s57.LonLat{
        s57.LonLat.init(-2, -2), s57.LonLat.init(0.4, -2),
        s57.LonLat.init(0.4, 3), s57.LonLat.init(-2, 3),
        s57.LonLat.init(-2, -2),
    };
    const fine_rings = [_][]const s57.LonLat{&fine_ring};
    const fine_cover = [_][]const []const s57.LonLat{&fine_rings};
    const ring = [_]s57.LonLat{
        s57.LonLat.init(-2, -2), s57.LonLat.init(3, -2),
        s57.LonLat.init(3, 3),   s57.LonLat.init(-2, 3),
        s57.LonLat.init(-2, -2),
    };
    const rings = [_][]const s57.LonLat{&ring};
    const coarse_cover = [_][]const []const s57.LonLat{&rings};
    const bounds = [4]f64{ 0.2, 0.2, 0.5, 0.5 };
    const streams = [_]?[]const u8{"DrawingPriority:7;PointInstruction:BOYLAT01"};
    const fine_bbox = [_]?[4]f64{.{ 0.3, 0.35, 0.3, 0.35 }};
    const coarse_bbox = [_]?[4]f64{.{ 0.45, 0.35, 0.45, 0.35 }};

    var backs = [_]Backend{
        .{ .cell = fine_cell, .portrayal = &streams, .bounds = bounds, .cscl = 20_000, .coverage = &fine_cover, .feat_bbox = &fine_bbox },
        .{ .cell = coarse_cell, .portrayal = &streams, .bounds = bounds, .cscl = 80_000, .coverage = &coarse_cover, .feat_bbox = &coarse_bbox },
    };

    var sink = CollectSink{ .a = a, .tiles = std.AutoHashMap(u64, []u8).init(a) };
    var baker = Baker.init(gpa, 13, 13, .{ .ctx = &sink, .func = CollectSink.run });
    defer baker.deinit();
    baker.rider_start = 1; // backs[1..] = the coarse rider
    try baker.bakeBand(.harbor, &backs, 1, .extend_min, null, null, null);

    // The rider's point tile (lon 0.45) is enumerated by the FINE cell's bbox and
    // must carry the coarse point; the fine point's own tile carries the fine one.
    var fine_pt: usize = 0;
    var coarse_pt: usize = 0;
    var it = sink.tiles.iterator();
    while (it.next()) |e| {
        const raw = try gzip.decompress(a, e.value_ptr.*);
        const layers = try mvt.decode(a, raw);
        for (layers) |L| {
            if (!std.mem.eql(u8, L.name, "point_symbols")) continue;
            for (L.features) |f| {
                _ = f;
                const z: u8 = @intCast(e.key_ptr.* >> 48);
                const x: u32 = @intCast((e.key_ptr.* >> 24) & 0xFFFFFF);
                _ = z;
                // lon 0.3 → x 4102, lon 0.45 → x 4106 at z13
                if (x <= 4104) fine_pt += 1 else coarse_pt += 1;
            }
        }
    }
    try std.testing.expect(fine_pt >= 1);
    // The bbox-edge hole: without riders this is 0 — the approach content was
    // simply absent from the harbor pass's tiles beyond the fine coverage.
    try std.testing.expect(coarse_pt >= 1);
}
