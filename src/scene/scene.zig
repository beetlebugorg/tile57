//! The tile engine: S-57 features plus their S-101 portrayal instructions become
//! a tile Surface, then an MVT or MLT vector tile for a given (z, x, y).
//!
//! A cell's features carry S-101 portrayal instructions from the Lua rules (see
//! the `portray` module). This module projects each feature's geometry to tile
//! space, resolves its layer and draw properties, and serializes the result. A
//! `classify()` fallback supplies a small object-class -> S-52 mapping for the
//! few paths that run without portrayal instructions.
//!
//! This module also hosts the banded multi-cell ENC_ROOT baker (`bake_enc`),
//! the engine's batch driver.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57");
const tile = @import("tiles").tile;
const mvt = @import("tiles").mvt;
const mlt = @import("tiles").mlt;
const render = @import("render");
const style = @import("style");
const geometry = @import("geometry"); // Martinez boolean; `geo` is a common param name here
const rs = render.surface;

/// The banded multi-cell ENC_ROOT -> PMTiles baker (folded in: it is the
/// batch driver of this engine). Re-exported for the CLI + lib root.
pub const bake_enc = @import("bake_enc.zig");
pub const coverage = @import("coverage"); // per-cell coverage sidecar (in PMTiles metadata)
const symins = @import("symins.zig"); // SYMINS02 native fallback (NEWOBJ producer draw ops)

// Light-sector reach (scene/lightreach.zig), re-exported so chart + bake_enc keep
// reaching it through the scene module.
const lightreach = @import("lightreach.zig");
pub const LightReach = lightreach.LightReach;
pub const collectLightReach = lightreach.collectLightReach;
pub const lightReachTiles = lightreach.lightReachTiles;
pub const LIGHT_AUG_REACH_TILES = lightreach.LIGHT_AUG_REACH_TILES;

// Complex-linestyle tessellation + registry (scene/linestyle.zig). Exposed so
// chart + bundle register and look up styles through `scene.linestyle`.
pub const linestyle = @import("linestyle.zig");

// Baked-tile replay (scene/replay.zig): a decoded tile -> Surface draw calls.
const replay = @import("replay.zig");
pub const replayTile = replay.replayTile;

/// Output tile encoding: classic Mapbox Vector Tile, or MapLibre Tile.
pub const TileFormat = enum { mvt, mlt };
const instructions = @import("s101").instructions;
const catalogue = @import("s101").catalogue;
const adapter = @import("s101").adapter;

// S-52 symbol scale the Go baker emits for every point symbol / sounding. The
// style's icon-size = scale / ATLAS_PPU (0.08), so this renders symbols at
// ~0.354 — matching the reference. The live path previously used 0.08 (icon
// size 1.0), i.e. ~2.8x too large.
const SYMBOL_SCALE: f64 = @import("render").sndfrm.SYMBOL_SCALE;

// Metres → feet. Soundings are stored + portrayed in metres (S-52/S-101 SNDFRM04 is
// metres-only); this app additionally bakes a feet glyph variant (sym_s_ft/sym_g_ft)
// so the generated style can show soundings in feet when the mariner picks that unit —
// a recreational-chartplotter convenience, not ECDIS behaviour. The feet value runs
// through the same SNDFRM04 glyph composition as metres, so it keeps one decimal place
// for shallow soundings (the depth-contour feet label, mariner.contourLabelField,
// rounds to whole feet — contour valdco values are whole metres).
const M_TO_FT: f64 = @import("render").sndfrm.M_TO_FT;

// S-57 attribute code for SCAMIN (the minimum display scale 1:N, S-57 Appendix A
// attr 133 / S-52 §8.4). Features carrying it are routed to a dedicated *_scamin
// MVT layer so the style can drop them below their 1:N scale; the value travels on
// the feature as the `scamin` property so the style derives the per-feature minzoom.
const ATTR_SCAMIN: u16 = 133;

// Area representative point (where an area's label/symbol is placed) and the
// polygon-geometry helpers live in s57.zig so the portrayal adapter shares them.

const Kind = enum { area, line, skip };
const Class = struct { kind: Kind, name: []const u8, color: []const u8, dash: []const u8 = "solid" };

/// Minimal S-57 object-class -> layer/color mapping (placeholder for S-101).
fn classify(objl: u16) Class {
    return switch (objl) {
        42 => .{ .kind = .area, .name = "DEPARE", .color = "DEPVS" }, // depth area
        46 => .{ .kind = .area, .name = "DRGARE", .color = "DEPVS" }, // dredged area
        71 => .{ .kind = .area, .name = "LNDARE", .color = "LANDA" }, // land area
        119 => .{ .kind = .area, .name = "BUAARE", .color = "CHBRN" }, // built-up area
        30 => .{ .kind = .line, .name = "COALNE", .color = "CSTLN" }, // coastline
        122 => .{ .kind = .line, .name = "SLCONS", .color = "CSTLN" }, // shoreline construction
        43 => .{ .kind = .line, .name = "DEPCNT", .color = "DEPCN", .dash = "solid" }, // depth contour (74 is LNDMRK)
        53 => .{ .kind = .line, .name = "DYKCON", .color = "CSTLN" },
        else => .{ .kind = .skip, .name = "", .color = "" },
    };
}

/// S-52 quaposSolidClass (s101build.go:299): man-made structures drawn with a definite
/// (solid) line regardless of QUAPOS. The approximate-position dashing is for natural
/// features whose charted position is uncertain (depth contours, coastline, rivers) —
/// not engineered structures whose edges often inherit a shared coastline's low-accuracy
/// QUAPOS. Keyed by acronym, like the oracle's map.
fn quaposSolidClass(objl: u16) bool {
    const acr = catalogue.acronymByObjl(objl) orelse return false;
    for ([_][]const u8{ "BRIDGE", "ROADWY", "RAILWY", "CAUSWY", "DAMCON", "GATCON" }) |name| {
        if (std.mem.eql(u8, acr, name)) return true;
    }
    return false;
}

/// True if the S-57 comma-separated list value `csv` contains any of `targets`.
/// (Mirrors adapter.hasListVal; S-57 list attributes are comma-joined.)
fn listHasAny(csv: []const u8, targets: []const i64) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |p| {
        const n = std.fmt.parseInt(i64, std.mem.trim(u8, p, " "), 10) catch continue;
        for (targets) |t| if (n == t) return true;
    }
    return false;
}

// SNDFRM04 glyph composition + the S-52 symbol scale live in the render module
// (render.sndfrm) so the pixel path composes the SAME glyph lists this engine
// bakes into sym_s/sym_g. Aliased here; all call sites unchanged.
const sndfrmSyms = @import("render").sndfrm.syms;

/// SNDFRM04 quality flags for the whole feature: swept (TECSOU∈{4,18}) → B1 ring;
/// low-accuracy (QUASOU∈{3,4,8,9}, no-bottom, or STATUS∈{18}) → C2/C3 ring.
fn soundingQualityFlags(f: s57.Feature) struct { swept: bool, low_acc: bool } {
    const quasou = f.attr(s57.ATTR_QUASOU) orelse "";
    // QUASOU=5 ("no bottom found at the depth shown"): S-65 §2.2.3.3 re-routes such a
    // sounding to the S-101 DepthNoBottomFound feature. SOUNDG bypasses S-101 portrayal
    // here, but DepthNoBottomFound's portrayal is exactly the depth digits + the
    // SNDFRM04 low-accuracy ring with NO NavHazard alert — and this soundings path emits
    // no AlertReference for any sounding. So the re-route is realized by drawing the
    // low-accuracy ring, recognized explicitly for QUASOU=5 (rather than only folded
    // into the generic low-accuracy set) so the no-bottom mark survives changes to it.
    const no_bottom = listHasAny(quasou, &.{5});
    return .{
        .swept = listHasAny(f.attr(s57.ATTR_TECSOU) orelse "", &.{ 4, 18 }),
        .low_acc = no_bottom or listHasAny(quasou, &.{ 3, 4, 8, 9 }) or
            listHasAny(f.attr(s57.ATTR_STATUS) orelse "", &.{18}),
    };
}

/// Append the SNDFRM04 sounding-glyph properties for one depth (metres): the metres
/// safe/general glyph lists (sym_s/sym_g), a FEET variant (sym_s_ft/sym_g_ft) the
/// style swaps in when the mariner selects feet, and the raw metres `depth` the
/// style's safety-depth split compares against. Returns false (nothing appended) when
/// the depth composes to no glyphs. The safety split stays in metres (`depth`); only
/// the displayed digits convert. The metres value follows SNDFRM04 (whole >= 31 m); the
/// feet value is a recreational display shown as WHOLE feet (`whole_feet`), TRUNCATED
/// down so it stays shallow-erring. A 4.5 m obstruction reads "14" (ft, 14.76 floored);
/// a 10 m one reads "32" (ft, 32.8 floored).
fn appendSoundingProps(a: Allocator, props: *std.ArrayList(mvt.Prop), depth_m: f64, swept: bool, low_acc: bool) !bool {
    const sym_s = try sndfrmSyms(a, "SOUNDS", depth_m, swept, low_acc, false);
    if (sym_s.len == 0) return false;
    const sym_g = try sndfrmSyms(a, "SOUNDG", depth_m, swept, low_acc, false);
    const ft = depth_m * M_TO_FT;
    const sym_s_ft = try sndfrmSyms(a, "SOUNDS", ft, swept, low_acc, true);
    const sym_g_ft = try sndfrmSyms(a, "SOUNDG", ft, swept, low_acc, true);
    try props.append(a, .{ .key = "sym_s", .value = .{ .string = sym_s } });
    try props.append(a, .{ .key = "sym_g", .value = .{ .string = sym_g } });
    try props.append(a, .{ .key = "sym_s_ft", .value = .{ .string = sym_s_ft } });
    try props.append(a, .{ .key = "sym_g_ft", .value = .{ .string = sym_g_ft } });
    try props.append(a, .{ .key = "depth", .value = .{ .double = depth_m } });
    return true;
}

/// True for a SNDFRM04 sounding digit-glyph symbol name (SOUNDS* bold/shallow or
/// SOUNDG* faint/deep). Mirrors the oracle's isSoundingName (bake.go:2628).
fn isSoundingName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "SOUNDS") or std.mem.startsWith(u8, name, "SOUNDG");
}

/// Emit a SOUNDG feature's multipoint soundings into the `soundings` layer, one
/// point per sounding, with the SNDFRM glyph variants (see appendSoundingProps) so
/// the style renders the depth digits and the mariner safety-depth + unit switches.
fn emitSoundings(a: Allocator, cell: s57.Cell, f: s57.Feature, fmeta: rs.FeatureMeta, z: u8, x: u32, y: u32, tb: [4]f64, surf: rs.Surface) !void {
    const snds = cell.soundingsFor(a, f) catch return;
    const q = soundingQualityFlags(f);
    // One feature bracket for the whole SOUNDG multipoint; the meta (draw priority /
    // display category / band / SCAMIN / class) rides every sounding so they honour
    // the client's category + SCAMIN gating — oracle routeSoundingGroup (bake.go:894).
    try surf.beginFeature(&fmeta);
    for (snds) |s| {
        if (s.lon() < tb[0] or s.lon() > tb[2] or s.lat() < tb[1] or s.lat() > tb[3]) continue;
        const pt = tile.project(s.lon(), s.lat(), z, x, y, tile.EXTENT);
        try surf.drawSounding(s.depth, q.swept, q.low_acc, pt);
    }
    try surf.endFeature();
}

fn overlaps(b0: [4]f64, b1: [4]f64) bool {
    return b0[0] <= b1[2] and b0[2] >= b1[0] and b0[1] <= b1[3] and b0[3] >= b1[1];
}

// Clip + per-tile simplify (Go baker quantizeRing): Douglas-Peucker then drop
// collinear/duplicate vertices so dense coastlines don't blow MapLibre's
// 65535-vertex-per-fill-segment cap. quantizeRingExact (no DP) is the fallback for
// a ring DP would collapse below 3 points, so simplification never deletes a whole
// still-renderable polygon. Returns the simplified ring, or empty if <3 vertices.
fn clipSimplifyPoly(a: Allocator, proj: []const mvt.Point, box: tile.Box) ![]const mvt.Point {
    const clipped = try tile.clipPolygon(a, proj, box);
    if (clipped.len < 3) return clipped[0..0];
    var ring = try tile.simplifyRing(a, clipped);
    if (ring.len < 3) ring = try tile.dedupCollinear(a, clipped); // DP over-collapsed
    return if (ring.len >= 3) ring else clipped[0..0];
}

// Coverage-clipped best-available composite:
// subtract the finer-scale coverage `clip` (already projected + box-clipped into this
// tile's i32 space, a clean union) from a coarser cell's box-clipped area rings, so a
// feature is emitted by exactly one cell — the finest whose M_COVR covers it. Replaces
// the old point-sampled whole-tile suppress_fills: a fully-covered tile clips to
// nothing (= suppression), a partial seam tile keeps only the coarse remnant (no
// double-draw), and an interior finer no-data hole keeps the coarse fill (no blank).
// Exact integer geometry via the Martinez boolean; `orientAreaRings` re-derives winding.
fn subtractCoverage(a: Allocator, rings: []const []const mvt.Point, clip: []const []const mvt.Point) []const []const mvt.Point {
    if (clip.len == 0 or rings.len == 0) return rings;
    const subj = mvtToGeo(a, rings) catch return rings;
    const clp = mvtToGeo(a, clip) catch return rings;
    const diff = geometry.boolean.compute(a, subj, clp, .diff) catch return rings;
    return geoToMvt(a, diff) catch return rings;
}

fn mvtToGeo(a: Allocator, rings: []const []const mvt.Point) ![]const []const geometry.boolean.Pt {
    const out = try a.alloc([]const geometry.boolean.Pt, rings.len);
    for (rings, 0..) |r, i| {
        const br = try a.alloc(geometry.boolean.Pt, r.len);
        for (r, 0..) |p, k| br[k] = .{ .x = p.x, .y = p.y };
        out[i] = br;
    }
    return out;
}

fn geoToMvt(a: Allocator, polys: []const []const geometry.boolean.Pt) ![]const []const mvt.Point {
    const out = try a.alloc([]const mvt.Point, polys.len);
    for (polys, 0..) |r, i| {
        const mr = try a.alloc(mvt.Point, r.len);
        // Coords are within the tile box (both operands box-clipped) → fit i32.
        for (r, 0..) |p, k| mr[k] = .{ .x = @intCast(p.x), .y = @intCast(p.y) };
        out[i] = mr;
    }
    return out;
}

// Line half of the coverage-clipped composite (spec §2.3 LINES): cut away the
// stretches of the box-clipped stroke runs that lie INSIDE the finer cells'
// coverage — plane.clipLineOutsidePolys splits each segment at its coverage-edge
// crossings and keeps the sub-runs whose midpoint is outside (the finer cell owns
// the covered stretch and the seam stroke). Replaces the whole-feature
// bbox-centre drop, which either kept a long coarse contour ENTIRELY (doubled
// inside finer coverage — the "extra contour lines") or dropped it entirely (a
// missing stroke outside). Fail-open on OOM: the un-clipped runs (a transient
// coarse dupe beats a missing stroke).
fn clipRunsOutsideCover(a: Allocator, runs: []const []const mvt.Point, cover: []const []const mvt.Point) []const []const mvt.Point {
    if (cover.len == 0 or runs.len == 0) return runs;
    const cov = mvtToGeo(a, cover) catch return runs;
    var out = std.ArrayList([]const mvt.Point).empty;
    for (runs) |run| {
        if (run.len < 2) continue;
        const line = a.alloc(geometry.boolean.Pt, run.len) catch return runs;
        for (run, 0..) |p, k| line[k] = .{ .x = p.x, .y = p.y };
        const kept = geometry.plane.clipLineOutsidePolys(a, line, cov) catch return runs;
        for (kept) |kr| {
            if (kr.len < 2) continue;
            const mr = a.alloc(mvt.Point, kr.len) catch return runs;
            for (kr, 0..) |p, k| mr[k] = .{ .x = @intCast(p.x), .y = @intCast(p.y) };
            out.append(a, mr) catch return runs;
        }
    }
    return out.items;
}

// The same coverage line clip for GEO-space stroke parts (the complex-linestyle
// tessellator works in lon/lat): project each part to integer tile space, cut the
// covered stretches, and map the kept runs back with tile.tileToLonLat. Dash
// phase restarts at a cut — identical to any part boundary today, and the finer
// cell draws its own stroke past the seam.
fn clipGeoPartsOutsideCover(a: Allocator, parts: []const []s57.LonLat, cover: []const []const mvt.Point, z: u8, x: u32, y: u32) []const []s57.LonLat {
    if (cover.len == 0 or parts.len == 0) return parts;
    var out = std.ArrayList([]s57.LonLat).empty;
    for (parts) |part| {
        if (part.len < 2) continue;
        const proj = a.alloc(mvt.Point, part.len) catch return parts;
        for (part, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const runs = [_][]const mvt.Point{proj};
        for (clipRunsOutsideCover(a, &runs, cover)) |kr| {
            if (kr.len < 2) continue;
            const gp = a.alloc(s57.LonLat, kr.len) catch return parts;
            for (kr, 0..) |p, i| {
                const ll = tile.tileToLonLat(@floatFromInt(p.x), @floatFromInt(p.y), z, x, y, tile.EXTENT);
                gp[i] = s57.LonLat.init(ll[0], ll[1]);
            }
            out.append(a, gp) catch return parts;
        }
    }
    return out.items;
}

// Even-odd point-in-rings in tile i32 space (exact i128 arithmetic) — the point
// half of the coverage-clipped composite: a coarser cell's point/line at a
// location a finer cell's M_COVR contains is dropped (the finer cell owns it).
fn pointInMvtRings(rings: []const []const mvt.Point, px: i64, py: i64) bool {
    var inside = false;
    for (rings) |ring| {
        if (ring.len < 3) continue;
        var j = ring.len - 1;
        for (ring, 0..) |pi, i| {
            const pj = ring[j];
            j = i;
            if ((@as(i64, pi.y) > py) != (@as(i64, pj.y) > py)) {
                const dy: i128 = @as(i128, pj.y) - pi.y;
                const lhs: i128 = (@as(i128, px) - pi.x) * dy;
                const rhs: i128 = (@as(i128, py) - pi.y) * (@as(i128, pj.x) - pi.x);
                if (dy > 0) {
                    if (lhs < rhs) inside = !inside;
                } else {
                    if (lhs > rhs) inside = !inside;
                }
            }
        }
    }
    return inside;
}

/// True when (lon,lat) falls inside this cell's finer-coverage clip — the finer
/// cell owns that ground, so a coarser point/line there is dropped (best-available).
fn coveredByFiner(cover_clip: []const []const mvt.Point, lon: f64, lat: f64, z: u8, x: u32, y: u32) bool {
    const p = tile.project(lon, lat, z, x, y, tile.EXTENT);
    return pointInMvtRings(cover_clip, p.x, p.y);
}

// Clip a line + simplify each kept run (drop runs that collapse below 2 vertices).

fn geomBounds(g: []const s57.LonLat) [4]f64 {
    var b = [4]f64{ 1e9, 1e9, -1e9, -1e9 };
    for (g) |p| {
        b[0] = @min(b[0], p.lon());
        b[1] = @min(b[1], p.lat());
        b[2] = @max(b[2], p.lon());
        b[3] = @max(b[3], p.lat());
    }
    return b;
}

/// Per-cell generation options: the CellRef band / coverage-suppression / pick
/// flags, threaded through the engine path beside the Surface.
pub const CellOpts = struct {
    /// NOAA navigational band of the cell being appended (0=berthing/finest …
    /// 5=overview/coarsest). Emitted as the `band` property so the style's
    /// fill-sort-key draws finer-band area fills over coarser ones at band overlaps
    /// (the live multi-cell path overlays all bands into one tile).
    band: u8 = 0,
    /// Best-band coverage suppression (live multi-cell path): this cell is a COARSER
    /// band overzoomed past its native range where a finer band's M_COVR coverage is
    /// present, so its AREA fills (suppress_fills) and/or patterns (suppress_patterns)
    /// are dropped — the finer cell carries the real data. Fills are suppressed only
    /// where a finer band covers the WHOLE tile (no seam gap; the finer fill occludes
    /// via the band sort-key); patterns, which draw above all fills, are suppressed by
    /// the tile centre so they can't lap over finer land.
    suppress_fills: bool = false,
    suppress_patterns: bool = false,
    /// Coverage-clipped best-available composite: the finer-scale coverage to
    /// subtract from THIS (coarser) cell's area fills + patterns, already projected
    /// and box-clipped into the tile's i32 space as a clean union of rings. null =
    /// nothing finer covers here (this cell is finest — draw everything). This is
    /// the exact geometric replacement for the point-sampled suppress_fills; see
    /// subtractCoverage.
    cover_clip: ?[]const []const mvt.Point = null,
    /// Best-band suppression for the remaining geometry of an overzoomed coarser cell:
    ///   suppress_lines  — drop boundary/line STROKES where a finer band covers the tile
    ///     centre. Lines double-draw beside the finer copy (no opaque fill hides them),
    ///     so this matches the Go line rule (coverageScaleAt at the tile centre).
    ///   suppress_points — drop point symbols + text where a finer band covers the WHOLE
    ///     tile. Conservative per-tile approximation of Go's per-point position test:
    ///     a partly-covered seam tile keeps the coarse points/labels (the finer cell,
    ///     drawn on top, wins where it has data); no labels lost over a coverage gap.
    suppress_lines: bool = false,
    suppress_points: bool = false,
    /// The overscale gate denominator = cscl / OVERSCALE_FACTOR (X2 per S-52
    /// PresLib §10.1.10.2: "grossly overscale ... by X2 or more"). A real SCAMIN-
    /// ladder crossing so the client flip is exact and never fires before 1x;
    /// 0 = unknown. Tagged as the `oscl` tile property on area fills + patterns,
    /// and emitted as the AP(OVERSC01) overscale hatch's gate (hatch shows while
    /// the display denominator is FINER/smaller than oscl). See emitOverscaleHatch.
    oscl: i64 = 0,
    /// Scale-boundary overscale (S-52 §10.1.10.2): emit this
    /// cell's AP(OVERSC01) coverage hatch into the tile. Set only when BOTH (a) a
    /// strictly-finer-CSCL cell also contributes to the SAME tile — a scale
    /// boundary exists (else whole-view overscale, the HUD "overscale ×n" readout's
    /// job, §10.1.10.1) — AND (b) this cell WINS the pure quilt somewhere in the
    /// tile (its fills are not suppressed everywhere): the hatch marks only the
    /// DISPLAYED smaller-scale data at the boundary ("must only be shown on the
    /// area compiled from the smaller scale ENC"), never a coarse cell occluded
    /// by finer coverage.
    overscale_hatch: bool = false,
    /// The effScamin floor (spec §4, bake_enc.effScaminFloor): every emitted
    /// feature's `scamin` is raised to at least this display denominator (the
    /// cell's band-floor zoom), so an aggressive SCAMIN cannot blank a feature
    /// in the window where this cell already owns the ground geometrically.
    /// 0 = no clamp. Features without SCAMIN stay ungated.
    eff_scamin_floor: i64 = 0,
    /// The display denominator beyond which this cell's SCAMIN-LESS SOUNDINGS stop
    /// showing (soundingScamin of the cell's compilation scale; 0 = no imputation).
    /// SCAMIN is optional in S-57 and producers routinely omit it on soundings, which
    /// leaves a sounding with no minimum display scale at all: every sounding a
    /// harbour cell holds then draws at every zoom the cell reaches, including the
    /// zooms where the chart is stretched far past the scale it was compiled for and
    /// the numbers are a carpet no one can read. Scale IS the density control in
    /// S-52 — soundings are drawn as symbols precisely so they stay legible — so a
    /// sounding the producer left ungated inherits the one scale limit its cell can
    /// justify: its own compilation scale. Only spot soundings (SOUNDG); a wreck,
    /// rock or obstruction is a DANGER and is never scale-gated away.
    sounding_scamin: i64 = 0,
    /// Emit the per-feature pick-report attributes (the `s57` blob + `cell` name) for
    /// the S-52 §10.8 cursor pick + dev inspector. Defaults ON (host wants a working
    /// pick report in the local-first deployment); a lean bake can turn it off via the
    /// C ABI to drop the bulky `s57` payload. See encodeS57Attrs.
    pick_attrs: bool = true,
    /// Max ground-distance sector-leg length (metres) among this cell's lights
    /// (LightReach.range_m) — widens the LIGHTS feature-cull margin to the honest
    /// per-zoom reach (lightReachTiles) so a directional light's full-nominal-range
    /// leg isn't culled on the tiles it crosses. 0 = display-mm figures only.
    light_range_m: f64 = 0,
    /// Isolated single-feature render (the `explore --kitty` thumbnail): portray
    /// ONLY the feature at this index, skipping every other feature in the cell.
    /// null = the normal whole-cell pass. See CellRef.only_fi.
    only_fi: ?usize = null,
};

/// MVT/MLT surface: owns the 11 tile layer lists and implements the rs.Surface
/// interface. The engine calls Surface methods (fillArea/strokeLine/…); this
/// surface builds the mvt.Feature props in the exact order the pre-seam code
/// used, so bakes are byte-identical before and after the split.
///
/// The only draw path that does NOT come through the Surface interface is the
/// legacy classify() mode (features with NO portrayal at all): its prop schema
/// ({class, color_token, band}) predates the S-101 engine and is a tile-only
/// serialization detail, so appendCellFeatures writes those lists directly.
pub const TileSurface = struct {
    a: Allocator,
    format: TileFormat,
    areas: std.ArrayList(mvt.Feature) = .empty,
    area_patterns: std.ArrayList(mvt.Feature) = .empty,
    lines: std.ArrayList(mvt.Feature) = .empty,
    points: std.ArrayList(mvt.Feature) = .empty,
    texts: std.ArrayList(mvt.Feature) = .empty,
    // SCAMIN buckets: a feature carrying SCAMIN (s57 attr 133) routes here instead
    // of the base list, and carries a `scamin` property so the style gates its
    // display below the feature's 1:N scale (see ATTR_SCAMIN / style/maplibre.zig).
    areas_scamin: std.ArrayList(mvt.Feature) = .empty,
    area_patterns_scamin: std.ArrayList(mvt.Feature) = .empty,
    lines_scamin: std.ArrayList(mvt.Feature) = .empty,
    points_scamin: std.ArrayList(mvt.Feature) = .empty,
    texts_scamin: std.ArrayList(mvt.Feature) = .empty,
    // The `soundings` layer (one list, no SCAMIN bucket — gated by the `scamin`
    // property in the style). SOUNDG multipoints and wreck/obstruction/rock depth
    // glyphs (coalesced from the portrayal via drawSounding) both land here.
    soundings: std.ArrayList(mvt.Feature) = .empty,
    /// Current feature meta, set by beginFeature; the draw methods read it.
    cur: Meta = .{ .display_priority = 0 },

    const mvt_vtable = rs.Surface.VTable{
        .beginScene = beginScene,
        .beginFeature = beginFeature,
        .fillArea = fillArea,
        .fillPattern = fillPattern,
        .strokeLine = strokeLine,
        .drawSymbol = drawSymbol,
        .drawSounding = drawSounding,
        .drawText = drawText,
        .endFeature = endFeature,
        .endScene = endScene,
        // Bake path: store complex runs un-tessellated (no size_scale set — bake is
        // native; replay re-walks the period display-scaled).
        .store_complex_run = storeComplexRun,
    };

    pub fn init(a: Allocator, format: TileFormat) TileSurface {
        return .{ .a = a, .format = format };
    }

    pub fn asSurface(self: *TileSurface) rs.Surface {
        return .{ .ptr = self, .vtable = &mvt_vtable };
    }

    fn sp(ctx: *anyopaque) *TileSurface {
        return @ptrCast(@alignCast(ctx));
    }

    fn areasL(s: *TileSurface) *std.ArrayList(mvt.Feature) {
        return if (s.cur.scamin != null) &s.areas_scamin else &s.areas;
    }
    fn apatL(s: *TileSurface) *std.ArrayList(mvt.Feature) {
        return if (s.cur.scamin != null) &s.area_patterns_scamin else &s.area_patterns;
    }
    fn linesL(s: *TileSurface) *std.ArrayList(mvt.Feature) {
        return if (s.cur.scamin != null) &s.lines_scamin else &s.lines;
    }
    fn pointsL(s: *TileSurface) *std.ArrayList(mvt.Feature) {
        return if (s.cur.scamin != null) &s.points_scamin else &s.points;
    }
    fn textsL(s: *TileSurface) *std.ArrayList(mvt.Feature) {
        return if (s.cur.scamin != null) &s.texts_scamin else &s.texts;
    }

    fn beginScene(_: *anyopaque, _: u8) anyerror!void {}

    fn beginFeature(ctx: *anyopaque, meta: *const rs.FeatureMeta) anyerror!void {
        const s = sp(ctx);
        s.cur = .{
            .display_priority = meta.display_priority,
            .display_plane = meta.display_plane,
            .display_category = meta.display_category,
            .vg = meta.vg,
            .scamin = meta.scamin,
            .oscl = meta.oscl,
            .class = meta.class,
            .s57 = meta.s57_json,
            .cell = meta.cell_name,
            .band = meta.band,
            .masked = meta.masked,
            .date_start = meta.date_start,
            .date_end = meta.date_end,
            .bnd = meta.bnd,
            .pts = meta.pts,
        };
    }

    fn fillArea(ctx: *anyopaque, token: rs.ColorToken, rings: []const []const rs.TilePoint, depth: ?rs.DepthRange) anyerror!void {
        const s = sp(ctx);
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(s.a, .{ .key = "color_token", .value = .{ .string = token } });
        if (depth) |d| {
            try props.append(s.a, .{ .key = "drval1", .value = .{ .float = d.d1 } });
            try props.append(s.a, .{ .key = "drval2", .value = .{ .float = d.d2 } });
        }
        // The cell's quantized compilation scale: the style's overscale machinery
        // splits area fills into a below-the-hatch (overscaled) and an above-the-
        // hatch (at-scale) pass on this tag — so a finer cell's opaque fill
        // occludes a coarser cell's OVERSC01 hatch.
        if (s.cur.oscl > 0) try props.append(s.a, .{ .key = "oscl", .value = .{ .int = s.cur.oscl } });
        try appendMeta(s.a, &props, s.cur);
        try s.areasL().append(s.a, .{ .geom_type = .polygon, .parts = rings, .properties = props.items });
    }

    fn fillPattern(ctx: *anyopaque, name: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        const s = sp(ctx);
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(s.a, .{ .key = "pattern_name", .value = .{ .string = name } });
        // The cell's quantized compilation scale — on the OVERSC01 hatch this is
        // the style's show gate (denom < oscl); other patterns just carry the tag.
        if (s.cur.oscl > 0) try props.append(s.a, .{ .key = "oscl", .value = .{ .int = s.cur.oscl } });
        try appendMeta(s.a, &props, s.cur);
        try s.apatL().append(s.a, .{ .geom_type = .polygon, .parts = rings, .properties = props.items });
    }

    fn strokeLine(ctx: *anyopaque, token: rs.ColorToken, width_px: f64, dash: rs.Dash, lines: []const []const rs.TilePoint, valdco: ?f64) anyerror!void {
        const s = sp(ctx);
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(s.a, .{ .key = "color_token", .value = .{ .string = token } });
        try props.append(s.a, .{ .key = "width_px", .value = .{ .double = width_px } });
        const dash_str: []const u8 = switch (dash) {
            .solid => "solid",
            .dashed => "dashed",
        };
        try props.append(s.a, .{ .key = "dash", .value = .{ .string = dash_str } });
        if (valdco) |v| try props.append(s.a, .{ .key = "valdco", .value = .{ .double = v } });
        try appendMeta(s.a, &props, s.cur);
        try s.linesL().append(s.a, .{ .geom_type = .linestring, .parts = lines, .properties = props.items });
    }

    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: rs.SymbolPlacement, danger_depth: ?f64) anyerror!void {
        const s = sp(ctx);
        var props = std.ArrayList(mvt.Prop).empty;
        if (danger_depth) |depth| {
            // OBSTRN07/WRECKS05 picked DANGER01 (shallow) vs 02 (deep) against the
            // BAKE-TIME safety depth; normalize to DANGER01 + danger_depth/sym_deep
            // so the style swaps live against the mariner's safety contour.
            try props.append(s.a, .{ .key = "symbol_name", .value = .{ .string = "DANGER01" } });
            try props.append(s.a, .{ .key = "danger_depth", .value = .{ .double = depth } });
            try props.append(s.a, .{ .key = "sym_deep", .value = .{ .string = "DANGER02" } });
        } else {
            try props.append(s.a, .{ .key = "symbol_name", .value = .{ .string = name } });
        }
        try props.append(s.a, .{ .key = "rotation_deg", .value = .{ .double = rot_deg } });
        switch (placement) {
            // Anchor-placed: rot_north only when the rule asked for chart-relative
            // rotation, and it precedes scale (the historical tile prop order).
            .point => if (rot_north) try props.append(s.a, .{ .key = "rot_north", .value = .{ .int = 1 } }),
            .line => {},
        }
        try props.append(s.a, .{ .key = "scale", .value = .{ .double = scale } });
        // Linestyle-embedded: tangent rotation turns with the chart, so rot_north is
        // inherent — and historically serialized AFTER scale. Keep that order.
        if (placement == .line) try props.append(s.a, .{ .key = "rot_north", .value = .{ .int = 1 } });
        try appendMeta(s.a, &props, s.cur);
        const parts = try s.a.alloc([]const mvt.Point, 1);
        const single = try s.a.alloc(mvt.Point, 1);
        single[0] = at;
        parts[0] = single;
        try s.pointsL().append(s.a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
    }

    /// BAKE: store one clipped complex-linestyle run UN-TESSELLATED, tagged with its style id
    /// and its phase (arc0), so replay can re-walk the period at the DISPLAY's size_scale.
    ///
    /// Without this the baker falls through to drawComplexRun and freezes the period at
    /// size_scale = 1. The bricks then scale with the display at render time while their
    /// SPACING does not, so on a HiDPI display (size_scale ~3) the symbols swell into each
    /// other and the linestyle reads as a smashed-up sawtooth. The whole point of storing the
    /// run is that spacing and brick size scale TOGETHER, and the baked tile stays
    /// display-independent — replay.zig has always known how to read this; only the baker
    /// never wrote it.
    fn storeComplexRun(ctx: *anyopaque, ls_id: []const u8, color: rs.ColorToken, width_px: f64, arc0: f64, run: []const rs.TilePoint) anyerror!void {
        const s = sp(ctx);
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(s.a, .{ .key = "ls_style", .value = .{ .string = ls_id } });
        try props.append(s.a, .{ .key = "ls_arc0", .value = .{ .double = arc0 } });
        try props.append(s.a, .{ .key = "color_token", .value = .{ .string = color } });
        try props.append(s.a, .{ .key = "width_px", .value = .{ .double = width_px } });
        try appendMeta(s.a, &props, s.cur);
        const parts = try s.a.alloc([]const mvt.Point, 1);
        parts[0] = run;
        try s.linesL().append(s.a, .{ .geom_type = .linestring, .parts = parts, .properties = props.items });
    }

    fn drawSounding(ctx: *anyopaque, depth_m: f64, swept: bool, low_acc: bool, at: rs.TilePoint) anyerror!void {
        const s = sp(ctx);
        var props = std.ArrayList(mvt.Prop).empty;
        if (!try appendSoundingProps(s.a, &props, depth_m, swept, low_acc)) return;
        try props.append(s.a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
        try appendMeta(s.a, &props, s.cur);
        const parts = try s.a.alloc([]const mvt.Point, 1);
        const single = try s.a.alloc(mvt.Point, 1);
        single[0] = at;
        parts[0] = single;
        try s.soundings.append(s.a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
    }

    fn drawText(ctx: *anyopaque, text: []const u8, text_style: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const s = sp(ctx);
        var props = std.ArrayList(mvt.Prop).empty;
        try appendTextProps(s.a, &props, text, text_style); // text already shortened by engine
        try appendMeta(s.a, &props, s.cur);
        const parts = try s.a.alloc([]const mvt.Point, 1);
        const single = try s.a.alloc(mvt.Point, 1);
        single[0] = at;
        parts[0] = single;
        try s.textsL().append(s.a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
    }

    fn endFeature(_: *anyopaque) anyerror!void {}

    fn endScene(ctx: *anyopaque, out: Allocator) anyerror![]u8 {
        const s = sp(ctx);
        // v2 tile schema (tile57/2): fold each SCAMIN twin into its BASE source-layer,
        // so the archive carries 6 vector layers (areas, area_patterns, lines,
        // point_symbols, soundings, text) instead of 11. SCAMIN band-independence is
        // now per-feature — a folded feature keeps its `scamin` property and the style
        // gates it via coalesce(scamin,1e12). Only the emitted layer NAME merges; all
        // the upstream SCAMIN routing / dedup / scale-window machinery is unchanged.
        try s.areas.appendSlice(s.a, s.areas_scamin.items);
        try s.area_patterns.appendSlice(s.a, s.area_patterns_scamin.items);
        try s.lines.appendSlice(s.a, s.lines_scamin.items);
        try s.points.appendSlice(s.a, s.points_scamin.items);
        try s.texts.appendSlice(s.a, s.texts_scamin.items);
        var layers = std.ArrayList(mvt.Layer).empty;
        if (s.areas.items.len > 0) try layers.append(s.a, .{ .name = "areas", .features = s.areas.items });
        if (s.area_patterns.items.len > 0) try layers.append(s.a, .{ .name = "area_patterns", .features = s.area_patterns.items });
        if (s.lines.items.len > 0) try layers.append(s.a, .{ .name = "lines", .features = s.lines.items });
        if (s.points.items.len > 0) try layers.append(s.a, .{ .name = "point_symbols", .features = s.points.items });
        if (s.soundings.items.len > 0) try layers.append(s.a, .{ .name = "soundings", .features = s.soundings.items });
        if (s.texts.items.len > 0) try layers.append(s.a, .{ .name = "text", .features = s.texts.items });
        if (layers.items.len == 0) return out.alloc(u8, 0);
        return switch (s.format) {
            .mvt => mvt.encode(out, .{ .layers = layers.items }),
            .mlt => mlt.encode(out, .{ .layers = layers.items }),
        };
    }
};

/// SCAMIN (1:N) denominator the feature carries, or null when absent/invalid.
pub fn featureScamin(f: s57.Feature) ?i64 {
    const v = f.attr(ATTR_SCAMIN) orelse return null;
    const n = std.fmt.parseInt(i64, std.mem.trim(u8, v, " "), 10) catch return null;
    return if (n > 0) n else null;
}

/// The feature's SCAMIN clamped to the cell's effScamin floor (spec §4): a
/// feature can never be SCAMIN-hidden above its own cell's band-floor zoom —
/// where the composite has already assigned it the ground, hiding it would
/// open a hole nothing else may fill. No SCAMIN stays no SCAMIN.
fn effScamin(f: s57.Feature, opts: CellOpts) ?i64 {
    // SOUNDINGS are exempt from the band-floor clamp, and inherit a limit when the
    // producer set none. Both for the same reason: SCAMIN is how a chart controls
    // sounding DENSITY, and the clamp — which exists so an aggressive SCAMIN cannot
    // blank a feature in the window where this cell already owns the ground — has
    // nothing to protect here. A hidden sounding leaves no hole: no coarser cell is
    // waiting to supply it, and the depth it reports is still carried by the depth
    // areas and contours under it. Clamping it up instead OVERRIDES the producer:
    // NOAA marks a harbour cell's soundings "not below 1:60,000" and the floor
    // lifts that to the cell's band floor (1:273,000 for an approach cell), so
    // every sounding the cell holds draws across its whole zoom window — the
    // unreadable carpet at the coarse end. Honour what the producer asked for.
    if (f.objl == OBJL_SOUNDG) return featureScamin(f) orelse
        (if (opts.sounding_scamin > 0) opts.sounding_scamin else null);
    const sc = featureScamin(f) orelse return null;
    return @max(sc, opts.eff_scamin_floor);
}

/// S-57 object class: SOUNDG, the spot-sounding multipoint. (A wreck, rock or
/// obstruction is a DANGER, not a sounding — it keeps the clamp, and is never
/// scale-gated away by the rule above.)
const OBJL_SOUNDG: u16 = 129;

/// How far past its compilation scale a cell's soundings stay readable when the
/// producer set no SCAMIN at all. The band windows already sit ~1.7x underzoomed
/// at a band's floor zoom, so 2x keeps such a sounding across the zoom window its
/// own cell owns and drops it only beyond that — where a coarser cell, with its
/// own sparser soundings, is the intended source.
pub const SOUNDING_UNDERZOOM: i64 = 2;

/// The display denominator beyond which a cell's SCAMIN-LESS soundings stop
/// showing: its compilation scale, allowed SOUNDING_UNDERZOOM x. 0 (unknown
/// scale) imputes nothing — there is no scale to justify a limit with.
pub fn soundingScamin(cscl: i32) i64 {
    if (cscl <= 0) return 0;
    return @as(i64, cscl) * SOUNDING_UNDERZOOM;
}

/// S-52 §10.6.1.1: does the feature carry ancillary information warranting the
/// SY(INFORM01) "additional information available" marker? True when it has a
/// non-blank INFORM/NINFOM (textual note) or TXTDSC/NTXTDS/PICREP (referenced
/// text/picture file). Mirrors Go hasAdditionalInfo (TrimSpace != "").
fn hasAdditionalInfo(f: s57.Feature) bool {
    for (f.attrs) |at| {
        const acr = catalogue.attrAcronym(at.code) orelse continue;
        const is_info = std.mem.eql(u8, acr, "INFORM") or std.mem.eql(u8, acr, "NINFOM") or
            std.mem.eql(u8, acr, "TXTDSC") or std.mem.eql(u8, acr, "NTXTDS") or
            std.mem.eql(u8, acr, "PICREP");
        if (is_info and std.mem.trim(u8, at.value, " \t\n\r\x0b\x0c").len > 0) return true;
    }
    return false;
}

test "hasAdditionalInfo: INFORM/TXTDSC trigger; blank/absent/other don't" {
    // Resolve the S-57 ATTL code for an acronym via the catalogue (no reverse map),
    // so the test stays correct regardless of the numeric code assignment.
    const codeFor = struct {
        fn f(acr: []const u8) u16 {
            var code: u16 = 1;
            while (code < 2000) : (code += 1) {
                if (catalogue.attrAcronym(code)) |a| if (std.mem.eql(u8, a, acr)) return code;
            }
            return 0;
        }
    }.f;
    const inform = codeFor("INFORM");
    const txtdsc = codeFor("TXTDSC");
    try std.testing.expect(inform != 0 and txtdsc != 0);

    // No info attribute → no marker.
    try std.testing.expect(!hasAdditionalInfo(.{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 75, .attrs = &.{} }));
    // A non-info attribute (DRVAL1) → no marker.
    try std.testing.expect(!hasAdditionalInfo(.{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 42, .attrs = &.{.{ .code = s57.ATTR_DRVAL1, .value = "9.1" }} }));
    // INFORM with text → marker.
    try std.testing.expect(hasAdditionalInfo(.{ .rcnm = 100, .rcid = 3, .prim = 1, .objl = 75, .attrs = &.{.{ .code = inform, .value = "see chart note" }} }));
    // TXTDSC (referenced file) → marker.
    try std.testing.expect(hasAdditionalInfo(.{ .rcnm = 100, .rcid = 4, .prim = 3, .objl = 42, .attrs = &.{.{ .code = txtdsc, .value = "DESC01.TXT" }} }));
    // INFORM present but blank (whitespace only) → no marker (matches Go TrimSpace != "").
    try std.testing.expect(!hasAdditionalInfo(.{ .rcnm = 100, .rcid = 5, .prim = 1, .objl = 75, .attrs = &.{.{ .code = inform, .value = "  \t " }} }));
}

/// The vector layers this engine emits, in emit order — the tile57/2 source-layer
/// set. Defined in tiles.mvt (shared with the compositor) and re-exported here;
/// keep the layer appends in endScene in sync with it.
pub const VECTOR_LAYERS = mvt.VECTOR_LAYERS;

/// PMTiles archive metadata JSON: the static vector_layers list MapLibre reads from
/// the TileJSON, plus a "scamin" array of the distinct SCAMIN denominators present
/// (ascending) so the client builds one native-minzoom bucket layer per value at
/// load instead of probing tiles. Mirrors the Go pmtiles.Builder.metadata
/// (vector_layers + scamin splice). `scamin` empty -> omit the field. `coverage_json`,
/// when non-null, is a per-cell coverage object (see `coverage.encodeJson`) spliced
/// under a "coverage" key — a single-cell composite bake carries its own M_COVR there.
/// `light_reach_json` (see `coverage.encodeLightReachJson`), when non-null, is the
/// cell's sector-figure reach summary spliced under a "light_reach" key so the
/// compositor can widen its tile addressing without re-portraying the cell.
/// Caller owns the returned bytes (allocated in `a`).
pub fn metadataJson(a: Allocator, scamin: []const u32, coverage_json: ?[]const u8, light_reach_json: ?[]const u8) ![]const u8 {
    var b = std.ArrayList(u8).empty;
    try b.appendSlice(a, "{\"name\":\"chartplotter\",\"format\":\"pbf\",\"vector_layers\":[");
    for (VECTOR_LAYERS, 0..) |name, i| {
        if (i > 0) try b.append(a, ',');
        try b.appendSlice(a, "{\"id\":\"");
        try b.appendSlice(a, name);
        try b.appendSlice(a, "\",\"fields\":{}}");
    }
    try b.append(a, ']');
    if (scamin.len > 0) {
        try b.appendSlice(a, ",\"scamin\":[");
        for (scamin, 0..) |v, i| {
            if (i > 0) try b.append(a, ',');
            var nbuf: [16]u8 = undefined;
            try b.appendSlice(a, std.fmt.bufPrint(&nbuf, "{d}", .{v}) catch unreachable);
        }
        try b.append(a, ']');
    }
    if (coverage_json) |cj| {
        try b.appendSlice(a, ",\"coverage\":");
        try b.appendSlice(a, cj);
    }
    if (light_reach_json) |lj| {
        try b.appendSlice(a, ",\"light_reach\":");
        try b.appendSlice(a, lj);
    }
    try b.append(a, '}');
    return b.toOwnedSlice(a);
}

/// Feature-level metadata shared by every primitive a feature emits, so the
/// client's S-52 mariner filters can select on it.
const Meta = struct {
    display_priority: i64,
    display_plane: i64 = 0, // S-101 DisplayPlane (0 UnderRadar default, 1 OverRadar)
    display_category: i64 = 1, // display-category rank (0 base, 1 standard, 2 other)
    vg: i64 = 0, // raw S-101 viewing-group number of the feature's primary draw (0 = none)
    scamin: ?i64 = null,
    // The source cell's compilation scale quantized up the scamin ladder (0 =
    // unknown/omitted). Emitted on area fills + patterns only (fillArea /
    // fillPattern), NOT via appendMeta — points/lines/text don't need it.
    oscl: i64 = 0,
    class: []const u8 = "", // S-57 object-class acronym (M_QUAL, LIGHTS, …)
    // Cursor-pick report (S-52 §10.8) + dev feature inspector: the feature's full
    // S-57 attribute set as compact acronym->value JSON. "" = omitted (no reportable
    // attribute, or pick attributes disabled). See encodeS57Attrs / pickS57.
    s57: []const u8 = "",
    // Source ENC cell name (the pick report's "source cell" badge). "" = omitted
    // (unknown cell name, or pick attributes disabled). From s57.Cell.name.
    cell: []const u8 = "",
    band: u8 = 0, // NOAA band rank (0 finest … 5 coarsest)
    masked: bool = false, // S-52 §8.6.2 suppressed boundary piece (meta-bounds view only)
    date_start: []const u8 = "",
    date_end: []const u8 = "",
    // S-52 boundary symbolization (§8.6.1) and point-symbol style (§11.2.2) tags
    // the client's boundaryFilter / pointStyleFilter key off: 2 = style-independent
    // (always shown — omitted from the tile, the client coalesces a missing tag to
    // 2), 0/1 = the plain/symbolized boundary or paper/simplified point pass.
    bnd: i64 = 2,
    pts: i64 = 2,
};

/// Append the shared metadata tags: S-52 draw priority + display category + band
/// (always), the object-class acronym (data-quality/meta/light filters), the SCAMIN
/// 1:N denominator (when gated), the boundary/point-style variant tags (only when
/// style-dependent), and the date-dependent validity tags (when dated).
// Append the OpText tile properties for one text label, matching the oracle's
// DrawText property set (bake.go): text, color_token, font_size_px (the FontSize
// modifier, or 12 by default), halign/valign (the resolved TextAlign values the
// style's TEXT_ANCHOR keys on), and the §14.5 text group. Halo + offset are
// separate findings (still on the OpText halo / LocalOffset rows).
// SBDARE nature-of-surface labels arrive from the (pristine, vendored) S-101
// rule as INT1 abbreviations ("S", "M", "Cy" …, space-joined for multiple
// surfaces). A screen has no chart-margin legend to decode them against, so
// expand each known token to its full name ("sand mud"); unknown tokens pass
// through untouched. SBDARE-only — "S" means something else elsewhere.
fn expandSeabedText(a: Allocator, class: []const u8, text: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, class, "SBDARE")) return text;
    const names = [_][2][]const u8{
        .{ "M", "mud" },     .{ "Cy", "clay" },    .{ "Si", "silt" },
        .{ "S", "sand" },    .{ "St", "stone" },   .{ "G", "gravel" },
        .{ "P", "pebbles" }, .{ "Cb", "cobbles" }, .{ "R", "rock" },
        .{ "Co", "coral" },  .{ "Sh", "shells" },
    };
    var out = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, text, ' ');
    var changed = false;
    var first = true;
    while (it.next()) |tok| {
        if (!first) try out.append(a, ' ');
        first = false;
        var expanded: ?[]const u8 = null;
        for (names) |n| {
            if (std.mem.eql(u8, tok, n[0])) {
                expanded = n[1];
                break;
            }
        }
        try out.appendSlice(a, expanded orelse tok);
        if (expanded != null) changed = true;
    }
    if (!changed) {
        out.deinit(a);
        return text;
    }
    return out.toOwnedSlice(a);
}

/// Strip the "by "/"bn " aid-name tag the S-101 buoy/beacon rules add (EncodeString
/// 'by %s' / 'bn %s') and show the FULL name. Previously this reduced the name to its
/// trailing chart designation ("Chesapeake Channel Lighted Buoy 78A" -> "78A"); that
/// shortening was removed so aid names read in full. Untagged text (depth labels, light
/// elevations, place names) passes through unchanged. Returns a borrowed slice.
fn stripNameTag(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, "by ") or std.mem.startsWith(u8, text, "bn "))
        return std.mem.trim(u8, text[3..], " ");
    return text;
}

/// Build the TextStyle for one parsed label, applying the label-tier resolver
/// (render.labeltier): a geographic-name class (city, bay, point…) is sized and
/// weighted by its S-57 class + SCAMIN + category, so a major place reads bolder
/// than a creek. Non-name labels keep the portrayal rule's own font-size / weight
/// / slant. The rule's halign/valign/offset/group always carry through.
fn textStyleFor(t: instructions.Text, f: s57.Feature, fmeta: rs.FeatureMeta) rs.TextStyle {
    var size = t.font_size;
    var weight: render.font.Weight = switch (t.weight) {
        .regular => .regular,
        .bold => .bold,
    };
    var slant: render.font.Slant = switch (t.slant) {
        .upright => .upright,
        .italic => .italic,
    };
    const cat: ?i64 = if (render.labeltier.categoryCode(fmeta.class)) |cc|
        (if (f.attrFloat(cc)) |x| @as(i64, @intFromFloat(x)) else null)
    else
        null;
    if (render.labeltier.resolve(fmeta.class, fmeta.scamin, cat)) |tier| {
        size = tier.size_px;
        weight = tier.weight;
        slant = tier.slant;
    }
    return .{
        .color = t.color,
        .font_size = size,
        .weight = weight,
        .slant = slant,
        .halign = t.halign,
        .valign = t.valign,
        .offset_x = t.offset_x,
        .offset_y = t.offset_y,
        .group = t.group,
    };
}

/// Serialize a text label's props in the tile schema order. `text` arrives already
/// shortened/resolved by the engine. A minimal label (empty halign — see
/// rs.TextStyle) carries only text/color/size, as the native fallbacks always did.
fn appendTextProps(a: Allocator, props: *std.ArrayList(mvt.Prop), text: []const u8, text_style: *const rs.TextStyle) !void {
    // Resolved body size: the FontSize modifier px, or 12 (oracle default). Drives
    // both the emitted font_size_px and the halo gate below.
    const font_px: f64 = if (text_style.font_size > 0) text_style.font_size else 12;
    try props.append(a, .{ .key = "text", .value = .{ .string = text } });
    try props.append(a, .{ .key = "color_token", .value = .{ .string = text_style.color } });
    try props.append(a, .{ .key = "font_size_px", .value = .{ .double = font_px } });
    // Label-tier weight/slant (render.labeltier): emit only the non-default face so
    // the common regular/upright label keeps its byte-identical prop set. A reader
    // that omits the key renders regular/upright.
    if (text_style.weight == .bold) try props.append(a, .{ .key = "font_weight", .value = .{ .string = "bold" } });
    if (text_style.slant == .italic) try props.append(a, .{ .key = "font_slant", .value = .{ .string = "italic" } });
    if (text_style.halign.len == 0) return; // minimal label: no alignment/halo/group spec
    try props.append(a, .{ .key = "halign", .value = .{ .string = text_style.halign } });
    try props.append(a, .{ .key = "valign", .value = .{ .string = text_style.valign } });
    // S-101 LocalOffset -> label-offset key in text-body units (3.51 mm = one text
    // body height = 1 em): the style's text-offset match keys on "ux,uy" to shift a
    // name clear of its symbol (PortrayFeatureName emits 0,-3.51 = one body up).
    // Only emit when non-zero (most labels sit on their pivot). Sign is S-52 +x
    // right / +y down, which matches MapLibre's text-offset.
    {
        const TEXT_BODY_MM = 3.51;
        const ux: i64 = @intFromFloat(@round(text_style.offset_x / TEXT_BODY_MM));
        const uy: i64 = @intFromFloat(@round(text_style.offset_y / TEXT_BODY_MM));
        if (ux != 0 or uy != 0)
            try props.append(a, .{ .key = "loff", .value = .{ .string = try std.fmt.allocPrint(a, "{d},{d}", .{ ux, uy }) } });
    }
    // §10 text halo: the oracle attaches a CHWHT, 1px halo to text >= 10 px
    // (s101emit.go:130-133) and emits it as halo_color_token / halo_width tile
    // properties (bake.go:1147-1148); smaller text gets no halo ("" / 0). Our served
    // style still renders text solid (no halo) by deliberate S-52 choice (maplibre.zig
    // textPaint passes halo_width 0) — these are tile-parity properties for a client
    // that wants the legibility halo.
    const haloed = font_px >= 10;
    try props.append(a, .{ .key = "halo_color_token", .value = .{ .string = if (haloed) "CHWHT" else "" } });
    try props.append(a, .{ .key = "halo_width", .value = .{ .double = if (haloed) 1 else 0 } });
    try props.append(a, .{ .key = "tgrp", .value = .{ .int = text_style.group } });
}

/// JSON-escape `s` (surrounding quotes included) into `buf`: escapes ", \, and the
/// C0 control chars so an S-57 text value (OBJNAM, INFORM, …) is a valid JSON string.
fn appendJsonString(a: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => if (c < 0x20) {
            var hb: [6]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&hb, "\\u{x:0>4}", .{c}) catch unreachable);
        } else try buf.append(a, c),
    };
    try buf.append(a, '"');
}

/// Compact JSON of the feature's full S-57 attribute set (acronym -> value) for the
/// S-52 §10.8 cursor-pick report + the dev feature inspector — host-canonical-backend
/// "Still needed" #4. Mirrors the Go baker's encodeS57Attrs: skip an attr with no
/// catalogue acronym or a blank value; "" when the feature has no reportable attribute
/// (the caller omits the `s57` prop). Values are the raw trimmed S-57 strings — the
/// Zig parser keeps ATTF/NATF values as text, so unlike the Go path there's no typed
/// re-format; the client (web/s57-catalogue.json) maps acronyms->labels and displays
/// the values verbatim. Caller owns the bytes (allocated in `a`).
pub fn encodeS57Attrs(a: Allocator, f: s57.Feature) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    var n: usize = 0;
    for (f.attrs) |at| {
        const acr = catalogue.attrAcronym(at.code) orelse continue;
        const v = std.mem.trim(u8, at.value, " \t\r\n");
        if (v.len == 0) continue;
        try buf.append(a, if (n == 0) '{' else ',');
        try appendJsonString(a, &buf, acr);
        try buf.append(a, ':');
        try appendJsonString(a, &buf, v);
        n += 1;
    }
    if (n == 0) return "";
    try buf.append(a, '}');
    return buf.items;
}

test "encodeS57Attrs: acronym->value JSON; skips blank + unknown; escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // DRVAL1 present, DRVAL2 blank (skipped), an out-of-range code with no acronym
    // (skipped) -> only the one reportable attribute.
    {
        const attrs = [_]s57.Attr{
            .{ .code = s57.ATTR_DRVAL1, .value = "9.1" },
            .{ .code = s57.ATTR_DRVAL2, .value = "  " },
            .{ .code = 65535, .value = "x" },
        };
        const f = s57.Feature{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .attrs = &attrs };
        try std.testing.expectEqualStrings("{\"DRVAL1\":\"9.1\"}", try encodeS57Attrs(a, f));
    }
    // No reportable attribute -> "" (the caller omits the s57 prop).
    {
        const f = s57.Feature{ .rcnm = 100, .rcid = 2, .prim = 1, .objl = 42, .attrs = &.{} };
        try std.testing.expectEqualStrings("", try encodeS57Attrs(a, f));
    }
    // Quote/backslash in a value are JSON-escaped.
    {
        const attrs = [_]s57.Attr{.{ .code = s57.ATTR_DRVAL1, .value = "a\"b\\c" }};
        const f = s57.Feature{ .rcnm = 100, .rcid = 3, .prim = 3, .objl = 42, .attrs = &attrs };
        try std.testing.expectEqualStrings("{\"DRVAL1\":\"a\\\"b\\\\c\"}", try encodeS57Attrs(a, f));
    }
}

fn appendMeta(a: Allocator, props: *std.ArrayList(mvt.Prop), m: Meta) !void {
    try props.append(a, .{ .key = "display_priority", .value = .{ .int = m.display_priority } });
    // S-101 DisplayPlane: emitted only for OverRadar (plane=1); the style's sort-key
    // coalesces an absent plane to 0 (UnderRadar), so the common case stays untagged.
    if (m.display_plane != 0) try props.append(a, .{ .key = "display_plane", .value = .{ .int = m.display_plane } });
    try props.append(a, .{ .key = "display_category", .value = .{ .int = m.display_category } });
    // Raw viewing group (§14.5): emitted only when the feature has a banded draw VG,
    // so undated/unbanded features keep their tile footprint unchanged.
    if (m.vg != 0) try props.append(a, .{ .key = "vg", .value = .{ .int = m.vg } });
    try props.append(a, .{ .key = "band", .value = .{ .int = m.band } });
    if (m.class.len > 0) try props.append(a, .{ .key = "class", .value = .{ .string = m.class } });
    if (m.s57.len > 0) try props.append(a, .{ .key = "s57", .value = .{ .string = m.s57 } });
    if (m.cell.len > 0) try props.append(a, .{ .key = "cell", .value = .{ .string = m.cell } });
    if (m.scamin) |sc| try props.append(a, .{ .key = "scamin", .value = .{ .int = sc } });
    // bnd/pts are emitted only for the style-variant passes (0/1); the common case
    // (2) is left off so the client coalesces to 2 (always shown) — keeping every
    // unvarying feature's tile footprint unchanged.
    if (m.bnd != 2) try props.append(a, .{ .key = "bnd", .value = .{ .int = m.bnd } });
    if (m.pts != 2) try props.append(a, .{ .key = "pts", .value = .{ .int = m.pts } });
    // §8.6.2-suppressed boundary piece — present only on the meta-bounds extras,
    // so every normally-drawn feature's tile footprint is unchanged.
    if (m.masked) try props.append(a, .{ .key = "masked", .value = .{ .int = 1 } });
    // Date-dependent display (S-52 §10.4.1.1): recurring iff a "--" month-day prefix,
    // stripped so the client compares MMDD (recurring) / YYYYMMDD (fixed).
    if (m.date_start.len > 0 or m.date_end.len > 0) {
        const recurring: i64 = if (std.mem.startsWith(u8, m.date_start, "--") or
            std.mem.startsWith(u8, m.date_end, "--")) 1 else 0;
        try props.append(a, .{ .key = "date_recurring", .value = .{ .int = recurring } });
        const ds = std.mem.trimStart(u8, m.date_start, "-");
        const de = std.mem.trimStart(u8, m.date_end, "-");
        if (ds.len > 0) try props.append(a, .{ .key = "date_start", .value = .{ .string = ds } });
        if (de.len > 0) try props.append(a, .{ .key = "date_end", .value = .{ .string = de } });
    }
}

/// Per-feature cached line/area geometry for a cell (indexed by feature index;
/// null = a point/sounding feature, or one that failed to assemble). The baker
/// builds this once per cell (buildGeoCache) so each of the cell's many tiles
/// projects + clips instead of re-resolving edges/nodes; the live single-tile
/// path leaves it null and assembles on demand.
pub const GeoParts = []const ?[][]s57.LonLat;

/// Assemble every line/area feature's geometry once into `a`. Used by the baker.
pub fn buildGeoCache(a: Allocator, cell: *const s57.Cell) !GeoParts {
    const parts = try a.alloc(?[][]s57.LonLat, cell.features.len);
    for (cell.features, 0..) |f, i| {
        parts[i] = if (f.prim == 2 or f.prim == 3) (cell.geometryParts(a, f) catch null) else null;
    }
    return parts;
}

/// Per-feature lon/lat bbox [w,s,e,n] (point/line/area), computed once per cell so
/// the baker can spatially cull features per tile. Only the (small) bboxes are
/// retained in `a`; line/area geometry is taken from the geo cache when present,
/// else assembled into a transient arena reused per feature (so coarse bands that
/// skip the geo cache don't hold assembled geometry just for bboxes).
pub fn buildFeatBBox(a: Allocator, cell: *const s57.Cell, geo: ?GeoParts) ![]?[4]f64 {
    const out = try a.alloc(?[4]f64, cell.features.len);
    var tmp = std.heap.ArenaAllocator.init(a);
    defer tmp.deinit();
    for (cell.features, 0..) |f, i| {
        out[i] = null;
        // SOUNDG (129) is a point feature (prim==1) whose single referenced node is a
        // MULTIPOINT carrying many SG3D soundings spread across the cell. Its cull bbox
        // must span ALL those soundings — pointGeometry returns just one representative
        // node, which would shrink the bbox to a single tile and make the per-tile cull
        // drop the whole feature (and all its soundings) on every other tile.
        if (f.objl == 129) {
            const snds = cell.soundingsFor(tmp.allocator(), f) catch &.{};
            if (snds.len > 0) {
                var w: f64 = 1e18;
                var s: f64 = 1e18;
                var e: f64 = -1e18;
                var n: f64 = -1e18;
                for (snds) |sd| {
                    w = @min(w, sd.lon());
                    e = @max(e, sd.lon());
                    s = @min(s, sd.lat());
                    n = @max(n, sd.lat());
                }
                out[i] = .{ w, s, e, n };
            }
            _ = tmp.reset(.retain_capacity);
            continue;
        }
        if (f.prim == 1) {
            if (cell.pointGeometry(f)) |p| out[i] = .{ p.lon(), p.lat(), p.lon(), p.lat() };
            continue;
        }
        if (f.prim != 2 and f.prim != 3) continue;
        const parts = featureParts(tmp.allocator(), cell.*, geo, i, f) catch continue;
        var w: f64 = 1e18;
        var s: f64 = 1e18;
        var e: f64 = -1e18;
        var n: f64 = -1e18;
        var any = false;
        for (parts) |part| for (part) |pt| {
            w = @min(w, pt.lon());
            e = @max(e, pt.lon());
            s = @min(s, pt.lat());
            n = @max(n, pt.lat());
            any = true;
        };
        if (any) out[i] = .{ w, s, e, n };
        _ = tmp.reset(.retain_capacity); // drop this feature's transient assembly
    }
    return out;
}

/// Per-feature area representative (label) point cache, indexed by feature index —
/// stored on the cell (cell.label_cache) and reused by the per-tile emit. The pole-
/// of-inaccessibility (polylabel) search depends only on the feature's full geometry
/// (tile-invariant), so computing it ONCE per cell removes the per-tile recompute that
/// dominates the bake. Only an AREA that actually anchors something at its representative
/// point consults labelPoint, so cache exactly those; a null slot (a plain fill area, an
/// unlabelled one, or `streams==null`) makes labelPoint fall back to a live search, so the
/// cached point is byte-identical either way. `streams` is the per-feature base instruction
/// stream (parallel to cell.features); null = cache nothing.
pub fn buildLabelCache(a: Allocator, cell: *const s57.Cell, geo: ?GeoParts, streams: ?[]const ?[]const u8) ![]?s57.LonLat {
    const out = try a.alloc(?s57.LonLat, cell.features.len);
    @memset(out, null);
    const ss = streams orelse return out;
    var tmp = std.heap.ArenaAllocator.init(a);
    defer tmp.deinit();
    for (cell.features, 0..) |f, i| {
        // Polylabel (areaRepresentativePoint) is AREA-only — lines anchor at their mid-vertex.
        if (f.prim != 3) continue;
        const stream: ?[]const u8 = if (i < ss.len) ss[i] else null;
        // Cache exactly the areas whose per-tile emit anchors something at the representative
        // point. A plain fill/boundary area — the vast majority (DEPARE, LNDARE, SBDARE, DEPCNT,
        // …) — anchors nothing there, and the pole-of-inaccessibility search is expensive, so skip
        // it. The set below is a strict SUPERSET of what the per-tile path consults, so a cached
        // point is only ever spurious, never missing — labelPoint (which recomputes the SAME
        // search from the SAME geometry on a miss) stays byte-identical either way:
        //   • hasAdditionalInfo -> the §10.6.1.1 INFORM01 marker (stream-independent),
        //   • an unmapped S-57 area -> the QUESMRK1 "?" fallback. It carries a NULL/errored
        //     portrayal stream yet still runs featureAnchor for EVERY tile the polygon spans —
        //     the per-tile pole-of-inaccessibility search that dominated Inland-ENC bakes (objl
        //     17000+ area classes with no S-101 mapping, huge river/fairway polygons). Mirror the
        //     emit-side QUESMRK1 guard exactly so this leaves the live path only when that fires.
        //   • a portrayed area placing a centred label (TextInstruction) or symbol
        //     (PointInstruction).
        const unmapped_qmark = !cell.native and f.objl != s57.OBJL_TOPMAR and adapter.resolveClass(f) == null;
        const places_symbol = if (stream) |s|
            std.mem.indexOf(u8, s, "TextInstruction:") != null or
                std.mem.indexOf(u8, s, "PointInstruction:") != null
        else
            false;
        if (!hasAdditionalInfo(f) and !unmapped_qmark and !places_symbol) continue;
        const parts = featureParts(tmp.allocator(), cell.*, geo, i, f) catch continue;
        out[i] = s57.areaRepresentativePoint(tmp.allocator(), parts);
        _ = tmp.reset(.retain_capacity);
    }
    return out;
}

/// Per-feature DRAWN-boundary cache (cell.drawn_boundary), indexed by feature index.
/// An area feature whose stroked boundary differs from its full fill ring
/// (needsDrawableBoundary — MASK/USAG edge flags, or a coast-coincident edge on a
/// non-coast-definer area) restrokes only the drawableLineParts SUBSET. That subset is
/// tile-invariant, so assemble it ONCE here and precompute each vertex's web-mercator
/// world coordinate — the per-tile emit then reprojects with a linear worldToTile instead
/// of running the transcendental projection on the boundary for every tile the area spans
/// (the dominant cost on Inland-ENC river cells: fairway/depth areas with long shared coast
/// boundaries). A null slot leaves the feature on the live path (reconstruct + project),
/// byte-identical since `world` holds exactly `tile.lonLatToWorld` and `tile.project` is
/// `worldToTile ∘ lonLatToWorld`. Covers exactly the features the per-tile stroke path
/// routes through drawableLineParts — ANY prim whose `needsDrawableBoundary` holds, not
/// areas only: a LINE (prim 2) with MASK/USAG edge flags takes the same drawn-subset path
/// and was the bulk of the uncached per-tile projection on Inland-ENC cells.
pub fn buildDrawnBoundary(a: Allocator, cell: *const s57.Cell) ![]?s57.DrawnBoundary {
    const out = try a.alloc(?s57.DrawnBoundary, cell.features.len);
    @memset(out, null);
    for (cell.features, 0..) |f, i| {
        if (!cell.needsDrawableBoundary(f)) continue;
        const parts = cell.drawableLineParts(a, f) catch continue;
        const world = a.alloc([][2]f64, parts.len) catch continue;
        for (parts, 0..) |part, pi| {
            const wp = try a.alloc([2]f64, part.len);
            for (part, 0..) |pt, j| wp[j] = tile.lonLatToWorld(pt.lon(), pt.lat());
            world[pi] = wp;
        }
        out[i] = .{ .parts = parts, .world = world };
    }
    return out;
}

/// One assembled line/area part: its tile-independent web-mercator coords plus its
/// static lon/lat bbox [w,s,e,n] and the matching normalised world bbox
/// [min_wx,min_wy,max_wx,max_wy]. Both are computed ONCE here so the baker's
/// per-tile cull reuses them instead of recomputing geomBounds for every tile a
/// feature spans (that recompute was ~10% of the bake). worldToTile is linear and
/// monotonic, so projecting the world bbox corners yields the part's exact
/// tile-coord bbox — letting processFeatureParsed skip a part that misses the clip box
/// without projecting its points (byte-identical to clipping it to empty).
pub const WPart = struct { pts: [][2]f64, bbox: [4]f64, wbbox: [4]f64 };

/// World coords (web-mercator [0,1]) parallel to a geo cache: each line/area
/// point's tile-independent projection, computed ONCE per cell so the baker
/// reprojects cheaply per tile (tile.worldToTile, no tan/log) instead of running
/// the transcendental projection for every tile a feature touches. Built from the
/// assembled geo cache, so [fi][part] lines up with GeoParts.
pub const GeoWorld = []const ?[]WPart;

pub fn buildGeoWorld(a: Allocator, geo: GeoParts) !GeoWorld {
    const out = try a.alloc(?[]WPart, geo.len);
    for (geo, 0..) |maybe_parts, i| {
        out[i] = null;
        const parts = maybe_parts orelse continue;
        const wparts = a.alloc(WPart, parts.len) catch continue;
        for (parts, 0..) |part, pi| {
            const wp = try a.alloc([2]f64, part.len);
            var bb = [4]f64{ 1e9, 1e9, -1e9, -1e9 };
            var wbb = [4]f64{ 1e9, 1e9, -1e9, -1e9 };
            for (part, 0..) |pt, j| {
                const lo = pt.lon();
                const la = pt.lat();
                wp[j] = tile.lonLatToWorld(lo, la);
                bb[0] = @min(bb[0], lo);
                bb[1] = @min(bb[1], la);
                bb[2] = @max(bb[2], lo);
                bb[3] = @max(bb[3], la);
                wbb[0] = @min(wbb[0], wp[j][0]);
                wbb[1] = @min(wbb[1], wp[j][1]);
                wbb[2] = @max(wbb[2], wp[j][0]);
                wbb[3] = @max(wbb[3], wp[j][1]);
            }
            wparts[pi] = .{ .pts = wp, .bbox = bb, .wbbox = wbb };
        }
        out[i] = wparts;
    }
    return out;
}

/// The feature's assembled line/area parts: the baker's cached copy if present,
/// else assembled now (the live path).
pub fn featureParts(a: Allocator, cell: s57.Cell, geo: ?GeoParts, fi: usize, f: s57.Feature) ![][]s57.LonLat {
    if (geo) |g| if (fi < g.len) if (g[fi]) |p| return p;
    return cell.geometryParts(a, f);
}

/// The feature's area representative (label) point: the per-cell cached value (baker
/// path) if present, else an on-demand polylabel search (live single-tile path).
/// Byte-identical either way — the cache is the same search precomputed once.
fn labelPoint(a: Allocator, cell: s57.Cell, fi: usize, geo_parts: [][]s57.LonLat) ?s57.LonLat {
    // Use the cache only when it holds a point for this feature; a null slot means
    // "not cached" (an unlabelled feature, or one the cache skipped) and falls back to
    // a live search — so the cached path is always byte-identical to the live one.
    if (cell.label_cache) |lc| if (fi < lc.len) if (lc[fi]) |p| return p;
    return s57.areaRepresentativePoint(a, geo_parts);
}

/// Anchor for a centred label / point symbol / info marker on a line or area
/// feature, mirroring the oracle's textAnchor (build.go:145-162): a LINE anchors
/// at the MIDDLE VERTEX of its flat FSPT-order coordinate chain (g.line[len/2]);
/// an AREA at its representative pole-of-inaccessibility point (labelPoint). A
/// point feature anchors at its node and never reaches here. `geo_parts` is the
/// assembled line/area geometry. The line case indexes the concatenation of the
/// parts: lineGeometryParts splits only at genuine discontinuities (where no node
/// is shared), so the total vertex count and ordering match the oracle's single
/// constructLineStringGeometry sequence — previously a line was polylabelled like
/// an area, drifting its label/symbol off the line.
fn featureAnchor(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo_parts: [][]s57.LonLat) ?s57.LonLat {
    if (f.prim == 2) return lineMidVertex(geo_parts);
    return labelPoint(a, cell, fi, geo_parts);
}

/// The middle vertex of a line's flat FSPT-order coordinate chain — the oracle's
/// textAnchor line case, g.line[len/2]. `geo_parts` is that chain split only at
/// genuine discontinuities (no node is shared across a split), so the concatenated
/// vertex count + ordering match the oracle's single constructLineStringGeometry
/// sequence; walk the parts to the global middle index.
fn lineMidVertex(geo_parts: [][]s57.LonLat) ?s57.LonLat {
    var total: usize = 0;
    for (geo_parts) |p| total += p.len;
    if (total == 0) return null;
    var mid = total / 2;
    for (geo_parts) |p| {
        if (mid < p.len) return p[mid];
        mid -= p.len;
    }
    return null; // unreachable: mid < total
}

test "lineMidVertex: middle vertex of the concatenated FSPT chain" {
    const v = struct {
        fn f(i: i32) s57.LonLat {
            return .{ .lon_e7 = i, .lat_e7 = i };
        }
    }.f;
    {
        var empty: [0][]s57.LonLat = .{};
        try std.testing.expect(lineMidVertex(&empty) == null);
        var ep: [0]s57.LonLat = .{};
        var one_empty = [_][]s57.LonLat{&ep};
        try std.testing.expect(lineMidVertex(&one_empty) == null);
    }
    // Single part, 5 vertices -> index 2.
    {
        var p0 = [_]s57.LonLat{ v(0), v(1), v(2), v(3), v(4) };
        var parts = [_][]s57.LonLat{&p0};
        try std.testing.expectEqual(@as(i32, 2), lineMidVertex(&parts).?.lon_e7);
    }
    // Two parts (3 + 2 = 5) -> global index 2 is the last vertex of part 0.
    {
        var p0 = [_]s57.LonLat{ v(0), v(1), v(2) };
        var p1 = [_]s57.LonLat{ v(3), v(4) };
        var parts = [_][]s57.LonLat{ &p0, &p1 };
        try std.testing.expectEqual(@as(i32, 2), lineMidVertex(&parts).?.lon_e7);
    }
    // Two parts (2 + 3 = 5) -> global index 2 is the first vertex of part 1.
    {
        var p0 = [_]s57.LonLat{ v(0), v(1) };
        var p1 = [_]s57.LonLat{ v(2), v(3), v(4) };
        var parts = [_][]s57.LonLat{ &p0, &p1 };
        try std.testing.expectEqual(@as(i32, 2), lineMidVertex(&parts).?.lon_e7);
    }
}

/// True when `variant` is a usable display-variant stream that genuinely differs
/// from the default `base` stream — i.e. this feature's portrayal actually changes
/// under the override, so it needs a two-pass (rank 0/1) split. An absent, errored,
/// or byte-identical variant means the feature is style-independent: it stays a
/// single common pass (rank 2), keeping its tile footprint unchanged.
fn variantDiffers(base: []const u8, variant: ?[]const u8) bool {
    const v = variant orelse return false;
    if (std.mem.startsWith(u8, v, "ERROR:")) return false;
    return !std.mem.eql(u8, base, v);
}

/// Drive one feature's S-101 instruction stream (plus its optional plain/simplified
/// display variants) through the Surface: parse each pass and hand it to
/// processFeatureParsed, splitting into two passes only when a variant differs
/// (S-52 boundary §8.6.1 / point-symbol §11.2.2 axes -> the bnd/pts tags).
fn processFeatureInstr(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, geo_world: ?GeoWorld, instr: []const u8, plain: ?[]const u8, simplified: ?[]const u8, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, opts: CellOpts, surf: rs.Surface) !void {
    const base = try instructions.parse(a, instr);
    if (f.prim == 1) {
        if (variantDiffers(instr, simplified)) {
            try processFeatureParsed(a, cell, f, fi, geo, geo_world, base, 2, 0, z, x, y, tb, box, opts, surf);
            const sp2 = try instructions.parse(a, simplified.?);
            try processFeatureParsed(a, cell, f, fi, geo, geo_world, sp2, 2, 1, z, x, y, tb, box, opts, surf);
        } else {
            try processFeatureParsed(a, cell, f, fi, geo, geo_world, base, 2, 2, z, x, y, tb, box, opts, surf);
        }
        return;
    }
    if (f.prim == 3 and variantDiffers(instr, plain)) {
        try processFeatureParsed(a, cell, f, fi, geo, geo_world, base, 1, 2, z, x, y, tb, box, opts, surf);
        const pl = try instructions.parse(a, plain.?);
        try processFeatureParsed(a, cell, f, fi, geo, geo_world, pl, 0, 2, z, x, y, tb, box, opts, surf);
        return;
    }
    try processFeatureParsed(a, cell, f, fi, geo, geo_world, base, 2, 2, z, x, y, tb, box, opts, surf);
}

// Web-mercator equatorial circumference (m): converts a ground-distance sector leg
// (GeographicCRS length) to a normalised-world offset. Mirrors Go bake.earthCircumM.
const EARTH_CIRCUM_M: f64 = 40075016.686;

/// Screen-space unit vector for a true-north bearing, with y growing southward
/// (north=(0,-1), east=(1,0)). Mirrors Go bake.bearingToScreen.
fn bearingToScreen(deg: f64) [2]f64 {
    const r = deg * std.math.pi / 180.0;
    return .{ @sin(r), -@cos(r) };
}

/// Tessellate the parsed sector figures (LightSectored legs/arcs) around `anchor`
/// into `lines_l` for tile (z,x,y). Port of internal/engine/bake.tessellateFigure:
/// figures are fixed display-mm sized, so their geographic extent is per-zoom. A ray
/// is the anchor -> a point at its bearing/length; an arc is N points along its
/// radius over the sweep (a 0 sweep = a full ring). Built in normalised-world coords
/// (anchor + screen-offset/worldPx) and projected with worldToTile — identical to
/// Go's per-zoom sunproject + reproject. Each figure carries its own stroke + vg.
/// Zoom below which a full-circle range ring (LightAllAround majorLight) is NOT
/// emitted. The ring is a fixed ~26 mm decoration drawn as baked geometry, so at
/// small scales it reads as a huge circle covering a wide ground area — and every
/// major light (VALNMR ≥ 10 M) has one, so overview fills with overlapping circles.
/// Real ECDIS shows the ring when zoomed in; gate to approach scale and finer
/// (bake_enc.bandZooms(.approach).min = 11). Partial sector arcs are unaffected.
const RING_MIN_ZOOM: u8 = 11;

fn emitAugFigures(a: Allocator, figs: []const instructions.AugFigure, anchor: s57.LonLat, fmeta: rs.FeatureMeta, z: u8, x: u32, y: u32, box: tile.Box, surf: rs.Surface) !void {
    if (figs.len == 0) return;
    // One tile renders as 512 CSS px (the engine's physical-scale model — style
    // scaminGateK's M_PER_PX_Z0 is the 512-tile metres-per-CSS-px, and MapLibre
    // lays vector tiles out at 512 logical px), so a display-mm length converts
    // to a tile fraction against a 512·2^z world. The old 256-unit MVT world drew
    // every figure at exactly 2x its catalogue size (20 mm sector arcs read
    // 40 mm on the map). Ground-metre legs are a world-fraction ratio either way.
    const world_px = 512.0 * @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    const pxmm = instructions.PX_PER_MM;
    for (figs) |fig| {
        const alon = if (fig.has_anchor) fig.anchor_lon else anchor.lon();
        const alat = if (fig.has_anchor) fig.anchor_lat else anchor.lat();
        const aw = tile.lonLatToWorld(alon, alat);

        var wpts = std.ArrayList([2]f64).empty;
        if (fig.is_ray) {
            var len_px = fig.length_mm * pxmm;
            if (fig.length_ground_m > 0) {
                const cos_lat = @cos(alat * std.math.pi / 180.0);
                if (cos_lat > 1e-6) len_px = fig.length_ground_m / (cos_lat * EARTH_CIRCUM_M) * world_px;
            }
            if (len_px <= 0) continue;
            const d = bearingToScreen(fig.bearing_deg);
            try wpts.append(a, aw);
            try wpts.append(a, .{ aw[0] + d[0] * len_px / world_px, aw[1] + d[1] * len_px / world_px });
        } else {
            const radius_px = fig.radius_mm * pxmm;
            if (radius_px <= 0) continue;
            var sweep = fig.sweep_deg;
            if (sweep == 0) sweep = 360; // a zero sweep is a full all-round ring
            // Suppress the major-light range ring (full circle) below approach scale
            // (see RING_MIN_ZOOM) — it would balloon into overlapping circles at
            // overview. Partial sector arcs (|sweep| < 360) keep drawing.
            if (@abs(sweep) >= 360 and z < RING_MIN_ZOOM) continue;
            const n: usize = @max(@as(usize, @intFromFloat(@ceil(@abs(sweep) / 3.0))), 8);
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                const brg = fig.start_deg + sweep * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const d = bearingToScreen(brg);
                try wpts.append(a, .{ aw[0] + d[0] * radius_px / world_px, aw[1] + d[1] * radius_px / world_px });
            }
        }
        if (wpts.items.len < 2) continue;

        const proj = try a.alloc(mvt.Point, wpts.items.len);
        for (wpts.items, 0..) |w, j| proj[j] = tile.worldToTile(w, z, x, y, tile.EXTENT);
        // Clip to the tile box (incl. buffer); keep the arc shape (no DP simplify).
        const sub = try tile.clipLine(a, proj, box);
        var kept = std.ArrayList([]const mvt.Point).empty;
        for (sub) |run| if (run.len >= 2) try kept.append(a, run);
        if (kept.items.len == 0) continue;

        var fig_meta = fmeta;
        fig_meta.vg = if (fig.vg != 0) fig.vg else fmeta.vg; // sector arcs filter on their own VG
        try surf.beginFeature(&fig_meta);
        try surf.strokeLine(fig.color, fig.width_mm * pxmm, if (fig.dashed) .dashed else .solid, kept.items, null);
        try surf.endFeature();
    }
}

/// DEPARE (42) / DRGARE (46) depth-area DRVAL1/DRVAL2 (metres), as f32 to match the
/// Go baker's `depthVals` + `mvt.FloatVal`. DRVAL2 falls back to DRVAL1 when absent;
/// a non-depth area or a missing DRVAL1 -> null (the props are omitted). The style's
/// `areasFillColor` keys on `drval1` to run SEABED01 shading (incl. the DEPDW/white
/// deep-water shade) + the safety-contour line + shallow pattern LIVE against the
/// mariner's contours, so depth areas must carry their range.
fn depthVals(f: s57.Feature) ?[2]f32 {
    if (f.objl != 42 and f.objl != 46) return null;
    const d1 = f.attrFloat(s57.ATTR_DRVAL1) orelse return null;
    const d2 = f.attrFloat(s57.ATTR_DRVAL2) orelse d1;
    return .{ @floatCast(d1), @floatCast(d2) };
}

fn appendDepthVals(a: Allocator, props: *std.ArrayList(mvt.Prop), f: s57.Feature) !void {
    if (depthVals(f)) |dv| {
        try props.append(a, .{ .key = "drval1", .value = .{ .float = dv[0] } });
        try props.append(a, .{ .key = "drval2", .value = .{ .float = dv[1] } });
    }
}

/// Emit one parsed portrayal pass `p` through the Surface interface, stamping
/// every primitive with the pass's meta (display_priority/cat/vg/scamin/bnd/pts + pick
/// attrs). The engine work happens here — geometry assembly, projection, tile
/// clipping/simplification, anchoring — so surfaces only ever see draw calls.
/// The cursor-pick report's class name for a feature. A native S-101 cell serves
/// its S-101 class; an S-57 cell serves the S-57 acronym.
fn pickClass(cell: s57.Cell, f: s57.Feature, fi: usize) []const u8 {
    if (cell.native) return if (cell.pick_class) |pc| (if (fi < pc.len) pc[fi] else "") else "";
    return catalogue.acronymByObjl(f.objl) orelse "";
}
/// The cursor-pick report's attribute JSON for a feature. A native S-101 cell serves
/// its S-101 attribute tree (UTF-8 preserved); an S-57 cell serves `encodeS57Attrs`.
/// Empty unless `pick` (the pick-enabled path); never fails (report metadata).
fn pickJson(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, pick: bool) []const u8 {
    if (!pick) return "";
    if (cell.native) return if (cell.pick_json) |pj| (if (fi < pj.len) pj[fi] else "") else "";
    return encodeS57Attrs(a, f) catch "";
}

fn processFeatureParsed(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, geo_world: ?GeoWorld, p: instructions.Portrayal, bnd: i64, pts: i64, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, opts: CellOpts, surf: rs.Surface) !void {
    const scamin = effScamin(f, opts);
    const cell_name = if (opts.pick_attrs) cell.name else "";
    const fmeta = rs.FeatureMeta{
        .display_priority = p.display_priority,
        .display_plane = p.plane,
        .display_category = p.cat,
        .vg = p.vg,
        .scamin = scamin,
        .oscl = opts.oscl,
        .class = pickClass(cell, f, fi),
        .s57_json = pickJson(a, cell, f, fi, opts.pick_attrs),
        .cell_name = cell_name,
        .band = opts.band,
        .date_start = p.date_start,
        .date_end = p.date_end,
        .bnd = bnd,
        .pts = pts,
    };

    // ── Point features ──────────────────────────────────────────────────────────
    if (f.prim == 1) {
        const pg = cell.pointGeometry(f) orelse return;
        // Sector legs / arcs draw before the light's own symbols (S-52 stacking).
        // They INHERIT the anchor point's coverage verdict (suppress_points /
        // suppress_lines) and are never independently clipped: a clipped-away
        // light drops its arc with it (no cross-band double arc), a surviving
        // light keeps its full arc even where it sweeps into finer coverage
        // (no amputation at the seam). Spec §2.3 sector-arc rule.
        if (!opts.suppress_points and !opts.suppress_lines)
            try emitAugFigures(a, p.aug_figures, pg, fmeta, z, x, y, box, surf);
        if (pg.lon() < tb[0] or pg.lon() > tb[2] or pg.lat() < tb[1] or pg.lat() > tb[3]) return;
        const pt = tile.project(pg.lon(), pg.lat(), z, x, y, tile.EXTENT);
        if (!opts.suppress_points) {
            // Sounding routing: coalesce SNDFRM04 glyphs + VALSOU → soundings layer.
            var routed_sounding = false;
            if (f.attrFloat(s57.ATTR_VALSOU)) |valsou| {
                var has = false;
                for (p.points) |sym| {
                    if (isSoundingName(sym.symbol)) {
                        has = true;
                        break;
                    }
                }
                if (has and std.math.isFinite(valsou)) {
                    const q = soundingQualityFlags(f);
                    try surf.beginFeature(&fmeta);
                    try surf.drawSounding(valsou, q.swept, q.low_acc, pt);
                    try surf.endFeature();
                    routed_sounding = true;
                }
            }
            for (p.points) |sym| {
                if (routed_sounding and isSoundingName(sym.symbol)) continue;
                const is_d12 = std.mem.eql(u8, sym.symbol, "DANGER01") or std.mem.eql(u8, sym.symbol, "DANGER02");
                const danger_class = f.objl == 86 or f.objl == 153 or f.objl == 159;
                const danger_depth: ?f64 = if (is_d12 and danger_class) f.attrFloat(s57.ATTR_VALSOU) else null;
                try surf.beginFeature(&fmeta);
                try surf.drawSymbol(sym.symbol, pt, sym.rotation, SYMBOL_SCALE, sym.rot_north, .point, danger_depth);
                try surf.endFeature();
            }
            for (p.texts) |t| {
                const ts = textStyleFor(t, f, fmeta);
                try surf.beginFeature(&fmeta);
                try surf.drawText(try expandSeabedText(a, fmeta.class, stripNameTag(t.text)), &ts, pt);
                try surf.endFeature();
            }
        }
        return;
    }

    // ── Line / area features ────────────────────────────────────────────────────
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const wparts: ?[]const WPart = if (geo_world) |gw| (if (fi < gw.len) gw[fi] else null) else null;
    var projected = std.ArrayList([]mvt.Point).empty;
    var any_overlap = false;
    for (geo_parts, 0..) |gp, pi| {
        if (gp.len < 2) continue;
        const wp: ?WPart = if (wparts) |wps| (if (pi < wps.len and wps[pi].pts.len == gp.len) wps[pi] else null) else null;
        if (wp) |w| {
            if (overlaps(w.bbox, tb)) any_overlap = true;
            const lo = tile.worldToTile(.{ w.wbbox[0], w.wbbox[1] }, z, x, y, tile.EXTENT);
            const hi = tile.worldToTile(.{ w.wbbox[2], w.wbbox[3] }, z, x, y, tile.EXTENT);
            if (hi.x < box.min or lo.x > box.max or hi.y < box.min or lo.y > box.max) continue;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (w.pts, 0..) |ww, i| proj[i] = tile.worldToTile(ww, z, x, y, tile.EXTENT);
            try projected.append(a, proj);
        } else {
            if (overlaps(geomBounds(gp), tb)) any_overlap = true;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (gp, 0..) |p2, i| proj[i] = tile.project(p2.lon(), p2.lat(), z, x, y, tile.EXTENT);
            try projected.append(a, proj);
        }
    }
    if (!any_overlap or projected.items.len == 0) return;

    if (f.prim == 3) {
        var rings = std.ArrayList([]const mvt.Point).empty;
        for (projected.items) |proj| {
            const ring = try clipSimplifyPoly(a, proj, box);
            if (ring.len >= 3) try rings.append(a, ring);
        }
        // Best-available: cut this cell's fill where a finer cell covers the ground.
        const arings = if (opts.cover_clip) |cc| subtractCoverage(a, rings.items, cc) else rings.items;
        if (arings.len > 0) {
            const rparts = try mvt.orientAreaRings(a, arings);
            const dv = depthVals(f);
            const dr: ?rs.DepthRange = if (dv) |d| .{ .d1 = d[0], .d2 = d[1] } else null;
            const fillmeta = fmeta;
            if (!opts.suppress_fills) if (p.fill_token) |token| {
                try surf.beginFeature(&fillmeta);
                try surf.fillArea(token, rparts, dr);
                try surf.endFeature();
            };
            if (!opts.suppress_patterns) for (p.patterns) |pat| {
                try surf.beginFeature(&fillmeta);
                try surf.fillPattern(pat, rparts);
                try surf.endFeature();
            };
        }
    }

    const valdco: ?f64 = if (f.objl == 43) f.attrFloat(s57.ATTR_VALDCO) else null;

    var stroke_geo: []const []s57.LonLat = geo_parts;
    var stroke_proj: []const []const mvt.Point = projected.items;
    if (!opts.suppress_lines and p.lines.len > 0 and cell.needsDrawableBoundary(f)) {
        var stroke_storage = std.ArrayList([]mvt.Point).empty;
        // The baker's per-cell drawn-boundary cache: the drawableLineParts subset plus each
        // vertex's precomputed world coord. Reproject the cached world with a linear
        // worldToTile instead of the transcendental projection on every tile — the drawn
        // boundary is tile-invariant. Live path (no cache / single tile) reconstructs and
        // projects directly; byte-identical, since project == worldToTile ∘ lonLatToWorld.
        const cached: ?s57.DrawnBoundary = if (cell.drawn_boundary) |db| (if (fi < db.len) db[fi] else null) else null;
        const dparts: []const []s57.LonLat = if (cached) |c| c.parts else (cell.drawableLineParts(a, f) catch &[_][]s57.LonLat{});
        stroke_geo = dparts;
        for (dparts, 0..) |dp, pi| {
            if (dp.len < 2) continue;
            if (!overlaps(geomBounds(dp), tb)) continue;
            const proj = try a.alloc(mvt.Point, dp.len);
            if (cached) |c| {
                for (c.world[pi], 0..) |ww, i| proj[i] = tile.worldToTile(ww, z, x, y, tile.EXTENT);
            } else {
                for (dp, 0..) |p2, i| proj[i] = tile.project(p2.lon(), p2.lat(), z, x, y, tile.EXTENT);
            }
            try stroke_storage.append(a, proj);
        }
        stroke_proj = stroke_storage.items;
    }
    // Best-available: cut the covered stretches out of this cell's strokes — the
    // exact line half of the composite (see clipRunsOutsideCover). The geo-space
    // copy feeds the complex-linestyle tessellator, the projected copy the plain
    // stroke path below. The coverage cut is the per-segment-vs-cover hotspot, so
    // clip ONLY the copy an actual line instruction will consume: a feature whose
    // lines are all plain (solid/dashed) never touches stroke_geo, and one with
    // only complex linestyles never touches stroke_proj — clipping the unused copy
    // is pure waste. Same output, one cut instead of two on the common path.
    if (opts.cover_clip) |cc| {
        var want_geo = false;
        var want_proj = false;
        if (!opts.suppress_lines) for (p.lines) |ln| {
            if (!std.mem.eql(u8, ln.style, "solid") and linestyle.lookup(ln.style) != null) want_geo = true else want_proj = true;
        };
        if (want_geo) stroke_geo = clipGeoPartsOutsideCover(a, stroke_geo, cc, z, x, y);
        if (want_proj) stroke_proj = clipRunsOutsideCover(a, stroke_proj, cc);
    }

    const force_dash = !quaposSolidClass(f.objl) and s57.isLowAccuracyQuapos(cell.featureQuapos(f));

    if (!opts.suppress_lines) for (p.lines) |ln| {
        if (!std.mem.eql(u8, ln.style, "solid")) {
            if (linestyle.lookup(ln.style)) |info| {
                // Complex linestyle: tessellated dash runs + tangent-rotated symbols.
                try linestyle.drawComplexLine(a, stroke_geo, info, ln.style, ln.color, !opts.suppress_points, z, x, y, box, &fmeta, surf);
                continue;
            }
        }
        const dash_str: []const u8 = if (std.mem.eql(u8, ln.style, "solid"))
            (if (force_dash) "dashed" else "solid")
        else
            "dashed";
        const dash: rs.Dash = if (std.mem.eql(u8, dash_str, "solid")) .solid else .dashed;
        try linestyle.drawPlainLine(a, stroke_proj, ln.color, ln.width, dash, box, &fmeta, valdco, surf);
    };

    if (!opts.suppress_points and p.texts.len > 0) {
        if (featureAnchor(a, cell, f, fi, geo_parts)) |rp| {
            if (rp.lon() >= tb[0] and rp.lon() <= tb[2] and rp.lat() >= tb[1] and rp.lat() <= tb[3]) {
                const cpt = tile.project(rp.lon(), rp.lat(), z, x, y, tile.EXTENT);
                for (p.texts) |t| {
                    const ts = textStyleFor(t, f, fmeta);
                    try surf.beginFeature(&fmeta);
                    try surf.drawText(try expandSeabedText(a, fmeta.class, stripNameTag(t.text)), &ts, cpt);
                    try surf.endFeature();
                }
            }
        }
    }

    if (!opts.suppress_points and p.points.len > 0) {
        if (featureAnchor(a, cell, f, fi, geo_parts)) |rp| {
            if (rp.lon() >= tb[0] and rp.lon() <= tb[2] and rp.lat() >= tb[1] and rp.lat() <= tb[3]) {
                const cpt = tile.project(rp.lon(), rp.lat(), z, x, y, tile.EXTENT);
                var routed_sounding = false;
                if (f.attrFloat(s57.ATTR_VALSOU)) |valsou| {
                    var has = false;
                    for (p.points) |sym| {
                        if (isSoundingName(sym.symbol)) {
                            has = true;
                            break;
                        }
                    }
                    if (has and std.math.isFinite(valsou)) {
                        const q = soundingQualityFlags(f);
                        try surf.beginFeature(&fmeta);
                        try surf.drawSounding(valsou, q.swept, q.low_acc, cpt);
                        try surf.endFeature();
                        routed_sounding = true;
                    }
                }
                for (p.points) |sym| {
                    if (routed_sounding and isSoundingName(sym.symbol)) continue;
                    const is_d12 = std.mem.eql(u8, sym.symbol, "DANGER01") or std.mem.eql(u8, sym.symbol, "DANGER02");
                    const danger_class = f.objl == 86 or f.objl == 153 or f.objl == 159;
                    const danger_depth: ?f64 = if (is_d12 and danger_class) f.attrFloat(s57.ATTR_VALSOU) else null;
                    try surf.beginFeature(&fmeta);
                    try surf.drawSymbol(sym.symbol, cpt, sym.rotation, SYMBOL_SCALE, sym.rot_north, .point, danger_depth);
                    try surf.endFeature();
                }
            }
        }
    }
}

/// Native S-52 fallback for SweptArea (SWPARE, objl 134). The S-101 Portrayal
/// Catalogue ships no SweptArea rule (an IHO gap), so the Lua engine emits
/// nothing for it. Mirror the Go reference's sweptAreaBuild: a dashed CHGRD
/// boundary on every ring, the SWPARE51 swept-depth bracket at the area's
/// representative point, and a "swept to <DRVAL1>" label there. DrawingPriority 6.
fn emitSweptAreaFallback(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, opts: CellOpts, surf: rs.Surface) !void {
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const fmeta = rs.FeatureMeta{
        .display_priority = 6,
        .scamin = effScamin(f, opts),
        .class = pickClass(cell, f, fi),
        .s57_json = pickJson(a, cell, f, fi, opts.pick_attrs),
        .cell_name = if (opts.pick_attrs) cell.name else "",
        .band = opts.band,
    };
    try surf.beginFeature(&fmeta);

    // Dashed CHGRD boundary on each ring (clipped to the tile, covered stretches
    // cut by the finer cells' coverage — best-available).
    if (!opts.suppress_lines) for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        var sub = try tile.clipSimplifyLine(a, proj, box);
        if (opts.cover_clip) |cc| sub = clipRunsOutsideCover(a, sub, cc);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        try surf.strokeLine("CHGRD", 1, .dashed, parts, null);
    };

    // SWPARE51 bracket + "swept to <DRVAL1>" label at the representative point. Drop
    // both where a finer band covers the whole tile (suppress_points).
    if (!opts.suppress_points) blk: {
        const rp = labelPoint(a, cell, fi, geo_parts) orelse break :blk;
        if (rp.lon() < tb[0] or rp.lon() > tb[2] or rp.lat() < tb[1] or rp.lat() > tb[3]) break :blk;
        const cpt = tile.project(rp.lon(), rp.lat(), z, x, y, tile.EXTENT);
        try surf.drawSymbol("SWPARE51", cpt, 0, SYMBOL_SCALE, false, .point, null);

        if (f.attrFloat(s57.ATTR_DRVAL1)) |d1| {
            const label = try std.fmt.allocPrint(a, "swept to {d}", .{d1});
            // Minimal label (empty halign): no alignment/halo/group spec — see rs.TextStyle.
            try surf.drawText(label, &.{ .color = "CHBLK", .font_size = 11 }, cpt);
        }
    }
    try surf.endFeature();
}

/// Native S-52 fallback for M_NSYS (objl 306) — the Go reference's navSystemBuild.
/// A marine navigation-system meta-area whose boundary is the IALA-A / IALA-B system
/// limit: stroke each ring with the MARSYS51 complex linestyle — the dashed "—A——B—"
/// pattern carrying the EMMARS01 (IALA-A) and EMMARS02 (IALA-B) letter symbols — or
/// NAVARE51 when ORIENT marks a direction of buoyage. The S-101 catalogue routes
/// M_NSYS to nothing (the S-101 adapter excludes it so this rule owns it), so without this
/// the boundary draws nothing. DrawingPriority 12. NOTE: the ORIENT-only DIRBOY
/// direction-of-buoyage arrow (DIRBOY01/A1/B1, CentreOnArea) is not yet ported —
/// absent on the reference data; the A/B boundary line is the visible feature.
fn emitNavSystemFallback(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, opts: CellOpts, surf: rs.Surface) !void {
    if (opts.suppress_lines) return;
    // S-52 §8.6.2 boundary masking, mirrored from the portrayal stroke path: the
    // producer flags the M_NSYS edges that coincide with the cell limit (MASK/USAG),
    // so the system boundary strokes only where a REAL division runs — not along
    // every cell junction of a uniform IALA region. The fill is unaffected.
    const masked_boundary = cell.needsDrawableBoundary(f);
    const geo_parts = if (masked_boundary)
        cell.drawableLineParts(a, f) catch return
    else
        featureParts(a, cell, geo, fi, f) catch return;

    const fmeta = rs.FeatureMeta{
        .display_priority = 12,
        .scamin = effScamin(f, opts),
        .class = pickClass(cell, f, fi),
        .s57_json = pickJson(a, cell, f, fi, opts.pick_attrs),
        .cell_name = if (opts.pick_attrs) cell.name else "",
        .band = opts.band,
    };

    // ORIENT present -> direction-of-buoyage boundary (NAVARE51); else the plain
    // IALA A/B system boundary (MARSYS51). Both stroke in CHGRD.
    const boundary: []const u8 = if (f.attr(s57.ATTR_ORIENT) != null) "NAVARE51" else "MARSYS51";

    // The masked complement (cell-limit stretches) rides along tagged, for the
    // meta-bounds view; the standard display filters the class out anyway.
    if (masked_boundary) try emitMaskedBoundary(a, cell, f, fmeta, z, x, y, tb, box, surf);
    if (geo_parts.len == 0) return;

    // Best-available: cut the covered stretches before tessellating/stroking.
    const nav_parts = if (opts.cover_clip) |cc| clipGeoPartsOutsideCover(a, geo_parts, cc, z, x, y) else geo_parts;

    // Tessellate the registered complex linestyle (dashes + the A/B letter symbols).
    if (linestyle.lookup(boundary)) |info| {
        try linestyle.drawComplexLine(a, nav_parts, info, boundary, "CHGRD", !opts.suppress_points, z, x, y, box, &fmeta, surf);
        return;
    }
    // No registered linestyle (live/host path, no table): a plain dashed CHGRD ring.
    try surf.beginFeature(&fmeta);
    for (nav_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const sub = try tile.clipSimplifyLine(a, proj, box);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        try surf.strokeLine("CHGRD", 1, .dashed, parts, null);
    }
    try surf.endFeature();
}

/// The §8.6.2-masked complement of a boundary, baked as a `masked`-tagged plain
/// dashed line so the meta-bounds inspection view can OUTLINE the meta object —
/// a whole-cell M_NSYS has its entire boundary flagged as the cell limit, and
/// masking alone leaves the toggle nothing to show. The standard display never
/// renders it (the meta classes are filtered out unless meta-bounds is on), and
/// the tag keeps the masked pieces letter-free in the styled view too.
fn emitMaskedBoundary(a: Allocator, cell: s57.Cell, f: s57.Feature, base: rs.FeatureMeta, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, surf: rs.Surface) !void {
    const masked_parts = cell.maskedLineParts(a, f) catch return;
    if (masked_parts.len == 0) return;
    var fmeta = base;
    fmeta.masked = true;
    // NOT cover-clipped: this is the meta-bounds inspection outline of one chart's
    // OWN extent, so it must trace that chart's whole boundary even where a finer
    // chart owns the ground on top of it. Clipping it to the best-available cover
    // (as the drawn portrayal is) carves the outline apart wherever a finer chart
    // overlaps — a coarse chart's rectangle comes out in disjoint fragments. The
    // inspection view wants every contributing chart's complete extent.
    try surf.beginFeature(&fmeta);
    for (masked_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const sub = try tile.clipSimplifyLine(a, proj, box);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        try surf.strokeLine("CHGRD", 1, .dashed, parts, null);
    }
    try surf.endFeature();
}

/// Native S-52 fallback for NEWOBJ (objl 163). NEWOBJ features map to S-101 classes
/// (e.g. VirtualAISAidToNavigation) whose rule may not portray the encoded geometry
/// (wrong primitive, unofficial stub, …); when portrayal yields nothing or errors,
/// draw the Go reference's newObjectBuild placeholder — a dashed CHMGF (magenta)
/// outline on the feature's line/area geometry. DrawingPriority 6.
/// Stroke a feature's line/area geometry as a dashed boundary in `color` — the
/// shared shape of several native S-52 fallbacks (NEWOBJ box; an area-encoded
/// RecommendedTrack whose Curve-only S-101 rule errors). DrawingPriority 6.
fn emitDashedBoundary(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, color: []const u8, width: f64, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, opts: CellOpts, surf: rs.Surface) !void {
    if (f.prim != 2 and f.prim != 3) return;
    if (opts.suppress_lines) return; // coarse band over finer M_COVR (centre): drop the stroke
    // Same S-52 §8.6.2 boundary masking as the portrayal stroke path (see
    // emitNavSystemFallback): masked cell-limit edges don't stroke.
    const geo_parts = if (cell.needsDrawableBoundary(f))
        cell.drawableLineParts(a, f) catch return
    else
        featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const fmeta = rs.FeatureMeta{
        .display_priority = 6,
        .scamin = effScamin(f, opts),
        .class = pickClass(cell, f, fi),
        .s57_json = pickJson(a, cell, f, fi, opts.pick_attrs),
        .cell_name = if (opts.pick_attrs) cell.name else "",
        .band = opts.band,
    };
    try surf.beginFeature(&fmeta);
    for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        var sub = try tile.clipSimplifyLine(a, proj, box);
        if (opts.cover_clip) |cc| sub = clipRunsOutsideCover(a, sub, cc);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        try surf.strokeLine(color, width, .dashed, parts, null);
    }
    try surf.endFeature();
}

/// Whether a feature is an M_COVR (objl 302) area with CATCOV=1 ("coverage
/// available") — the data-coverage polygon the S-52 §10.1.10 overscale hatch is
/// drawn over. Mirrors s57.Cell.mcovrCoverage's selection (CATCOV = S-57 attr 18).
fn isCoverageFeature(f: s57.Feature) bool {
    if (f.objl != 302 or f.prim != 3) return false;
    const cv = f.attr(18) orelse return false;
    const n = std.fmt.parseInt(i64, std.mem.trim(u8, cv, " "), 10) catch return false;
    return n == 1;
}

/// S-52 §10.1.10.2 overscale area at a chart scale boundary: emit one AP(OVERSC01)
/// area-pattern feature over an M_COVR(CATCOV=1) coverage polygon, clipped to the
/// tile, tagged `oscl` = the X2 gate denominator (cscl/OVERSCALE_FACTOR,
/// CellOpts.oscl). The style shows it only while the display is grossly overscale
/// (denominator FINER/smaller than oscl, i.e. X2+) and paints it ABOVE overscaled
/// cells' fills but BELOW at-scale (finer) cells' fills — the occlusion trick that
/// leaves the hatch only on coarse-only patches.
fn emitOverscaleHatch(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, opts: CellOpts, surf: rs.Surface) !void {
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;
    var rings = std.ArrayList([]const mvt.Point).empty;
    for (geo_parts) |gp| {
        if (gp.len < 3) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |p, i| proj[i] = tile.project(p.lon(), p.lat(), z, x, y, tile.EXTENT);
        const ring = try clipSimplifyPoly(a, proj, box);
        if (ring.len >= 3) try rings.append(a, ring);
    }
    if (rings.items.len == 0) return;
    const parts = try mvt.orientAreaRings(a, rings.items);
    const fmeta = rs.FeatureMeta{
        // S-52 §10.1.10.2: the overscale pattern draws at display priority 3 in
        // DISPLAY BASE (the indication is never optional content). No class/pick
        // payload — the hatch is an indication, not a chartable feature.
        .display_priority = 3,
        .display_category = 0,
        .band = opts.band,
        .oscl = opts.oscl,
        .overscale = true,
    };
    try surf.beginFeature(&fmeta);
    try surf.fillPattern("OVERSC01", parts);
    try surf.endFeature();
}

/// One cell plus its optional per-feature S-101 instruction streams. `portrayal`
/// is the default pass; `portrayal_plain` / `portrayal_simplified` are the
/// boundary-style (area) and point-style (point) display variants (null when not
/// computed) — see portray.CellPortrayal.
pub const CellRef = struct {
    cell: *s57.Cell,
    portrayal: ?[]const ?[]const u8 = null,
    portrayal_plain: ?[]const ?[]const u8 = null,
    portrayal_simplified: ?[]const ?[]const u8 = null,
    geo: ?GeoParts = null,
    /// World coords parallel to `geo` (precomputed projection) — lets the baker
    /// reproject line/area geometry per tile without per-point tan/log.
    geo_world: ?GeoWorld = null,
    /// Per-feature lon/lat bbox [w,s,e,n] (parallel to cell.features), precomputed
    /// once per cell so a tile can SKIP features it doesn't overlap instead of
    /// projecting + clipping every feature of every cell (the baker's spatial cull).
    feat_bbox: ?[]const ?[4]f64 = null,
    band: u8 = 0,
    /// Drop this coarser band cell's AREA fills / patterns / line strokes / point
    /// symbols+text where a finer band's M_COVR data-coverage is present. See the
    /// CellOpts.suppress_* fields for the per-geometry whole-tile vs centre rules.
    suppress_fills: bool = false,
    suppress_patterns: bool = false,
    suppress_lines: bool = false,
    suppress_points: bool = false,
    /// Finer-scale coverage to subtract from this cell's fills/patterns (see
    /// CellOpts.cover_clip) — the exact coverage-clipped composite.
    cover_clip: ?[]const []const mvt.Point = null,
    /// The cell's X2 overscale gate denominator (see CellOpts.oscl): tags area
    /// fills/patterns + gates the AP(OVERSC01) overscale hatch; 0 = unknown.
    oscl: i64 = 0,
    /// Emit this cell's AP(OVERSC01) coverage hatch (see CellOpts.overscale_hatch):
    /// a strictly-finer-CSCL cell rides this tile (scale boundary) AND this cell
    /// wins the pure quilt somewhere (it is the displayed smaller-scale data).
    overscale_hatch: bool = false,
    /// The effScamin floor for this cell (see CellOpts.eff_scamin_floor).
    eff_scamin_floor: i64 = 0,
    /// The imputed SCAMIN for this cell's ungated soundings (see
    /// CellOpts.sounding_scamin). 0 = derive it from the cell's own parsed scale:
    /// the baker keeps the compilation scale on its own backend (the cell it hands
    /// us has no DSPM params), so it passes the value in; the live paths, which
    /// parse the cell whole, let the fallback read it off the cell.
    sounding_scamin: i64 = 0,
    /// Max ground-distance sector-leg length (metres) among the cell's lights
    /// (see CellOpts.light_range_m) — the honest LIGHTS cull margin.
    light_range_m: f64 = 0,
    /// Isolated single-feature render (see CellOpts.only_fi): portray ONLY the
    /// feature at this index. null = the normal whole-cell pass.
    only_fi: ?usize = null,
};

/// Generate MVT bytes (uncompressed) for tile (z,x,y) from a single `cell`.
/// `portrayal`, if given, is indexed by feature index and holds each feature's
/// S-101 instruction stream (from the Lua engine); features with an instruction
/// stream are styled by it, the rest fall back to classify().
/// Generate encoded tile bytes (uncompressed) for tile (z,x,y) overlaying one or
/// more cells (an ENC_ROOT). Each cell's features are appended into the shared
/// layers, so a tile spanning several cells carries all of them.
///
/// `scratch` holds all transient working memory (geometry assembly, clipped rings,
/// the per-layer feature lists). A batch baker passes a per-thread arena reset
/// between tiles; `out` owns only the returned encoded bytes (pass `scratch` too
/// when the result is consumed before the next reset, e.g. gzipped immediately).
pub fn encodeTile(scratch: Allocator, out: Allocator, cells: []const CellRef, z: u8, x: u32, y: u32, format: TileFormat, pick_attrs: bool) ![]u8 {
    const a = scratch;
    const tb = tile.tileBoundsLonLat(z, x, y);
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    var mvt_surf = TileSurface.init(a, format);
    const surf = mvt_surf.asSurface();
    try surf.beginScene(z);

    for (cells) |cr| {
        const opts = CellOpts{
            .band = cr.band,
            .suppress_fills = cr.suppress_fills,
            .suppress_patterns = cr.suppress_patterns,
            .cover_clip = cr.cover_clip,
            .suppress_lines = cr.suppress_lines,
            .suppress_points = cr.suppress_points,
            .oscl = cr.oscl,
            .overscale_hatch = cr.overscale_hatch,
            .eff_scamin_floor = cr.eff_scamin_floor,
            .sounding_scamin = if (cr.sounding_scamin != 0) cr.sounding_scamin else soundingScamin(cr.cell.params.cscl),
            .pick_attrs = pick_attrs,
            .light_range_m = cr.light_range_m,
            .only_fi = cr.only_fi,
        };
        try appendCellFeatures(a, surf, &mvt_surf, opts, cr.cell, cr.portrayal, cr.portrayal_plain, cr.portrayal_simplified, cr.geo, cr.geo_world, cr.feat_bbox, z, x, y, tb, box);
    }

    return surf.endScene(out);
}

/// Append one tile's worth of every cell's features into an already-begun
/// Surface scene — the composable core of the pixel path (a view scene calls
/// this once per covering tile between beginScene/endScene). The classify()
/// legacy mode (features with NO portrayal) is tile-schema-only and skipped:
/// a pixel render always portrays.
pub fn appendTile(surf: rs.Surface, scratch: Allocator, cells: []const CellRef, z: u8, x: u32, y: u32, pick_attrs: bool) !void {
    const tb = tile.tileBoundsLonLat(z, x, y);
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);
    for (cells) |cr| {
        const opts = CellOpts{
            .band = cr.band,
            .suppress_fills = cr.suppress_fills,
            .suppress_patterns = cr.suppress_patterns,
            .cover_clip = cr.cover_clip,
            .suppress_lines = cr.suppress_lines,
            .suppress_points = cr.suppress_points,
            .oscl = cr.oscl,
            .overscale_hatch = cr.overscale_hatch,
            .eff_scamin_floor = cr.eff_scamin_floor,
            .sounding_scamin = if (cr.sounding_scamin != 0) cr.sounding_scamin else soundingScamin(cr.cell.params.cscl),
            .pick_attrs = pick_attrs,
            .light_range_m = cr.light_range_m,
            .only_fi = cr.only_fi,
        };
        try appendCellFeatures(scratch, surf, null, opts, cr.cell, cr.portrayal, cr.portrayal_plain, cr.portrayal_simplified, cr.geo, cr.geo_world, cr.feat_bbox, z, x, y, tb, box);
    }
}

/// Generate the chart scene for tile (z,x,y) onto an arbitrary render
/// Surface — the backend decides what a scene becomes (a PixelSurface makes
/// PNG/PDF; encodeTile is this plus the tile-serializing surface). Returns
/// whatever the surface's endScene produces.
pub fn generateTile(surf: rs.Surface, scratch: Allocator, out: Allocator, cells: []const CellRef, z: u8, x: u32, y: u32, pick_attrs: bool) ![]u8 {
    try surf.beginScene(z);
    try appendTile(surf, scratch, cells, z, x, y, pick_attrs);
    return surf.endScene(out);
}

/// Render a VIEW — an arbitrary centre + fractional zoom + pixel size — as
/// ONE whole scene across every covering tile: labels and declutter run over
/// the full canvas (no per-tile seams), the native win over tile compositing.
/// `ps` is any view-shaped surface (*render.pixel.PixelSurface,
/// *render.ascii.AsciiSurface): it carries w_px/h_px/px_per_tile and is
/// repositioned per covering tile via setOrigin. It must have been initView'd
/// with the same output size and a px_per_tile of
/// 256 * 2^(zoom - round(zoom)) * supersample.
pub fn generateView(ps: anytype, scratch: Allocator, out: Allocator, cells: []const CellRef, center_lon: f64, center_lat: f64, zoom: f64, pick_attrs: bool) ![]u8 {
    var vt = ViewTiles.init(center_lon, center_lat, zoom, ps.w_px, ps.h_px, ps.px_per_tile);
    const surf = ps.asSurface();
    try surf.beginScene(vt.z);
    while (vt.next()) |t| {
        ps.setOrigin(t.origin_x, t.origin_y);
        try appendTile(surf, scratch, cells, t.z, t.x, t.y, pick_attrs);
    }
    return surf.endScene(out);
}

/// The tiles covering a view (centre + fractional zoom + output px), with each
/// tile's canvas origin — shared by generateView and the lib's
/// chart-level renderView (which re-selects cells per tile).
pub const ViewTiles = struct {
    z: u8,
    pt: f64, // px per tile
    left: f64,
    top: f64,
    tx0: i64,
    tx1: i64,
    ty1: i64,
    max_t: i64,
    tx: i64,
    ty: i64,

    pub const Tile = struct { z: u8, x: u32, y: u32, origin_x: f32, origin_y: f32 };

    pub fn init(center_lon: f64, center_lat: f64, zoom: f64, w_px: u32, h_px: u32, px_per_tile: f32) ViewTiles {
        const zi: u8 = @intFromFloat(std.math.clamp(@round(zoom), 0, 22));
        const n_tiles: f64 = @floatFromInt(@as(u32, 1) << @intCast(zi));
        const pt: f64 = @floatCast(px_per_tile);
        const world = tile.lonLatToWorld(center_lon, center_lat); // [0,1] web-mercator
        const wf: f64 = @floatFromInt(w_px);
        const hf: f64 = @floatFromInt(h_px);
        const left = world[0] * n_tiles * pt - wf / 2;
        const top = world[1] * n_tiles * pt - hf / 2;
        const tx0: i64 = @intFromFloat(@floor(left / pt));
        const ty0: i64 = @intFromFloat(@floor(top / pt));
        return .{
            .z = zi,
            .pt = pt,
            .left = left,
            .top = top,
            .tx0 = tx0,
            .tx1 = @intFromFloat(@floor((left + wf - 0.001) / pt)),
            .ty1 = @intFromFloat(@floor((top + hf - 0.001) / pt)),
            .max_t = @as(i64, 1) << @intCast(zi),
            .tx = tx0,
            .ty = ty0,
        };
    }

    pub fn next(self: *ViewTiles) ?Tile {
        while (self.ty <= self.ty1) {
            const cur_tx = self.tx;
            const cur_ty = self.ty;
            self.tx += 1;
            if (self.tx > self.tx1) {
                self.tx = self.tx0;
                self.ty += 1;
            }
            // y clamps at the mercator poles; x WRAPS — longitude is cyclic, so a
            // view straddling the antimeridian fetches the far side's tiles. The
            // canvas origin keeps the UNwrapped position: the tile draws at its
            // continuous spot in the view, whichever world copy it came from.
            if (cur_ty < 0 or cur_ty >= self.max_t) continue;
            return .{
                .z = self.z,
                .x = @intCast(@mod(cur_tx, self.max_t)),
                .y = @intCast(cur_ty),
                .origin_x = @floatCast(@as(f64, @floatFromInt(cur_tx)) * self.pt - self.left),
                .origin_y = @floatCast(@as(f64, @floatFromInt(cur_ty)) * self.pt - self.top),
            };
        }
        return null;
    }
};

/// Emit one centred point symbol at the feature's anchor — its node (point), line
/// middle vertex, or area representative point (see featureAnchor) — routed to the
/// scamin bucket and carrying the feature's pick meta (class/cell/s57/scamin/band).
/// Shared by the §10.6.1.1 INFORM01 "info available" marker and the §10.1.1
/// QUESMRK1 unknown-object mark, which differ only in symbol/priority/category.
/// No-op when the anchor doesn't resolve or falls outside the raw tile bounds.
fn emitCentredSymbol(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, symbol: []const u8, prio: i64, cat: i64, z: u8, x: u32, y: u32, tb: [4]f64, opts: CellOpts, surf: rs.Surface) !void {
    const rp: ?s57.LonLat = if (f.prim == 1)
        cell.pointGeometry(f)
    else rpblk: {
        const gp = featureParts(a, cell, geo, fi, f) catch break :rpblk null;
        break :rpblk featureAnchor(a, cell, f, fi, gp);
    };
    const p = rp orelse return;
    if (p.lon() < tb[0] or p.lon() > tb[2] or p.lat() < tb[1] or p.lat() > tb[3]) return;
    const pt = tile.project(p.lon(), p.lat(), z, x, y, tile.EXTENT);
    const fmeta = rs.FeatureMeta{
        .display_priority = prio,
        .display_category = cat,
        .scamin = effScamin(f, opts),
        .class = pickClass(cell, f, fi),
        .s57_json = pickJson(a, cell, f, fi, opts.pick_attrs),
        .cell_name = if (opts.pick_attrs) cell.name else "",
        .band = opts.band,
    };
    try surf.beginFeature(&fmeta);
    try surf.drawSymbol(symbol, pt, 0, SYMBOL_SCALE, false, .point, null);
    try surf.endFeature();
}

/// Append one cell's features for tile (z,x,y), driving the Surface interface:
/// the S-101 portrayal path through processFeatureInstr, native S-52 fallbacks
/// (SWPARE / NEWOBJ / M_NSYS / INFORM01 / QUESMRK1 / SOUNDG) through their emit*
/// helpers. The only direct-list writer left is the legacy classify() mode for
/// features with NO portrayal at all — a tile-only schema that predates the
/// engine (that's why mvt_surf rides along beside surf — null for non-tile
/// surfaces, which always portray and never see classify() features).
fn appendCellFeatures(
    a: Allocator,
    surf: rs.Surface,
    mvt_surf: ?*TileSurface,
    opts: CellOpts,
    cell: *s57.Cell,
    portrayal: ?[]const ?[]const u8,
    portrayal_plain: ?[]const ?[]const u8,
    portrayal_simplified: ?[]const ?[]const u8,
    geo: ?GeoParts,
    geo_world: ?GeoWorld,
    feat_bbox: ?[]const ?[4]f64,
    z: u8,
    x: u32,
    y: u32,
    tb: [4]f64,
    box: tile.Box,
) !void {
    const mlon = (tb[2] - tb[0]) * @as(f64, @floatFromInt(tile.BUFFER)) / @as(f64, @floatFromInt(tile.EXTENT));
    const mlat = (tb[3] - tb[1]) * @as(f64, @floatFromInt(tile.BUFFER)) / @as(f64, @floatFromInt(tile.EXTENT));
    // LIGHTS cull margin: display-mm sector figures reach ~1 tile at every zoom;
    // ground-length legs (directional lights) reach their honest per-zoom span.
    const light_reach = lightReachTiles(opts.light_range_m, z, (tb[1] + tb[3]) * 0.5);
    // Sub-band SCAMIN cull: below the cell's native band floor this is a fill-up
    // tile (the compositor pulls finer data into coarser zooms where nothing
    // coarser covers), and a feature whose (floored) SCAMIN cannot display
    // anywhere in this tile is dead weight — cull it so the z4 copy of a harbor
    // cell carries land/coast/majors, not every sounding. The threshold is the
    // tile's most permissive display denominator (its highest-|lat| edge) with
    // one zoom of slack, so the cull stays strictly looser than any client
    // gate-latitude choice; SCAMIN-less features always pass.
    const subband_floor = @import("tiles").band.bandZooms(@import("tiles").band.bandOf(cell.params.cscl)).min;
    const subband_min_denom: f64 = if (z < subband_floor) blk: {
        const max_abs_lat = @max(@abs(tb[1]), @abs(tb[3]));
        const k = @import("style").scaminGateK(max_abs_lat);
        break :blk k / @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z))) / 2.0;
    } else 0;
    for (cell.features, 0..) |f, fi| {
        // Isolated single-feature render (explore --kitty thumbnail): draw only
        // the requested feature, skip the rest of the cell.
        if (opts.only_fi) |only| if (fi != only) continue;
        if (subband_min_denom > 0) {
            if (effScamin(f, opts)) |sc| {
                if (@as(f64, @floatFromInt(sc)) < subband_min_denom) continue;
            } else if (f.objl == 75) {
                // LIGHTS is the one class whose SCAMIN-less features do NOT ride
                // sub-band: producers leave SCAMIN off most fine-band lights (cell
                // selection is the intended gate — an ECDIS at this scale would
                // never load the cell), and a light's portrayal is all fixed
                // display-size construction — flare, characteristic text, 20/25 mm
                // sector legs and arcs — which reads as a continent-sized doodle
                // on a fill-up tile. The true small-scale lights arrive from the
                // overview/general cells, SCAMIN-carrying. Ground features
                // (land/coast/depth) keep riding.
                continue;
            }
        }
        var ml = mlon;
        var mt = mlat;
        if (f.objl == 75) {
            ml = @max(ml, (tb[2] - tb[0]) * light_reach);
            mt = @max(mt, (tb[3] - tb[1]) * light_reach);
        }
        if (feat_bbox) |fbb| if (fi < fbb.len) if (fbb[fi]) |b| {
            if (b[2] < tb[0] - ml or b[0] > tb[2] + ml or b[3] < tb[1] - mt or b[1] > tb[3] + mt) continue;
        };
        var fopts = opts;
        // Coverage-clipped best-available composite (point half): where a finer
        // cell's M_COVR contains this feature's position, drop its symbols/text.
        // A POINT tests its own node geometry — exact, and independent of the
        // per-feature bbox cache (the live path carries none; keying on feat_bbox
        // silently kept every coarse point copy there — the landmark dup). Its
        // augmented figures (sector arcs/legs) inherit the verdict via
        // suppress_lines. Areas are handled by the exact fill difference above;
        // line STROKES are cut exactly against the coverage (clipRunsOutsideCover /
        // clipGeoPartsOutsideCover), so a long coarse contour keeps its stretch
        // outside finer coverage and loses the stretch inside — the whole-feature
        // bbox-centre drop doubled contours (centre outside → whole line kept).
        // A line/area feature's centred label/symbol still drops by bbox centre.
        if (opts.cover_clip) |cc| if (f.prim != 3) {
            const pos: ?s57.LonLat = if (f.prim == 1)
                cell.pointGeometry(f)
            else blk: {
                if (feat_bbox) |fbb| if (fi < fbb.len) if (fbb[fi]) |b|
                    break :blk s57.LonLat.init((b[0] + b[2]) * 0.5, (b[1] + b[3]) * 0.5);
                break :blk null;
            };
            if (pos) |pg| if (coveredByFiner(cc, pg.lon(), pg.lat(), z, x, y)) {
                fopts.suppress_points = true;
                if (f.prim == 1) fopts.suppress_lines = true;
            };
        };
        if (!fopts.suppress_points and hasAdditionalInfo(f)) {
            try emitCentredSymbol(a, cell.*, f, fi, geo, "INFORM01", 8, 2, z, x, y, tb, fopts, surf);
        }
        // S-52 §10.1.10.2 overscale area at a chart scale boundary:
        // a cell's M_COVR (CATCOV=1) coverage polygon rides
        // the tile as an AP(OVERSC01) hatch gated on `oscl` (X2) ONLY when
        // overscale_hatch is set — a strictly-finer-CSCL cell rides the tile (a
        // scale boundary) AND this cell wins the pure quilt somewhere (it is the
        // displayed smaller-scale data, "must only be shown on the area compiled
        // from the smaller scale ENC"). Whole-view overscale emits no hatch (the
        // HUD readout's job, §10.1.10.1). Emitted BESIDE the feature's normal
        // portrayal (the M_COVR boundary lines still draw). The extra !suppress_fills
        // guard is redundant given overscale_hatch (win-somewhere => fills not
        // suppressed) but kept defensive so hatch and fills always co-vary.
        if (fopts.oscl > 0 and fopts.overscale_hatch and !fopts.suppress_fills and isCoverageFeature(f)) {
            try emitOverscaleHatch(a, cell.*, f, fi, geo, z, x, y, tb, box, fopts, surf);
        }
        if (f.objl == 129) {
            const smeta = rs.FeatureMeta{
                .display_priority = 18,
                .display_category = 2,
                .class = if (cell.native) pickClass(cell.*, f, fi) else "SOUNDG",
                .s57_json = pickJson(a, cell.*, f, fi, fopts.pick_attrs),
                .cell_name = if (fopts.pick_attrs) cell.name else "",
                .scamin = effScamin(f, opts),
                .band = fopts.band,
            };
            try emitSoundings(a, cell.*, f, smeta, z, x, y, tb, surf);
            continue;
        }
        if (f.objl == 163) {
            if (try symins.buildSyminsPortrayal(a, f)) |sp| {
                try processFeatureParsed(a, cell.*, f, fi, geo, geo_world, sp, 2, 2, z, x, y, tb, box, fopts, surf);
                continue;
            }
        }
        const stream: ?[]const u8 = if (portrayal) |pp| (if (fi < pp.len) pp[fi] else null) else null;
        const errored = stream != null and std.mem.startsWith(u8, stream.?, "ERROR:");
        if (stream) |s| {
            if (!errored) {
                const plain: ?[]const u8 = if (portrayal_plain) |pp| (if (fi < pp.len) pp[fi] else null) else null;
                const simplified: ?[]const u8 = if (portrayal_simplified) |pp| (if (fi < pp.len) pp[fi] else null) else null;
                try processFeatureInstr(a, cell.*, f, fi, geo, geo_world, s, plain, simplified, z, x, y, tb, box, fopts, surf);
                continue;
            }
        }
        if (f.objl == 134) {
            try emitSweptAreaFallback(a, cell.*, f, fi, geo, z, x, y, tb, box, fopts, surf);
            continue;
        }
        if (f.objl == 163) {
            try emitDashedBoundary(a, cell.*, f, fi, geo, "CHMGF", 1.5, z, x, y, tb, box, fopts, surf);
            continue;
        }
        if (f.objl == 306 and f.prim == 3) {
            try emitNavSystemFallback(a, cell.*, f, fi, geo, z, x, y, tb, box, fopts, surf);
            continue;
        }
        // "Unknown feature -> ?" fallback: only for S-57 cells, where an object class
        // with no S-101 mapping was never portrayed. A NATIVE S-101 feature always has
        // a valid class (it came from the dataset's own FTCS table); a null/empty
        // portrayal stream there means the rule ran and emitted nothing, not "unknown".
        if (!cell.native and f.objl != s57.OBJL_TOPMAR and adapter.resolveClass(f) == null) {
            if (!fopts.suppress_points) try emitCentredSymbol(a, cell.*, f, fi, geo, "QUESMRK1", 6, 1, z, x, y, tb, fopts, surf);
            continue;
        }
        if (errored) continue;
        // classify() legacy mode (no portrayal at all): tile-schema-only —
        // non-tile surfaces skip it (they always portray).
        const ms = mvt_surf orelse continue;
        const cls = classify(f.objl);
        if (cls.kind == .skip) continue;
        const geo_parts = featureParts(a, cell.*, geo, fi, f) catch continue;
        if (geo_parts.len == 0) continue;

        if (cls.kind == .area) {
            if (fopts.suppress_fills) continue;
            var rings = std.ArrayList([]const mvt.Point).empty;
            for (geo_parts) |gp| {
                if (gp.len < 2) continue;
                if (!overlaps(geomBounds(gp), tb)) continue;
                const proj = try a.alloc(mvt.Point, gp.len);
                for (gp, 0..) |p, i| proj[i] = tile.project(p.lon(), p.lat(), z, x, y, tile.EXTENT);
                const ring = try clipSimplifyPoly(a, proj, box);
                if (ring.len >= 3) try rings.append(a, ring);
            }
            if (rings.items.len == 0) continue;
            const parts = try mvt.orientAreaRings(a, rings.items);
            var aprops = std.ArrayList(mvt.Prop).empty;
            try aprops.append(a, .{ .key = "class", .value = .{ .string = cls.name } });
            try aprops.append(a, .{ .key = "color_token", .value = .{ .string = cls.color } });
            try aprops.append(a, .{ .key = "band", .value = .{ .int = fopts.band } });
            // Quantized compilation scale (overscale fill ordering — see fillArea).
            if (fopts.oscl > 0) try aprops.append(a, .{ .key = "oscl", .value = .{ .int = fopts.oscl } });
            try appendDepthVals(a, &aprops, f);
            try ms.areas.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = aprops.items });
            continue;
        }

        if (fopts.suppress_lines) continue;
        for (geo_parts) |gp| {
            if (gp.len < 2) continue;
            if (!overlaps(geomBounds(gp), tb)) continue;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (gp, 0..) |p, i| proj[i] = tile.project(p.lon(), p.lat(), z, x, y, tile.EXTENT);
            var sub = try tile.clipSimplifyLine(a, proj, box);
            if (fopts.cover_clip) |cc| sub = clipRunsOutsideCover(a, sub, cc);
            if (sub.len == 0) continue;
            const parts = try a.alloc([]const mvt.Point, sub.len);
            for (sub, 0..) |s, i| parts[i] = s;
            const lprops = try a.alloc(mvt.Prop, 3);
            lprops[0] = .{ .key = "class", .value = .{ .string = cls.name } };
            lprops[1] = .{ .key = "color_token", .value = .{ .string = cls.color } };
            lprops[2] = .{ .key = "dash", .value = .{ .string = cls.dash } };
            try ms.lines.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = lprops });
        }
    }
}

test "SNDFRM04 digit composition matches the Lua rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("SOUNDS12,SOUNDS57", try sndfrmSyms(a, "SOUNDS", 2.7, false, false, false));
    try std.testing.expectEqualStrings("SOUNDS10,SOUNDS56", try sndfrmSyms(a, "SOUNDS", 0.6, false, false, false));
    try std.testing.expectEqualStrings("SOUNDS15", try sndfrmSyms(a, "SOUNDS", 5.0, false, false, false));
    try std.testing.expectEqualStrings("SOUNDG22,SOUNDG11,SOUNDG56", try sndfrmSyms(a, "SOUNDG", 21.6, false, false, false));
    try std.testing.expectEqualStrings("SOUNDS14,SOUNDS07", try sndfrmSyms(a, "SOUNDS", 47.0, false, false, false));

    // whole_feet (the recreational feet display): 32.8 shows as WHOLE feet "32",
    // truncated down (no subscript tenth) — matching native metres >= 31 (which also
    // drops the tenth per SNDFRM04). A converted value never shows a fractional foot.
    try std.testing.expectEqualStrings("SOUNDS13,SOUNDS02", try sndfrmSyms(a, "SOUNDS", 32.8, false, false, true));
    try std.testing.expectEqualStrings("SOUNDS13,SOUNDS02", try sndfrmSyms(a, "SOUNDS", 32.8, false, false, false));

    // >= 1000 m (4-digit, codes 2,1,0,4) — previously dropped entirely.
    try std.testing.expectEqualStrings("SOUNDG21,SOUNDG12,SOUNDG03,SOUNDG44", try sndfrmSyms(a, "SOUNDG", 1234.0, false, false, false));
    try std.testing.expectEqualStrings("SOUNDG21,SOUNDG10,SOUNDG00,SOUNDG40", try sndfrmSyms(a, "SOUNDG", 1000.0, false, false, false));
    // >= 10000 m (5-digit, codes 3,2,1,0,4) — deepest oceans.
    try std.testing.expectEqualStrings("SOUNDG31,SOUNDG20,SOUNDG19,SOUNDG09,SOUNDG44", try sndfrmSyms(a, "SOUNDG", 10994.0, false, false, false));

    // Negative soundings (drying heights): A-prefix ring by sign/magnitude.
    try std.testing.expectEqualStrings("SOUNDSA3,SOUNDS21,SOUNDS12,SOUNDS53", try sndfrmSyms(a, "SOUNDS", -12.3, false, false, false));
    try std.testing.expectEqualStrings("SOUNDSA2,SOUNDS11,SOUNDS05", try sndfrmSyms(a, "SOUNDS", -15.0, false, false, false));
    try std.testing.expectEqualStrings("SOUNDSA1,SOUNDS15", try sndfrmSyms(a, "SOUNDS", -5.0, false, false, false));
    try std.testing.expectEqualStrings("SOUNDSA1,SOUNDS10,SOUNDS56", try sndfrmSyms(a, "SOUNDS", -0.6, false, false, false));

    // Quality prefixes (SNDFRM04:37-51): B1 (swept) and the low-accuracy ring lead
    // the composite, ring sized to the variant (C3 shallow / C2 deep).
    try std.testing.expectEqualStrings("SOUNDSB1,SOUNDS15", try sndfrmSyms(a, "SOUNDS", 5.0, true, false, false));
    try std.testing.expectEqualStrings("SOUNDSC3,SOUNDS15", try sndfrmSyms(a, "SOUNDS", 5.0, false, true, false));
    try std.testing.expectEqualStrings("SOUNDGC2,SOUNDG15", try sndfrmSyms(a, "SOUNDG", 5.0, false, true, false));
    // B1 then ring then A-prefix then digits, all together.
    try std.testing.expectEqualStrings("SOUNDSB1,SOUNDSC3,SOUNDSA3,SOUNDS21,SOUNDS12,SOUNDS53", try sndfrmSyms(a, "SOUNDS", -12.3, true, true, false));
}

test "appendSoundingProps: feet variant is whole feet, truncated down" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A 4.5 m obstruction: metres reads "4.5" (SOUNDS14,SOUNDS55); feet shows WHOLE
    // "14" (4.5*3.280839895 = 14.76 → floored), NOT "14.8" (nearest), "14.7" (tenth), or
    // "15" (rounded). Truncated down errs shallow = the safe direction.
    var props = std.ArrayList(mvt.Prop).empty;
    try std.testing.expect(try appendSoundingProps(a, &props, 4.5, false, false));
    var sym_s: []const u8 = "";
    var sym_s_ft: []const u8 = "";
    for (props.items) |p| {
        if (std.mem.eql(u8, p.key, "sym_s")) sym_s = p.value.string;
        if (std.mem.eql(u8, p.key, "sym_s_ft")) sym_s_ft = p.value.string;
    }
    try std.testing.expectEqualStrings("SOUNDS14,SOUNDS55", sym_s); // 4.5 m
    try std.testing.expectEqualStrings("SOUNDS11,SOUNDS04", sym_s_ft); // 14 ft (14.76 floored)
}

test "appendTextProps: LocalOffset (mm) -> loff key in text-body units (round mm/3.51)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { ox: f64, oy: f64, want: ?[]const u8 }{
        .{ .ox = 0, .oy = -3.51, .want = "0,-1" }, // PortrayFeatureName name: one body up
        .{ .ox = 3.51, .oy = 3.51, .want = "1,1" }, // down-right
        .{ .ox = 7.02, .oy = 0, .want = "2,0" }, // two bodies right
        .{ .ox = 0, .oy = 0, .want = null }, // on the pivot -> no loff prop
    };
    for (cases) |c| {
        var props = std.ArrayList(mvt.Prop).empty;
        try appendTextProps(a, &props, "x", &.{ .color = "CHBLK", .font_size = 0, .halign = "left", .valign = "bottom", .offset_x = c.ox, .offset_y = c.oy });
        var loff: ?[]const u8 = null;
        for (props.items) |p| {
            if (std.mem.eql(u8, p.key, "loff")) loff = p.value.string;
        }
        if (c.want) |w| {
            try std.testing.expect(loff != null);
            try std.testing.expectEqualStrings(w, loff.?);
        } else {
            try std.testing.expect(loff == null);
        }
    }
}

test "appendTextProps: halo (CHWHT/1) gated on font_size >= 10, matching the oracle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { fs: f64, halo: bool }{
        .{ .fs = 0, .halo = true }, // 0 -> emit default 12 -> haloed
        .{ .fs = 12, .halo = true },
        .{ .fs = 10, .halo = true }, // boundary: >= 10
        .{ .fs = 9.9, .halo = false },
        .{ .fs = 8, .halo = false },
    };
    for (cases) |c| {
        var props = std.ArrayList(mvt.Prop).empty;
        try appendTextProps(a, &props, "x", &.{ .color = "CHBLK", .font_size = c.fs, .halign = "left", .valign = "bottom" });
        var color: []const u8 = "<none>";
        var width: f64 = -1;
        for (props.items) |p| {
            if (std.mem.eql(u8, p.key, "halo_color_token")) color = p.value.string;
            if (std.mem.eql(u8, p.key, "halo_width")) width = p.value.double;
        }
        if (c.halo) {
            try std.testing.expectEqualStrings("CHWHT", color);
            try std.testing.expectEqual(@as(f64, 1), width);
        } else {
            try std.testing.expectEqualStrings("", color);
            try std.testing.expectEqual(@as(f64, 0), width);
        }
    }
}

test "stripNameTag: strips the by/bn aid-name tag, keeps the full name" {
    // The S-101 buoy/beacon rules tag OBJNAM "by <name>"/"bn <name>"; the tag is
    // stripped and the FULL name shown (the designation-shortening was removed).
    try std.testing.expectEqualStrings("Chesapeake Channel Lighted Buoy 78A", stripNameTag("by Chesapeake Channel Lighted Buoy 78A"));
    try std.testing.expectEqualStrings("Tangier Sound Daybeacon 3", stripNameTag("by Tangier Sound Daybeacon 3"));
    try std.testing.expectEqualStrings("Turn Rock Daybeacon 2", stripNameTag("bn Turn Rock Daybeacon 2"));
    try std.testing.expectEqualStrings("22", stripNameTag("by 22"));
    // No "by "/"bn " prefix -> passthrough (depth label, light elevation, place name).
    try std.testing.expectEqualStrings(" 4.6m", stripNameTag(" 4.6m"));
    try std.testing.expectEqualStrings("Herring Bay", stripNameTag("Herring Bay"));
    try std.testing.expectEqualStrings("Thomas Point Light", stripNameTag("by Thomas Point Light"));
}

test "listHasAny splits S-57 comma lists and matches any target" {
    try std.testing.expect(listHasAny("4", &.{ 4, 18 }));
    try std.testing.expect(listHasAny("6,18", &.{ 4, 18 }));
    try std.testing.expect(listHasAny(" 3 , 7 ", &.{ 3, 4, 5, 8, 9 }));
    try std.testing.expect(!listHasAny("1,2,6", &.{ 4, 18 }));
    try std.testing.expect(!listHasAny("", &.{18}));
}

fn findProp(props: []const mvt.Prop, key: []const u8) ?mvt.Value {
    for (props) |pr| if (std.mem.eql(u8, pr.key, key)) return pr.value;
    return null;
}

test "featureScamin reads s57 attr 133" {
    const with = s57.Feature{ .rcnm = 0, .rcid = 1, .prim = 1, .objl = 14, .attrs = &.{.{ .code = ATTR_SCAMIN, .value = "22000" }} };
    try std.testing.expectEqual(@as(?i64, 22000), featureScamin(with));
    const zero = s57.Feature{ .rcnm = 0, .rcid = 2, .prim = 1, .objl = 14, .attrs = &.{.{ .code = ATTR_SCAMIN, .value = "0" }} };
    try std.testing.expectEqual(@as(?i64, null), featureScamin(zero)); // 0 = "always shown", not a bucket
    const without = s57.Feature{ .rcnm = 0, .rcid = 3, .prim = 1, .objl = 14 };
    try std.testing.expectEqual(@as(?i64, null), featureScamin(without));
}

test "processFeatureInstr routes SCAMIN point to the bucket + carries display_priority/scamin" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &.{},
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(gpa),
        .edges = std.AutoHashMap(u32, usize).init(gpa),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(gpa),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer cell.deinit();
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 1, s57.LonLat.init(0, 0));

    var ms = TileSurface.init(a, .mvt);
    const surf = ms.asSurface();
    const tb = [4]f64{ -1, -1, 1, 1 };
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    // SCAMIN-carrying point -> the internal scamin bucket (folded into `point_symbols`
    // at emit), with display_priority=7 + scamin=22000.
    const f_sc = s57.Feature{
        .rcnm = 0,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &.{.{ .code = ATTR_SCAMIN, .value = "22000" }},
    };
    try processFeatureInstr(a, cell, f_sc, 0, null, null, "DrawingPriority:7;PointInstruction:BOYLAT01", null, null, 0, 0, 0, tb, box, .{}, surf);
    try std.testing.expectEqual(@as(usize, 0), ms.points.items.len);
    try std.testing.expectEqual(@as(usize, 1), ms.points_scamin.items.len);
    try std.testing.expectEqual(@as(i64, 7), findProp(ms.points_scamin.items[0].properties, "display_priority").?.int);
    try std.testing.expectEqual(@as(i64, 22000), findProp(ms.points_scamin.items[0].properties, "scamin").?.int);

    // No SCAMIN -> base point_symbols layer, display_priority default 0, no scamin.
    const f_base = s57.Feature{
        .rcnm = 0,
        .rcid = 2,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    };
    try processFeatureInstr(a, cell, f_base, 0, null, null, "PointInstruction:BOYLAT01", null, null, 0, 0, 0, tb, box, .{}, surf);
    try std.testing.expectEqual(@as(usize, 1), ms.points.items.len);
    try std.testing.expectEqual(@as(i64, 0), findProp(ms.points.items[0].properties, "display_priority").?.int);
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(ms.points.items[0].properties, "scamin"));
    // No point-style variant -> common pass: no `pts` tag (client coalesces to 2).
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(ms.points.items[0].properties, "pts"));

    // v2 schema: endScene folds the SCAMIN twin into the base, so the emitted tile
    // carries ONE merged `point_symbols` layer holding BOTH points — the folded one
    // keeps its `scamin` (22000), the base one has none. (No `point_symbols_scamin`.)
    _ = try surf.vtable.endScene(surf.ptr, a);
    try std.testing.expectEqual(@as(usize, 2), ms.points.items.len);
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(ms.points.items[0].properties, "scamin"));
    try std.testing.expectEqual(@as(i64, 22000), findProp(ms.points.items[1].properties, "scamin").?.int);
}

test "variantDiffers: absent/errored/identical = common, real change = split" {
    try std.testing.expect(!variantDiffers("PointInstruction:A", null));
    try std.testing.expect(!variantDiffers("PointInstruction:A", "ERROR: boom"));
    try std.testing.expect(!variantDiffers("PointInstruction:A", "PointInstruction:A"));
    try std.testing.expect(variantDiffers("PointInstruction:BOYLAT01", "PointInstruction:BOYLAT11"));
}

test "processFeatureInstr tags pts 0/1 when a point's simplified symbol differs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &.{},
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(gpa),
        .edges = std.AutoHashMap(u32, usize).init(gpa),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(gpa),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer cell.deinit();
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 1, s57.LonLat.init(0, 0));

    var ms = TileSurface.init(a, .mvt);
    const surf = ms.asSurface();
    const tb = [4]f64{ -1, -1, 1, 1 };
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    const f = s57.Feature{
        .rcnm = 0,
        .rcid = 1,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    };
    // Paper -> BOYLAT01; simplified -> BOYLAT11. Two passes: pts=0 then pts=1.
    try processFeatureInstr(a, cell, f, 0, null, null, "PointInstruction:BOYLAT01", null, "PointInstruction:BOYLAT11", 0, 0, 0, tb, box, .{}, surf);
    try std.testing.expectEqual(@as(usize, 2), ms.points.items.len);
    try std.testing.expectEqual(@as(i64, 0), findProp(ms.points.items[0].properties, "pts").?.int);
    try std.testing.expectEqualStrings("BOYLAT01", findProp(ms.points.items[0].properties, "symbol_name").?.string);
    try std.testing.expectEqual(@as(i64, 1), findProp(ms.points.items[1].properties, "pts").?.int);
    try std.testing.expectEqualStrings("BOYLAT11", findProp(ms.points.items[1].properties, "symbol_name").?.string);
    // Boundary axis untouched on a point: no `bnd` tag.
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(ms.points.items[0].properties, "bnd"));
}

test "processFeatureInstr tags bnd 1/0 when an area's plain boundary differs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &.{},
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(gpa),
        .edges = std.AutoHashMap(u32, usize).init(gpa),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(gpa),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer cell.deinit();
    // A square ring, pre-assembled below so processFeatureInstr skips edge resolution.
    const ring = [_]s57.LonLat{
        s57.LonLat.init(-0.5, -0.5), s57.LonLat.init(0.5, -0.5),
        s57.LonLat.init(0.5, 0.5),   s57.LonLat.init(-0.5, 0.5),
        s57.LonLat.init(-0.5, -0.5),
    };

    var ms = TileSurface.init(a, .mvt);
    const surf = ms.asSurface();
    const tb = [4]f64{ -1, -1, 1, 1 };
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    // Pre-assembled geometry for one area feature (bypasses edge resolution).
    const part = try a.dupe(s57.LonLat, &ring);
    const parts = try a.alloc([]s57.LonLat, 1);
    parts[0] = part;
    const geo_one = try a.alloc(?[][]s57.LonLat, 1);
    geo_one[0] = parts;

    const f = s57.Feature{ .rcnm = 0, .rcid = 1, .prim = 3, .objl = 42 };
    // Symbolized boundary draws a complex line; plain draws a simple stroke.
    const symbolized = "ColorFill:DEPMS;LineStyle:CTNARE51,,1,CHMGD;LineInstruction:CTNARE51";
    const plain = "ColorFill:DEPMS;LineStyle:_simple_,,1,CHMGD;LineInstruction:_simple_";
    try processFeatureInstr(a, cell, f, 0, geo_one, null, symbolized, plain, null, 0, 0, 0, tb, box, .{}, surf);
    // Both passes emit the fill: one tagged bnd=1 (symbolized), one bnd=0 (plain).
    try std.testing.expectEqual(@as(usize, 2), ms.areas.items.len);
    try std.testing.expectEqual(@as(i64, 1), findProp(ms.areas.items[0].properties, "bnd").?.int);
    try std.testing.expectEqual(@as(i64, 0), findProp(ms.areas.items[1].properties, "bnd").?.int);
    // Symbolized + plain boundary line, each tagged with its pass's bnd.
    try std.testing.expectEqual(@as(usize, 2), ms.lines.items.len);
    try std.testing.expectEqual(@as(i64, 1), findProp(ms.lines.items[0].properties, "bnd").?.int);
    try std.testing.expectEqual(@as(i64, 0), findProp(ms.lines.items[1].properties, "bnd").?.int);
}

test "generate a tile from a cell is well-formed MVT" {
    // Smoke test with an empty cell (no features) -> empty output.
    const gpa = std.testing.allocator;
    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &.{},
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(gpa),
        .edges = std.AutoHashMap(u32, usize).init(gpa),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(gpa),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer cell.deinit();
    const one = [_]CellRef{.{ .cell = &cell, .portrayal = null }};
    var tile_arena = std.heap.ArenaAllocator.init(gpa);
    defer tile_arena.deinit();
    const out = try encodeTile(tile_arena.allocator(), gpa, &one, 14, 4711, 6262, .mvt, true);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "QUASOU=5 no-bottom sounding draws the low-accuracy ring (S-65 DepthNoBottomFound)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A SOUNDG feature with QUASOU=5 is the S-65 DepthNoBottomFound case: it must draw
    // the SNDFRM04 low-accuracy ring (and, like every sounding here, no NavHazard).
    const attrs = [_]s57.Attr{.{ .code = s57.ATTR_QUASOU, .value = "5" }};
    const f = s57.Feature{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 129, .attrs = &attrs };
    const q = soundingQualityFlags(f);
    try std.testing.expect(q.low_acc);
    try std.testing.expect(!q.swept);
    // The deep (SOUNDG) glyph leads with the C2 ring; the shallow (SOUNDS) glyph with C3.
    try std.testing.expect(std.mem.startsWith(u8, try sndfrmSyms(a, "SOUNDG", 20.0, q.swept, q.low_acc, false), "SOUNDGC2"));
    try std.testing.expect(std.mem.startsWith(u8, try sndfrmSyms(a, "SOUNDS", 4.0, q.swept, q.low_acc, false), "SOUNDSC3"));

    // A normal surveyed sounding (QUASOU=1) gets no ring: the glyph starts with a digit.
    const attrs_ok = [_]s57.Attr{.{ .code = s57.ATTR_QUASOU, .value = "1" }};
    const f_ok = s57.Feature{ .rcnm = 100, .rcid = 2, .prim = 1, .objl = 129, .attrs = &attrs_ok };
    const q_ok = soundingQualityFlags(f_ok);
    try std.testing.expect(!q_ok.low_acc);
    try std.testing.expect(std.mem.startsWith(u8, try sndfrmSyms(a, "SOUNDG", 20.0, q_ok.swept, q_ok.low_acc, false), "SOUNDG"));
    try std.testing.expect(!std.mem.startsWith(u8, try sndfrmSyms(a, "SOUNDG", 20.0, q_ok.swept, q_ok.low_acc, false), "SOUNDGC2"));
}

test "DANGER01/02 on a VALSOU danger normalizes + tags danger_depth/sym_deep for the live safety-contour swap" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &.{},
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(gpa),
        .edges = std.AutoHashMap(u32, usize).init(gpa),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(gpa),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer cell.deinit();
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 1, s57.LonLat.init(0, 0));

    var ms = TileSurface.init(a, .mvt);
    const surf = ms.asSurface();
    const tb = [4]f64{ -1, -1, 1, 1 };
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    // A WRECKS point with VALSOU whose rule emitted the bake-time DANGER02 pick:
    // normalized to DANGER01 + danger_depth/sym_deep so the client swaps live.
    const f_wreck = s57.Feature{
        .rcnm = 0,
        .rcid = 1,
        .prim = 1,
        .objl = 159,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &.{.{ .code = s57.ATTR_VALSOU, .value = "15.1" }},
    };
    try processFeatureInstr(a, cell, f_wreck, 0, null, null, "DrawingPriority:12;PointInstruction:DANGER02", null, null, 0, 0, 0, tb, box, .{}, surf);
    try std.testing.expectEqual(@as(usize, 1), ms.points.items.len);
    try std.testing.expectEqualStrings("DANGER01", findProp(ms.points.items[0].properties, "symbol_name").?.string);
    try std.testing.expectEqual(@as(f64, 15.1), findProp(ms.points.items[0].properties, "danger_depth").?.double);
    try std.testing.expectEqualStrings("DANGER02", findProp(ms.points.items[0].properties, "sym_deep").?.string);

    // No VALSOU -> the baked symbol passes through untagged (nothing to swap on).
    const f_nodep = s57.Feature{
        .rcnm = 0,
        .rcid = 2,
        .prim = 1,
        .objl = 159,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    };
    try processFeatureInstr(a, cell, f_nodep, 0, null, null, "PointInstruction:DANGER01", null, null, 0, 0, 0, tb, box, .{}, surf);
    try std.testing.expectEqual(@as(usize, 2), ms.points.items.len);
    try std.testing.expectEqualStrings("DANGER01", findProp(ms.points.items[1].properties, "symbol_name").?.string);
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(ms.points.items[1].properties, "danger_depth"));

    // A non-danger class (BOYLAT) never gets tagged even with VALSOU present.
    const f_buoy = s57.Feature{
        .rcnm = 0,
        .rcid = 3,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &.{.{ .code = s57.ATTR_VALSOU, .value = "4" }},
    };
    try processFeatureInstr(a, cell, f_buoy, 0, null, null, "PointInstruction:DANGER01", null, null, 0, 0, 0, tb, box, .{}, surf);
    try std.testing.expectEqual(@as(usize, 3), ms.points.items.len);
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(ms.points.items[2].properties, "sym_deep"));
}

test {
    _ = bake_enc;
    _ = symins;
    _ = lightreach;
    _ = linestyle;
    _ = replay;
}
