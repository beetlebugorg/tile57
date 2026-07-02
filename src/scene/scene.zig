//! Direct S-57 -> MVT tile generation (M6c demo, BYPASSING S-101 portrayal).
//!
//! Generates a vector tile for (z,x,y) straight from an S-57 cell with a small
//! hardcoded object-class -> S-52 color-token mapping, so the existing chart
//! style renders it. This proves cell -> MVT -> MapLibre end to end before the
//! S-101 Lua portrayal engine lands and replaces classify() with real rules.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57");
const tile = @import("tiles").tile;
const mvt = @import("tiles").mvt;
const mlt = @import("tiles").mlt;
const render = @import("render");
const assets = @import("assets");
const rs = render.surface;

/// The banded multi-cell ENC_ROOT -> PMTiles baker (folded in: it is the
/// batch driver of this engine). Re-exported for the CLI + lib root.
pub const bake_enc = @import("bake_enc.zig");

/// SCAMIN standalone (specs/scamin-standalone.md): cross-cell point-object
/// matching + SCAMIN union + scale-window eligibility for the *_scamin point/
/// text layers. Shared by the bake pre-pass and the live per-tile dedup.
pub const scamin_pts = @import("scamin_pts.zig");

/// Output tile encoding: classic Mapbox Vector Tile, or MapLibre Tile (optional).
pub const TileFormat = enum { mvt, mlt };
const s101 = @import("s100").s101_instr;
const catalogue = @import("s100").catalogue;
const s101_adapt = @import("s100").s101_adapt;

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
// for shallow soundings (the depth-contour feet label, chartstyle.contourLabelField,
// rounds to whole feet — contour valdco values are whole metres).
const M_TO_FT: f64 = @import("render").sndfrm.M_TO_FT;

// Worst-case reach of a light's sector legs/arcs (emitAugFigures) as a fraction of a
// tile — these are drawn at a fixed DISPLAY size (radius/length in mm), so the reach
// is ~constant in tile units at every zoom (offset_tiles = mm * PX_PER_MM / 256).
// Used to widen the LIGHTS spatial-cull margin so an arc isn't dropped on the tiles it
// crosses (S-52 legs ~25 mm / arcs ~20 mm ≈ 0.8 tile; 1.0 leaves headroom).
const LIGHT_AUG_REACH_TILES: f64 = 1.0;

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
/// (Mirrors s101_adapt.hasListVal; S-57 list attributes are comma-joined.)
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
/// feet value is a CONVERSION, so it keeps its tenth at every magnitude (`always_tenths`)
/// — we never round a conversion to a whole number. A 4.5 m obstruction reads "14.8"
/// (ft); a 10 m one reads "32.8" (ft), not "32".
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

// Clip a line + simplify each kept run (drop runs that collapse below 2 vertices).
fn clipSimplifyLine(a: Allocator, proj: []const mvt.Point, box: tile.Box) ![]const []const mvt.Point {
    const sub = try tile.clipLine(a, proj, box);
    var out = std.ArrayList([]const mvt.Point).empty;
    for (sub) |run| {
        const s = try tile.simplifyRing(a, run);
        if (s.len >= 2) try out.append(a, s);
    }
    return out.items;
}

/// Shoelace signed area (x2) of a ring in tile space; only its sign is used.
/// y is down, so a positive value is a clockwise (exterior) ring per the MVT spec.
fn ringSignedArea(ring: []const mvt.Point) i64 {
    if (ring.len < 3) return 0;
    var area: i64 = 0;
    var j: usize = ring.len - 1;
    for (ring, 0..) |p, i| {
        const q = ring[j];
        area += @as(i64, q.x) * @as(i64, p.y) - @as(i64, p.x) * @as(i64, q.y);
        j = i;
    }
    return area;
}

/// Even-odd ray test: is tile-space point `pt` inside `ring`?
fn ringContains(ring: []const mvt.Point, pt: mvt.Point) bool {
    if (ring.len < 3) return false;
    var inside = false;
    const px: f64 = @floatFromInt(pt.x);
    const py: f64 = @floatFromInt(pt.y);
    var j: usize = ring.len - 1;
    for (ring, 0..) |p, i| {
        const q = ring[j];
        const ax: f64 = @floatFromInt(p.x);
        const ay: f64 = @floatFromInt(p.y);
        const bx: f64 = @floatFromInt(q.x);
        const by: f64 = @floatFromInt(q.y);
        if ((ay > py) != (by > py) and
            px < (bx - ax) * (py - ay) / (by - ay) + ax)
        {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Orient + order a feature's clipped area rings into MVT multipolygon parts so
/// holes are SUBTRACTED instead of filled (e.g. an island inside a sea/depth
/// area). Mirrors the Go reference encodePolygon: classify each ring by geometric
/// nesting depth (even = exterior, odd = hole), force exteriors to a positive
/// signed area (clockwise in y-down tile space) and holes to negative, and emit
/// each exterior immediately followed by the holes it directly contains. This is
/// independent of the FSPT USAG tags, and keeps disjoint multi-part areas
/// (multiple exteriors) working as a proper multipolygon. `rings` are the clipped
/// rings (open, >= 3 pts); returned parts may reverse a ring into a fresh copy.
fn orientAreaRings(a: Allocator, rings: []const []const mvt.Point) ![]const []const mvt.Point {
    const n = rings.len;
    const depth = try a.alloc(usize, n);
    for (rings, 0..) |ri, i| {
        var d: usize = 0;
        for (rings, 0..) |rj, j| {
            if (i != j and ringContains(rj, ri[0])) d += 1;
        }
        depth[i] = d;
    }

    const done = try a.alloc(bool, n);
    @memset(done, false);
    var out = std.ArrayList([]const mvt.Point).empty;

    const emit = struct {
        fn one(al: Allocator, list: *std.ArrayList([]const mvt.Point), ring: []const mvt.Point, d: usize) !void {
            const want_pos = (d % 2) == 0; // even depth = exterior (positive), odd = hole
            if ((ringSignedArea(ring) >= 0) == want_pos) {
                try list.append(al, ring);
            } else {
                const rev = try al.alloc(mvt.Point, ring.len);
                for (ring, 0..) |p, k| rev[ring.len - 1 - k] = p;
                try list.append(al, rev);
            }
        }
    }.one;

    // Each exterior (even depth) followed by the holes it directly contains, so a
    // decoder attaches each hole to the right exterior (depth exactly +1, inside).
    for (0..n) |i| {
        if (done[i] or depth[i] % 2 != 0) continue;
        done[i] = true;
        try emit(a, &out, rings[i], depth[i]);
        for (0..n) |k| {
            if (done[k] or depth[k] != depth[i] + 1) continue;
            if (ringContains(rings[i], rings[k][0])) {
                done[k] = true;
                try emit(a, &out, rings[k], depth[k]);
            }
        }
    }
    // Safety net: emit anything not placed (malformed nesting) on its own.
    for (0..n) |i| {
        if (done[i]) continue;
        done[i] = true;
        try emit(a, &out, rings[i], depth[i]);
    }
    return out.items;
}

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
    /// Band-handoff carry-down (scamin-aware quilting): this coarser cell rides in a
    /// tile whose display window opens coarser than the covering finer cell's
    /// compilation scale, so instead of being suppressed its features are tagged with
    /// the handoff denominator — the `smax` tile property the style gates on (hide
    /// once the display is finer than 1:smax). 0 = not carried (no tag emitted).
    smax: i64 = 0,
    /// The cell's compilation-scale denominator quantized UP the scamin ladder
    /// (bake_enc.quantizeHandoff over the participating cells' ladders, so the
    /// client's crossing machinery fires exactly at the emitted value); 0 = unknown.
    /// Tagged as the `oscl` tile property on area fills + patterns, and emitted as
    /// the AP(OVERSC01) overscale hatch's gate (S-52 §10.1.10: hatch shows while
    /// the display is FINER than 1:oscl). See emitOverscaleHatch.
    oscl: i64 = 0,
    /// Emit the per-feature pick-report attributes (the `s57` blob + `cell` name) for
    /// the S-52 §10.8 cursor pick + dev inspector. Defaults ON (host wants a working
    /// pick report in the local-first deployment); a lean bake can turn it off via the
    /// C ABI to drop the bulky `s57` payload. See encodeS57Attrs.
    pick_attrs: bool = true,
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
    // display below the feature's 1:N scale (see ATTR_SCAMIN / assets/style.zig).
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
    cur: Meta = .{ .prio = 0 },

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
            .prio = meta.draw_prio,
            .cat = meta.cat,
            .vg = meta.vg,
            .scamin = meta.scamin,
            .smax = meta.smax,
            .oscl = meta.oscl,
            .class = meta.class,
            .s57 = meta.s57_json,
            .cell = meta.cell_name,
            .band = meta.band,
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
        // occludes a coarser cell's OVERSC01 hatch (specs/overscale.md).
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

    fn drawText(ctx: *anyopaque, text: []const u8, style: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const s = sp(ctx);
        var props = std.ArrayList(mvt.Prop).empty;
        try appendTextProps(s.a, &props, text, style); // text already shortened by engine
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
        var layers = std.ArrayList(mvt.Layer).empty;
        if (s.areas.items.len > 0) try layers.append(s.a, .{ .name = "areas", .features = s.areas.items });
        if (s.areas_scamin.items.len > 0) try layers.append(s.a, .{ .name = "areas_scamin", .features = s.areas_scamin.items });
        if (s.area_patterns.items.len > 0) try layers.append(s.a, .{ .name = "area_patterns", .features = s.area_patterns.items });
        if (s.area_patterns_scamin.items.len > 0) try layers.append(s.a, .{ .name = "area_patterns_scamin", .features = s.area_patterns_scamin.items });
        if (s.lines.items.len > 0) try layers.append(s.a, .{ .name = "lines", .features = s.lines.items });
        if (s.lines_scamin.items.len > 0) try layers.append(s.a, .{ .name = "lines_scamin", .features = s.lines_scamin.items });
        if (s.points.items.len > 0) try layers.append(s.a, .{ .name = "point_symbols", .features = s.points.items });
        if (s.points_scamin.items.len > 0) try layers.append(s.a, .{ .name = "point_symbols_scamin", .features = s.points_scamin.items });
        if (s.soundings.items.len > 0) try layers.append(s.a, .{ .name = "soundings", .features = s.soundings.items });
        if (s.texts.items.len > 0) try layers.append(s.a, .{ .name = "text", .features = s.texts.items });
        if (s.texts_scamin.items.len > 0) try layers.append(s.a, .{ .name = "text_scamin", .features = s.texts_scamin.items });
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

/// The vector layers this engine emits, in emit order — the source-layer ids the
/// generated MapLibre style reads. Static: an archive may omit empties, but the
/// TileJSON advertises the full set (mirrors the Go pmtiles metadataJSON, with this
/// engine's actual layer split — points/text get _scamin buckets, complex lines fold
/// into `lines`). Keep in sync with the layer appends in appendCellFeatures' finalize.
pub const VECTOR_LAYERS = [_][]const u8{
    "areas",     "areas_scamin", "area_patterns", "area_patterns_scamin",
    "lines",     "lines_scamin", "point_symbols", "point_symbols_scamin",
    "soundings", "text",         "text_scamin",
};

/// PMTiles archive metadata JSON: the static vector_layers list MapLibre reads from
/// the TileJSON, plus a "scamin" array of the distinct SCAMIN denominators present
/// (ascending) so the client builds one native-minzoom bucket layer per value at
/// load (host-canonical-backend.md §2) instead of probing tiles. Mirrors the Go
/// pmtiles.Builder.metadata (vector_layers + scamin splice). `scamin` empty -> omit
/// the field. Caller owns the returned bytes (allocated in `a`).
pub fn metadataJson(a: Allocator, scamin: []const u32) ![]const u8 {
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
    try b.append(a, '}');
    return b.toOwnedSlice(a);
}

/// Feature-level metadata shared by every primitive a feature emits, so the
/// client's S-52 mariner filters can select on it.
const Meta = struct {
    prio: i64,
    cat: i64 = 1, // display-category rank (0 base, 1 standard, 2 other)
    vg: i64 = 0, // raw S-101 viewing-group number of the feature's primary draw (0 = none)
    scamin: ?i64 = null,
    // Band-handoff carry-down tag: the handoff denominator a carried coarser-band
    // feature hides beyond (the style's smax gate). 0 = not carried (omitted).
    smax: i64 = 0,
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
/// Case-insensitive last occurrence of `needle` in `haystack`.
fn lastIndexOfCI(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = haystack.len - needle.len + 1;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Reduce a buoy/lighted-buoy name label to its chart designation. The S-101 buoy
/// rules tag the feature "by <OBJNAM>" (EncodeString 'by %s'); NOAA OBJNAM is the full
/// descriptive name ("Chesapeake Channel Lighted Buoy 78A") but a chart shows only the
/// trailing designation ("78A"), which also de-clutters a channel of buoys whose long
/// prefix repeats. The "by " prefix marks these name labels; all other text (depth
/// labels, light elevations, …) has no such prefix and passes through unchanged. The
/// designation is whatever follows the LAST buoy/beacon type-word; "Light"/"Lt" are
/// deliberately excluded so a named light keeps its name, and a name with no type-word
/// keeps its stripped form (e.g. a bare "22").
///
/// An extracted designation is QUOTED ("78A") like the paper chart: an aid's
/// designation in quotes cannot be misread as a sounding or a depth — the
/// chart convention exists for exactly that reason. Unshortened text passes
/// through borrowed; a quoted designation allocates from `a`.
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

fn shortenName(a: Allocator, text: []const u8) ![]const u8 {
    // "by " = buoy names, "bn " = beacon names (EncodeString prefixes in the
    // buoy/beacon rules); both reduce to the designation.
    const tagged = std.mem.startsWith(u8, text, "by ") or std.mem.startsWith(u8, text, "bn ");
    if (!tagged) return text;
    const name = std.mem.trim(u8, text[3..], " ");
    const keywords = [_][]const u8{ "Daybeacon", "Daymark", "Buoy", "Beacon" };
    var best_end: ?usize = null;
    for (keywords) |kw| {
        if (lastIndexOfCI(name, kw)) |idx| {
            const end = idx + kw.len;
            if (best_end == null or end > best_end.?) best_end = end;
        }
    }
    if (best_end) |end| {
        const rest = std.mem.trim(u8, name[end..], " ");
        if (rest.len > 0) return std.fmt.allocPrint(a, "\"{s}\"", .{rest});
    }
    return name;
}

/// Serialize a text label's props in the tile schema order. `text` arrives already
/// shortened/resolved by the engine. A minimal label (empty halign — see
/// rs.TextStyle) carries only text/color/size, as the native fallbacks always did.
fn appendTextProps(a: Allocator, props: *std.ArrayList(mvt.Prop), text: []const u8, style: *const rs.TextStyle) !void {
    // Resolved body size: the FontSize modifier px, or 12 (oracle default). Drives
    // both the emitted font_size_px and the halo gate below.
    const font_px: f64 = if (style.font_size > 0) style.font_size else 12;
    try props.append(a, .{ .key = "text", .value = .{ .string = text } });
    try props.append(a, .{ .key = "color_token", .value = .{ .string = style.color } });
    try props.append(a, .{ .key = "font_size_px", .value = .{ .double = font_px } });
    if (style.halign.len == 0) return; // minimal label: no alignment/halo/group spec
    try props.append(a, .{ .key = "halign", .value = .{ .string = style.halign } });
    try props.append(a, .{ .key = "valign", .value = .{ .string = style.valign } });
    // S-101 LocalOffset -> label-offset key in text-body units (3.51 mm = one text
    // body height = 1 em): the style's text-offset match keys on "ux,uy" to shift a
    // name clear of its symbol (PortrayFeatureName emits 0,-3.51 = one body up).
    // Only emit when non-zero (most labels sit on their pivot). Sign is S-52 +x
    // right / +y down, which matches MapLibre's text-offset.
    {
        const TEXT_BODY_MM = 3.51;
        const ux: i64 = @intFromFloat(@round(style.offset_x / TEXT_BODY_MM));
        const uy: i64 = @intFromFloat(@round(style.offset_y / TEXT_BODY_MM));
        if (ux != 0 or uy != 0)
            try props.append(a, .{ .key = "loff", .value = .{ .string = try std.fmt.allocPrint(a, "{d},{d}", .{ ux, uy }) } });
    }
    // §10 text halo: the oracle attaches a CHWHT, 1px halo to text >= 10 px
    // (s101emit.go:130-133) and emits it as halo_color_token / halo_width tile
    // properties (bake.go:1147-1148); smaller text gets no halo ("" / 0). Our served
    // style still renders text solid (no halo) by deliberate S-52 choice (style.zig
    // textPaint passes halo_width 0) — these are tile-parity properties for a client
    // that wants the legibility halo.
    const haloed = font_px >= 10;
    try props.append(a, .{ .key = "halo_color_token", .value = .{ .string = if (haloed) "CHWHT" else "" } });
    try props.append(a, .{ .key = "halo_width", .value = .{ .double = if (haloed) 1 else 0 } });
    try props.append(a, .{ .key = "tgrp", .value = .{ .int = style.group } });
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
    try props.append(a, .{ .key = "draw_prio", .value = .{ .int = m.prio } });
    try props.append(a, .{ .key = "cat", .value = .{ .int = m.cat } });
    // Raw viewing group (§14.5): emitted only when the feature has a banded draw VG,
    // so undated/unbanded features keep their tile footprint unchanged.
    if (m.vg != 0) try props.append(a, .{ .key = "vg", .value = .{ .int = m.vg } });
    try props.append(a, .{ .key = "band", .value = .{ .int = m.band } });
    if (m.class.len > 0) try props.append(a, .{ .key = "class", .value = .{ .string = m.class } });
    if (m.s57.len > 0) try props.append(a, .{ .key = "s57", .value = .{ .string = m.s57 } });
    if (m.cell.len > 0) try props.append(a, .{ .key = "cell", .value = .{ .string = m.cell } });
    if (m.scamin) |sc| try props.append(a, .{ .key = "scamin", .value = .{ .int = sc } });
    // Band-handoff carry-down: only a carried coarser-band copy is tagged (see
    // CellOpts.smax) — untagged features keep their tile footprint unchanged and
    // pass the style's smax gate via its coalesce-0 fallback.
    if (m.smax > 0) try props.append(a, .{ .key = "smax", .value = .{ .int = m.smax } });
    // bnd/pts are emitted only for the style-variant passes (0/1); the common case
    // (2) is left off so the client coalesces to 2 (always shown) — keeping every
    // unvarying feature's tile footprint unchanged.
    if (m.bnd != 2) try props.append(a, .{ .key = "bnd", .value = .{ .int = m.bnd } });
    if (m.pts != 2) try props.append(a, .{ .key = "pts", .value = .{ .int = m.pts } });
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
/// dominates the bake. ONLY area/line features whose portrayal draws a label or centred
/// symbol (Text/PointInstruction) ever consult labelPoint, so cache only those — running
/// the search for every other area would cost more than the per-tile recompute it saves.
/// A null slot (unlabelled, or `streams==null`) makes labelPoint fall back to a live
/// search, so the cached point is byte-identical either way. `streams` is the per-feature
/// base instruction stream (parallel to cell.features); null = cache nothing.
pub fn buildLabelCache(a: Allocator, cell: *const s57.Cell, geo: ?GeoParts, streams: ?[]const ?[]const u8) ![]?s57.LonLat {
    const out = try a.alloc(?s57.LonLat, cell.features.len);
    @memset(out, null);
    const ss = streams orelse return out;
    var tmp = std.heap.ArenaAllocator.init(a);
    defer tmp.deinit();
    for (cell.features, 0..) |f, i| {
        if (f.prim != 2 and f.prim != 3) continue;
        if (i >= ss.len) break;
        const s = ss[i] orelse continue;
        if (std.mem.indexOf(u8, s, "TextInstruction") == null and std.mem.indexOf(u8, s, "PointInstruction") == null) continue;
        const parts = featureParts(tmp.allocator(), cell.*, geo, i, f) catch continue;
        out[i] = s57.areaRepresentativePoint(tmp.allocator(), parts);
        _ = tmp.reset(.retain_capacity);
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
    const base = try s101.parse(a, instr);
    if (f.prim == 1) {
        if (variantDiffers(instr, simplified)) {
            try processFeatureParsed(a, cell, f, fi, geo, geo_world, base, 2, 0, z, x, y, tb, box, opts, surf);
            const sp2 = try s101.parse(a, simplified.?);
            try processFeatureParsed(a, cell, f, fi, geo, geo_world, sp2, 2, 1, z, x, y, tb, box, opts, surf);
        } else {
            try processFeatureParsed(a, cell, f, fi, geo, geo_world, base, 2, 2, z, x, y, tb, box, opts, surf);
        }
        return;
    }
    if (f.prim == 3 and variantDiffers(instr, plain)) {
        try processFeatureParsed(a, cell, f, fi, geo, geo_world, base, 1, 2, z, x, y, tb, box, opts, surf);
        const pl = try s101.parse(a, plain.?);
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
fn emitAugFigures(a: Allocator, figs: []const s101.AugFigure, anchor: s57.LonLat, fmeta: rs.FeatureMeta, z: u8, x: u32, y: u32, box: tile.Box, surf: rs.Surface) !void {
    if (figs.len == 0) return;
    const world_px = 256.0 * @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    const pxmm = s101.PX_PER_MM;
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
/// every primitive with the pass's meta (draw_prio/cat/vg/scamin/bnd/pts + pick
/// attrs). The engine work happens here — geometry assembly, projection, tile
/// clipping/simplification, anchoring — so surfaces only ever see draw calls.
fn processFeatureParsed(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, geo_world: ?GeoWorld, p: s101.Portrayal, bnd: i64, pts: i64, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, opts: CellOpts, surf: rs.Surface) !void {
    const scamin = featureScamin(f);
    const s57_json = if (opts.pick_attrs) try encodeS57Attrs(a, f) else "";
    const cell_name = if (opts.pick_attrs) cell.name else "";
    const fmeta = rs.FeatureMeta{
        .draw_prio = p.draw_prio,
        .cat = p.cat,
        .vg = p.vg,
        .scamin = scamin,
        .smax = opts.smax,
        .oscl = opts.oscl,
        .class = catalogue.acronymByObjl(f.objl) orelse "",
        .s57_json = s57_json,
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
                const style = rs.TextStyle{
                    .color = t.color,
                    .font_size = t.font_size,
                    .halign = t.halign,
                    .valign = t.valign,
                    .offset_x = t.offset_x,
                    .offset_y = t.offset_y,
                    .group = t.group,
                };
                try surf.beginFeature(&fmeta);
                try surf.drawText(try expandSeabedText(a, fmeta.class, try shortenName(a, t.text)), &style, pt);
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
        if (rings.items.len > 0) {
            const rparts = try orientAreaRings(a, rings.items);
            const dv = depthVals(f);
            const dr: ?rs.DepthRange = if (dv) |d| .{ .d1 = d[0], .d2 = d[1] } else null;
            if (!opts.suppress_fills) if (p.fill_token) |token| {
                try surf.beginFeature(&fmeta);
                try surf.fillArea(token, rparts, dr);
                try surf.endFeature();
            };
            if (!opts.suppress_patterns) for (p.patterns) |pat| {
                try surf.beginFeature(&fmeta);
                try surf.fillPattern(pat, rparts);
                try surf.endFeature();
            };
        }
    }

    const valdco: ?f64 = if (f.objl == 43) f.attrFloat(s57.ATTR_VALDCO) else null;

    var stroke_geo: []const []s57.LonLat = geo_parts;
    var stroke_proj: []const []mvt.Point = projected.items;
    if (!opts.suppress_lines and p.lines.len > 0 and cell.needsDrawableBoundary(f)) {
        var stroke_storage = std.ArrayList([]mvt.Point).empty;
        const dparts = cell.drawableLineParts(a, f) catch &[_][]s57.LonLat{};
        stroke_geo = dparts;
        for (dparts) |dp| {
            if (dp.len < 2) continue;
            if (!overlaps(geomBounds(dp), tb)) continue;
            const proj = try a.alloc(mvt.Point, dp.len);
            for (dp, 0..) |p2, i| proj[i] = tile.project(p2.lon(), p2.lat(), z, x, y, tile.EXTENT);
            try stroke_storage.append(a, proj);
        }
        stroke_proj = stroke_storage.items;
    }

    const force_dash = !quaposSolidClass(f.objl) and s57.isLowAccuracyQuapos(cell.featureQuapos(f));

    if (!opts.suppress_lines) for (p.lines) |ln| {
        if (!std.mem.eql(u8, ln.style, "solid")) {
            if (g_linestyles.get(ln.style)) |info| {
                // Complex linestyle: tessellated dash runs + tangent-rotated symbols.
                try emitComplexLine(a, stroke_geo, info, ln.color, !opts.suppress_points, z, x, y, box, &fmeta, surf);
                continue;
            }
        }
        const dash_str: []const u8 = if (std.mem.eql(u8, ln.style, "solid"))
            (if (force_dash) "dashed" else "solid")
        else
            "dashed";
        const dash: rs.Dash = if (std.mem.eql(u8, dash_str, "solid")) .solid else .dashed;
        for (stroke_proj) |proj| {
            const sub = try clipSimplifyLine(a, proj, box);
            if (sub.len == 0) continue;
            const seg_parts = try a.alloc([]const mvt.Point, sub.len);
            for (sub, 0..) |seg, i| seg_parts[i] = seg;
            try surf.beginFeature(&fmeta);
            try surf.strokeLine(ln.color, ln.width, dash, seg_parts, valdco);
            try surf.endFeature();
        }
    };

    if (!opts.suppress_points and p.texts.len > 0) {
        if (featureAnchor(a, cell, f, fi, geo_parts)) |rp| {
            if (rp.lon() >= tb[0] and rp.lon() <= tb[2] and rp.lat() >= tb[1] and rp.lat() <= tb[3]) {
                const cpt = tile.project(rp.lon(), rp.lat(), z, x, y, tile.EXTENT);
                for (p.texts) |t| {
                    const style = rs.TextStyle{
                        .color = t.color,
                        .font_size = t.font_size,
                        .halign = t.halign,
                        .valign = t.valign,
                        .offset_x = t.offset_x,
                        .offset_y = t.offset_y,
                        .group = t.group,
                    };
                    try surf.beginFeature(&fmeta);
                    try surf.drawText(try expandSeabedText(a, fmeta.class, try shortenName(a, t.text)), &style, cpt);
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

// === SYMINS02 native fallback (S-52 PresLib §13.2.18 / §10.3.3.8) ===========
// Portray an S-57 NEWOBJ from its producer SYMINS attribute (code 192): a
// ';'-separated list of S-52 draw ops — SY()/TX()/TE()/LS()/LC()/AC()/AP() —
// rendered verbatim instead of the S-101 V-AIS alias the FeatureCatalogue maps
// NEWOBJ to. This is how the S-52 PresLib "ECDIS Chart 1" labels/boundaries/fills
// are drawn. Mirrors Go parseSYMINS (internal/engine/portrayal/symins.go).

const SYMINS_ATTR: u16 = 192;

fn syminsTrimQuotes(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, "'\"");
}

fn syminsArgAt(args: []const []const u8, i: usize) []const u8 {
    return if (i < args.len) args[i] else "";
}

/// The S-57 attribute value referenced by acronym (e.g. "OBJNAM"), trimmed, or null
/// when absent/blank. Mirrors Go lookupAttributeText over the feature's attrs.
fn syminsFeatAttr(f: s57.Feature, acr: []const u8) ?[]const u8 {
    for (f.attrs) |at| {
        const a2 = catalogue.attrAcronym(at.code) orelse continue;
        if (std.ascii.eqlIgnoreCase(a2, acr)) {
            const v = std.mem.trim(u8, at.value, " ");
            return if (v.len == 0) null else v;
        }
    }
    return null;
}

/// Split a SYMINS string on ';', honouring quotes and nested parens (so a ';' inside
/// TX('a;b',…) or between parens isn't a split). Returns slices into `s`.
fn syminsSplitInstructions(a: Allocator, s: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var depth: i32 = 0;
    var in_quote = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\'', '"' => in_quote = !in_quote,
            '(' => if (!in_quote) {
                depth += 1;
            },
            ')' => if (!in_quote) {
                depth -= 1;
            },
            ';' => if (!in_quote and depth == 0) {
                try out.append(a, s[start..i]);
                start = i + 1;
            },
            else => {},
        }
    }
    if (start < s.len) try out.append(a, s[start..]);
    return out.items;
}

/// Split "OP(params)" into the op and inner params, or null when malformed.
fn syminsSplitOp(instr0: []const u8) ?struct { op: []const u8, params: []const u8 } {
    const instr = std.mem.trim(u8, instr0, " \t");
    const open = std.mem.indexOfScalar(u8, instr, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, instr, ')') orelse return null;
    if (open == 0 or close < open) return null;
    return .{ .op = std.mem.trim(u8, instr[0..open], " \t"), .params = instr[open + 1 .. close] };
}

/// Split an instruction's params on ',', honouring quotes. Returns trimmed slices.
fn syminsSplitArgs(a: Allocator, params: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var in_quote = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const c = params[i];
        if (c == '\'' or c == '"') {
            in_quote = !in_quote;
        } else if (c == ',' and !in_quote) {
            try out.append(a, std.mem.trim(u8, params[start..i], " \t"));
            start = i + 1;
        }
    }
    try out.append(a, std.mem.trim(u8, params[start..], " \t"));
    return out.items;
}

/// printf-style format substitution for a SYMINS TE() instruction (S-52 §3.2.3.2):
/// each %-spec consumes the next attribute name and formats its value (floats honour
/// .precision; integer convs round; the '0' flag + width zero-pad). Mirrors Go
/// formatSubstitute + appendConverted + zeroPad. Returns null when an attribute is
/// missing (the whole label is then dropped, as in Go).
fn syminsZeroPad(a: Allocator, out: *std.ArrayList(u8), s: []const u8, width: usize, flags: []const u8) !void {
    const has0 = std.mem.indexOfScalar(u8, flags, '0') != null;
    const has_minus = std.mem.indexOfScalar(u8, flags, '-') != null;
    if (width <= s.len or !has0 or has_minus) {
        try out.appendSlice(a, s);
        return;
    }
    const pad = width - s.len;
    const signed = s.len > 0 and (s[0] == '-' or s[0] == '+' or s[0] == ' ');
    if (signed) try out.append(a, s[0]);
    var k: usize = 0;
    while (k < pad) : (k += 1) try out.append(a, '0');
    try out.appendSlice(a, if (signed) s[1..] else s);
}

fn syminsAppendConverted(a: Allocator, out: *std.ArrayList(u8), val: []const u8, conv: u8, precision: i32, width: usize, flags: []const u8) !void {
    var buf: [512]u8 = undefined;
    var s: []const u8 = val;
    switch (conv) {
        'f', 'e', 'g' => {
            if (std.fmt.parseFloat(f64, std.mem.trim(u8, val, " \t"))) |x| {
                s = std.fmt.float.render(&buf, x, .{
                    .mode = .decimal,
                    .precision = if (precision >= 0) @as(usize, @intCast(precision)) else null,
                }) catch val;
            } else |_| {}
        },
        'd', 'i', 'u', 'x' => {
            if (std.fmt.parseFloat(f64, std.mem.trim(u8, val, " \t"))) |x| {
                const r: i64 = @intFromFloat(@round(x));
                s = std.fmt.bufPrint(&buf, "{d}", .{r}) catch val;
            } else |_| {}
        },
        else => {},
    }
    try syminsZeroPad(a, out, s, width, flags);
}

fn syminsFormatSubstitute(a: Allocator, f: s57.Feature, format: []const u8, names: []const []const u8) !?[]const u8 {
    var out = std.ArrayList(u8).empty;
    var attr_idx: usize = 0;
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] != '%' or i + 1 >= format.len) {
            try out.append(a, format[i]);
            i += 1;
            continue;
        }
        if (format[i + 1] == '%') {
            try out.append(a, '%');
            i += 2;
            continue;
        }
        var j = i + 1;
        const flags_start = j;
        while (j < format.len and std.mem.indexOfScalar(u8, "-+ #0", format[j]) != null) j += 1;
        const flags = format[flags_start..j];
        var width: usize = 0;
        while (j < format.len and format[j] >= '0' and format[j] <= '9') : (j += 1) width = width * 10 + (format[j] - '0');
        var precision: i32 = -1;
        if (j < format.len and format[j] == '.') {
            j += 1;
            var p: i32 = 0;
            while (j < format.len and format[j] >= '0' and format[j] <= '9') : (j += 1) p = p * 10 + @as(i32, format[j] - '0');
            precision = p;
        }
        while (j < format.len and (format[j] == 'l' or format[j] == 'h' or format[j] == 'L')) j += 1;
        if (j >= format.len) {
            try out.appendSlice(a, format[i..]); // malformed trailing spec -> literal
            break;
        }
        const conv = format[j];
        switch (conv) {
            's', 'c', 'd', 'i', 'u', 'x', 'f', 'e', 'g' => {
                if (attr_idx >= names.len) return null;
                const acr = names[attr_idx];
                attr_idx += 1;
                const val = syminsFeatAttr(f, acr) orelse return null;
                try syminsAppendConverted(a, &out, val, conv, precision, width, flags);
            },
            else => try out.appendSlice(a, format[i .. j + 1]), // unknown conversion -> literal
        }
        i = j + 1;
    }
    return out.items;
}

/// Parse a SYMINS TX()/TE() instruction into a Text. The Text model carries the
/// label string, colour and viewing group; the S-52 justification / offset / font /
/// halo fields are dropped (tracked OpText findings), matching the current text path.
fn syminsText(a: Allocator, f: s57.Feature, op: []const u8, params: []const u8) !?s101.Text {
    const args = try syminsSplitArgs(a, params);
    var text: []const u8 = "";
    var color_idx: usize = undefined;
    var display_idx: usize = undefined;
    if (std.mem.eql(u8, op, "TE")) {
        if (args.len < 10) return null;
        var names = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, syminsTrimQuotes(args[1]), ',');
        while (it.next()) |nm| {
            const t = std.mem.trim(u8, nm, " \t");
            if (t.len > 0) try names.append(a, t);
        }
        text = (try syminsFormatSubstitute(a, f, syminsTrimQuotes(args[0]), names.items)) orelse return null;
        color_idx = 8;
        display_idx = 9;
    } else { // TX
        if (args.len < 9) return null;
        const raw = args[0];
        if (raw.len > 0 and (raw[0] == '\'' or raw[0] == '"')) {
            text = syminsTrimQuotes(raw); // literal
        } else {
            text = syminsFeatAttr(f, std.mem.trim(u8, raw, " \t")) orelse return null;
        }
        color_idx = 7;
        display_idx = 8;
    }
    if (text.len == 0) return null;
    var color = std.mem.trim(u8, syminsArgAt(args, color_idx), " \t");
    if (color.len == 0) color = "CHBLK";
    const group = std.fmt.parseInt(i64, std.mem.trim(u8, syminsArgAt(args, display_idx), " \t"), 10) catch 0;
    return s101.Text{ .text = text, .color = color, .group = group };
}

/// Build an S-101 Portrayal from a NEWOBJ's SYMINS attribute, or null when there is
/// no usable SYMINS (caller then falls back to the default new-object symbology).
/// Geometry/anchoring/clipping is handled by processFeatureParsed exactly like a rule stream.
fn buildSyminsPortrayal(a: Allocator, f: s57.Feature) !?s101.Portrayal {
    const raw0 = f.attr(SYMINS_ATTR) orelse return null;
    const raw = std.mem.trim(u8, raw0, " ");
    if (raw.len == 0) return null;

    var points = std.ArrayList(s101.Point).empty;
    var texts = std.ArrayList(s101.Text).empty;
    var lines = std.ArrayList(s101.Line).empty;
    var patterns = std.ArrayList([]const u8).empty;
    var fill_token: ?[]const u8 = null;

    for (try syminsSplitInstructions(a, raw)) |instr| {
        const opp = syminsSplitOp(instr) orelse continue;
        if (std.mem.eql(u8, opp.op, "SY")) { // SY(NAME[,rot])
            const args = try syminsSplitArgs(a, opp.params);
            const name = std.mem.trim(u8, syminsArgAt(args, 0), " \t");
            if (name.len == 0) continue;
            const rot: f64 = if (args.len > 1) (std.fmt.parseFloat(f64, std.mem.trim(u8, args[1], " \t")) catch 0) else 0;
            try points.append(a, .{ .symbol = name, .rotation = rot, .offset_x = 0, .offset_y = 0 });
        } else if (std.mem.eql(u8, opp.op, "TX") or std.mem.eql(u8, opp.op, "TE")) {
            if (try syminsText(a, f, opp.op, opp.params)) |t| try texts.append(a, t);
        } else if (std.mem.eql(u8, opp.op, "LS")) { // LS(style,width,colour)
            const args = try syminsSplitArgs(a, opp.params);
            if (args.len < 3) continue;
            var w = std.fmt.parseInt(i64, std.mem.trim(u8, args[1], " \t"), 10) catch 0;
            if (w <= 0) w = 1;
            const st = std.mem.trim(u8, args[0], " \t");
            const dashed = std.ascii.eqlIgnoreCase(st, "DASH") or std.ascii.eqlIgnoreCase(st, "DOTT");
            try lines.append(a, .{
                .style = if (dashed) "dash" else "solid",
                .width = @floatFromInt(w),
                .color = std.mem.trim(u8, args[2], " \t"),
            });
        } else if (std.mem.eql(u8, opp.op, "LC")) { // LC(LINESTYLE) — approximated as dashed
            const name = std.mem.trim(u8, syminsArgAt(try syminsSplitArgs(a, opp.params), 0), " \t");
            if (name.len == 0) continue;
            try lines.append(a, .{ .style = name, .width = 1, .color = "CHBLK" });
        } else if (std.mem.eql(u8, opp.op, "AC")) { // AC(COLOUR[,transp])
            const color = std.mem.trim(u8, syminsArgAt(try syminsSplitArgs(a, opp.params), 0), " \t");
            if (color.len > 0) fill_token = color;
        } else if (std.mem.eql(u8, opp.op, "AP")) { // AP(PATTERN)
            const name = std.mem.trim(u8, syminsArgAt(try syminsSplitArgs(a, opp.params), 0), " \t");
            if (name.len > 0) try patterns.append(a, name);
        }
    }
    if (points.items.len == 0 and texts.items.len == 0 and lines.items.len == 0 and
        patterns.items.len == 0 and fill_token == null) return null;
    return s101.Portrayal{
        .fill_token = fill_token,
        .patterns = patterns.items,
        .lines = lines.items,
        .points = points.items,
        .texts = texts.items,
    };
}

// === Complex (symbolised) line tessellation (S-101 LineStyles) =============
// A named linestyle (LC / a LineInstruction whose style is not "_simple_") is
// tessellated per zoom: walk the line by arc length and emit, per period, the dash
// "on" runs as line segments + each embedded symbol as a point rotated to the local
// tangent. Mirrors Go bake/complexline.go + linestyle_catalog.go. The mm geometry is
// parsed by assets.parseLineStyle; the baker converts it to LsInfo at the PresLib
// FEATURE scale (ls_px_per_mm) and registers it before baking.

const ls_feature_scale: f64 = 0.01 / 0.35278; // px per 0.01-mm PresLib unit (= SYMBOL_SCALE)
const ls_px_per_mm: f64 = 100.0 * ls_feature_scale; // mm -> screen px
/// The mm->px feature scale the baker must apply when building an LsInfo from the raw
/// millimetre LineStyles geometry (assets.parseLineStyle), so the tessellator and the
/// table agree. Differs from the symbol-scale assets.analysePattern uses for the
/// client linestyles.json.
pub const LINESTYLE_PX_PER_MM = ls_px_per_mm;

pub const LsSym = struct { name: []const u8, offset_px: f64 };
pub const LsInfo = struct {
    period_px: f64,
    on_runs: []const [2]f64, // [lo,hi] screen px from period start
    symbols: []const LsSym,
    color_token: []const u8,
    width_px: f64,
};

// Set once by the baker before tile generation; read-only during the parallel bake
// (encodeTile only reads), so it needs no lock. Absent => named lines fall
// back to the generic dashed stroke (live/host path, no regression).
var g_linestyles: std.StringHashMapUnmanaged(LsInfo) = .{};

/// Register one analysed complex linestyle (id = LineStyles file stem). `id` and the
/// LsInfo slices must outlive the bake (embedded XML / the bake's long-lived alloc).
pub fn registerLinestyle(gpa: Allocator, id: []const u8, info: LsInfo) void {
    g_linestyles.put(gpa, id, info) catch {};
}

/// Drop all registered linestyles (host/test reset).
pub fn clearLinestyles(gpa: Allocator) void {
    g_linestyles.deinit(gpa);
    g_linestyles = .{};
}

/// Populate the complex-linestyle table from S-101 LineStyles XML sources
/// (id = file stem). IDEMPOTENT — a populated table is left untouched, so
/// every scene entry point (bake, lib renderView, CLI render) can call it
/// unconditionally; forgetting it silently degrades named linestyles
/// (MARSYS51, cables, pipelines, …) to generic dashed strokes. Mirrors the
/// Go lsInfoFromCatalog: mm geometry at the PresLib feature scale, S-52
/// minimum pen width. `gpa` + `srcs` must outlive all tile generation.
pub fn registerLinestylesXml(gpa: Allocator, srcs: []const assets.LineStyleSrc) void {
    if (g_linestyles.count() > 0) return;
    const px = LINESTYLE_PX_PER_MM;
    for (srcs) |s| {
        const parsed = assets.parseLineStyle(gpa, s.xml) catch continue;
        const period = parsed.interval_length * px;
        if (period < 0.5) continue; // no interval to tile (pure-symbol style)
        var runs = std.ArrayList([2]f64).empty;
        for (parsed.dashes) |d| {
            const lo = d.start * px;
            const hi = (d.start + d.length) * px;
            if (hi - lo > 1e-6) runs.append(gpa, .{ lo, hi }) catch {};
        }
        var syms = std.ArrayList(LsSym).empty;
        for (parsed.symbols) |sym| syms.append(gpa, .{ .name = sym.reference, .offset_px = sym.position * px }) catch {};
        var width = parsed.pen_width * px;
        if (width < 0.6) width = 0.9; // S-52 minimum pen
        registerLinestyle(gpa, s.id, .{
            .period_px = period,
            .on_runs = runs.items,
            .symbols = syms.items,
            .color_token = parsed.pen_color,
            .width_px = width,
        });
    }
}

const LsTangent = struct { p: tile.FPoint, dx: f64, dy: f64 };

/// Point at local arc `d` along rp plus the (un-normalised) tangent of its segment.
fn lsPointAndTangent(rp: []const tile.FPoint, rarc: []const f64, d_in: f64) ?LsTangent {
    const total = rarc[rarc.len - 1];
    const d = std.math.clamp(d_in, 0, total);
    var i: usize = 0;
    while (i + 1 < rp.len) : (i += 1) {
        if (d <= rarc[i + 1] or i + 2 == rp.len) {
            const seg = rarc[i + 1] - rarc[i];
            const t: f64 = if (seg > 1e-12) (d - rarc[i]) / seg else 0;
            return .{
                .p = .{ .x = rp[i].x + t * (rp[i + 1].x - rp[i].x), .y = rp[i].y + t * (rp[i + 1].y - rp[i].y) },
                .dx = rp[i + 1].x - rp[i].x,
                .dy = rp[i + 1].y - rp[i].y,
            };
        }
    }
    return null;
}

fn lsLerpArc(rp: []const tile.FPoint, rarc: []const f64, d: f64) tile.FPoint {
    return (lsPointAndTangent(rp, rarc, d) orelse LsTangent{ .p = rp[0], .dx = 0, .dy = 0 }).p;
}

/// Sub-polyline of rp between local arc distances d0..d1 (endpoints interpolated).
fn lsSubPathByArc(a: Allocator, rp: []const tile.FPoint, rarc: []const f64, d0_in: f64, d1_in: f64) ![]tile.FPoint {
    const total = rarc[rarc.len - 1];
    const d0 = std.math.clamp(d0_in, 0, total);
    const d1 = std.math.clamp(d1_in, 0, total);
    if (d1 - d0 < 1e-9) return &.{};
    var out = std.ArrayList(tile.FPoint).empty;
    try out.append(a, lsLerpArc(rp, rarc, d0));
    for (rp, 0..) |p, i| {
        if (rarc[i] > d0 and rarc[i] < d1) try out.append(a, p);
    }
    try out.append(a, lsLerpArc(rp, rarc, d1));
    return out.items;
}

/// Tessellate a complex linestyle along a feature's geometry parts into this tile.
/// `emit_symbols` is false when best-band suppression drops the coarse cell's points.
fn emitComplexLine(a: Allocator, parts: []const []s57.LonLat, info: LsInfo, color: []const u8, emit_symbols: bool, z: u8, x: u32, y: u32, box: tile.Box, fmeta: *const rs.FeatureMeta, surf: rs.Surface) !void {
    const ext: f64 = @floatFromInt(tile.EXTENT);
    const px_scale = ext / 256.0; // figures are laid out in 256-px-per-tile space
    const period = info.period_px * px_scale;
    if (period < 1e-6) return;
    try surf.beginFeature(fmeta);
    for (parts) |part| {
        if (part.len < 2) continue;
        const fpts = try a.alloc(tile.FPoint, part.len);
        for (part, 0..) |pt, i| fpts[i] = tile.worldToTileF(tile.lonLatToWorld(pt.lon(), pt.lat()), z, x, y, tile.EXTENT);
        const arc = try a.alloc(f64, part.len);
        arc[0] = 0;
        for (1..part.len) |i| arc[i] = arc[i - 1] + std.math.hypot(fpts[i].x - fpts[i - 1].x, fpts[i].y - fpts[i - 1].y);
        for (try tile.clipLinePhased(a, fpts, arc, box)) |run| {
            const rp = run.points;
            if (rp.len < 2) continue;
            const rarc = try a.alloc(f64, rp.len);
            rarc[0] = 0;
            for (1..rp.len) |i| rarc[i] = rarc[i - 1] + std.math.hypot(rp[i].x - rp[i - 1].x, rp[i].y - rp[i - 1].y);
            const g0 = run.arc0;
            const run_end = g0 + rarc[rp.len - 1];
            var k: i64 = @intFromFloat(@floor(g0 / period));
            while (@as(f64, @floatFromInt(k)) * period < run_end) : (k += 1) {
                const base = @as(f64, @floatFromInt(k)) * period;
                for (info.on_runs) |on| { // dash on-runs -> line segments
                    const lo = @max(base + on[0] * px_scale, g0);
                    const hi = @min(base + on[1] * px_scale, run_end);
                    if (hi - lo < 1e-6) continue;
                    const sub = try lsSubPathByArc(a, rp, rarc, lo - g0, hi - g0);
                    if (sub.len < 2) continue;
                    const seg = try a.alloc(mvt.Point, sub.len);
                    for (sub, 0..) |spt, i| seg[i] = tile.quantizeF(spt);
                    const segparts = try a.alloc([]const mvt.Point, 1);
                    segparts[0] = seg;
                    try surf.strokeLine(color, info.width_px, .solid, segparts, null);
                }
                if (!emit_symbols) continue;
                for (info.symbols) |sym| { // embedded symbols -> tangent-rotated points
                    if (sym.name.len == 0) continue;
                    const gp = base + sym.offset_px * px_scale;
                    if (gp < g0 or gp > run_end) continue;
                    const tp = lsPointAndTangent(rp, rarc, gp - g0) orelse continue;
                    const qp = tile.quantizeF(tp.p);
                    // Own each embedded symbol by exactly ONE tile: emit it only when its
                    // position lands inside the RAW tile [0,EXTENT). The dash-run lines
                    // keep the buffered clip (seamless strokes across the seam), but a
                    // symbol in the buffer zone would otherwise be tessellated by BOTH
                    // this tile and its neighbour -> the same symbol drawn twice at every
                    // tile seam (user-reported "double symbols"). Half-open so a symbol on
                    // the seam belongs to exactly one side (no gap, no double).
                    if (qp.x < 0 or qp.x >= tile.EXTENT or qp.y < 0 or qp.y >= tile.EXTENT) continue;
                    const rot = std.math.atan2(tp.dy, tp.dx) * 180.0 / std.math.pi;
                    try surf.drawSymbol(sym.name, qp, rot, SYMBOL_SCALE, true, .line, null);
                }
            }
        }
    }
    try surf.endFeature();
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
        .draw_prio = 6,
        .scamin = featureScamin(f),
        .smax = opts.smax,
        .class = catalogue.acronymByObjl(f.objl) orelse "",
        .s57_json = if (opts.pick_attrs) try encodeS57Attrs(a, f) else "",
        .cell_name = if (opts.pick_attrs) cell.name else "",
        .band = opts.band,
    };
    try surf.beginFeature(&fmeta);

    // Dashed CHGRD boundary on each ring (clipped to the tile). Best-band: drop the
    // stroke where a finer band covers the tile centre (suppress_lines).
    if (!opts.suppress_lines) for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const sub = try clipSimplifyLine(a, proj, box);
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
/// M_NSYS to nothing (s101_adapt excludes it so this rule owns it), so without this
/// the boundary draws nothing. DrawingPriority 12. NOTE: the ORIENT-only DIRBOY
/// direction-of-buoyage arrow (DIRBOY01/A1/B1, CentreOnArea) is not yet ported —
/// absent on the reference data; the A/B boundary line is the visible feature.
fn emitNavSystemFallback(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, opts: CellOpts, surf: rs.Surface) !void {
    if (opts.suppress_lines) return;
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const fmeta = rs.FeatureMeta{
        .draw_prio = 12,
        .scamin = featureScamin(f),
        .smax = opts.smax,
        .class = catalogue.acronymByObjl(f.objl) orelse "",
        .s57_json = if (opts.pick_attrs) try encodeS57Attrs(a, f) else "",
        .cell_name = if (opts.pick_attrs) cell.name else "",
        .band = opts.band,
    };

    // ORIENT present -> direction-of-buoyage boundary (NAVARE51); else the plain
    // IALA A/B system boundary (MARSYS51). Both stroke in CHGRD.
    const boundary: []const u8 = if (f.attr(s57.ATTR_ORIENT) != null) "NAVARE51" else "MARSYS51";

    // Tessellate the registered complex linestyle (dashes + the A/B letter symbols).
    if (g_linestyles.get(boundary)) |info| {
        try emitComplexLine(a, geo_parts, info, "CHGRD", !opts.suppress_points, z, x, y, box, &fmeta, surf);
        return;
    }
    // No registered linestyle (live/host path, no table): a plain dashed CHGRD ring.
    try surf.beginFeature(&fmeta);
    for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const sub = try clipSimplifyLine(a, proj, box);
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
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const fmeta = rs.FeatureMeta{
        .draw_prio = 6,
        .scamin = featureScamin(f),
        .smax = opts.smax,
        .class = catalogue.acronymByObjl(f.objl) orelse "",
        .s57_json = if (opts.pick_attrs) try encodeS57Attrs(a, f) else "",
        .cell_name = if (opts.pick_attrs) cell.name else "",
        .band = opts.band,
    };
    try surf.beginFeature(&fmeta);
    for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const sub = try clipSimplifyLine(a, proj, box);
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

/// S-52 §10.1.10 overscale indication: emit one AP(OVERSC01) area-pattern feature
/// over an M_COVR(CATCOV=1) coverage polygon, clipped to the tile, tagged `oscl` =
/// the cell's compilation scale quantized up the scamin ladder (CellOpts.oscl).
/// The style shows it only while the display is FINER than 1:oscl and paints it
/// ABOVE overscaled cells' fills but BELOW at-scale (finer) cells' fills — the
/// occlusion trick that leaves the hatch only on coarse-only patches
/// (specs/overscale.md). Rides the cell's carry tag (smax) so a band-handoff copy
/// hides with the rest of the cell's content past its handoff.
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
    const parts = try orientAreaRings(a, rings.items);
    const fmeta = rs.FeatureMeta{
        // S-52 §10.1.10.2: the overscale pattern draws at display priority 3 in
        // DISPLAY BASE (the indication is never optional content). No class/pick
        // payload — the hatch is an indication, not a chartable feature.
        .draw_prio = 3,
        .cat = 0,
        .smax = opts.smax,
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
    /// Band-handoff carry-down tag (see CellOpts.smax): the handoff denominator
    /// stamped on every feature this cell emits into the tile; 0 = not carried.
    smax: i64 = 0,
    /// The cell's quantized compilation scale (see CellOpts.oscl): tags area
    /// fills/patterns + gates the AP(OVERSC01) overscale hatch; 0 = unknown.
    oscl: i64 = 0,
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
            .suppress_lines = cr.suppress_lines,
            .suppress_points = cr.suppress_points,
            .smax = cr.smax,
            .oscl = cr.oscl,
            .pick_attrs = pick_attrs,
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
            .suppress_lines = cr.suppress_lines,
            .suppress_points = cr.suppress_points,
            .smax = cr.smax,
            .oscl = cr.oscl,
            .pick_attrs = pick_attrs,
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
            if (cur_ty < 0 or cur_ty >= self.max_t or cur_tx < 0 or cur_tx >= self.max_t) continue;
            return .{
                .z = self.z,
                .x = @intCast(cur_tx),
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
        .draw_prio = prio,
        .cat = cat,
        .scamin = featureScamin(f),
        .smax = opts.smax,
        .class = catalogue.acronymByObjl(f.objl) orelse "",
        .s57_json = if (opts.pick_attrs) try encodeS57Attrs(a, f) else "",
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
    for (cell.features, 0..) |f, fi| {
        var ml = mlon;
        var mt = mlat;
        if (f.objl == 75) {
            ml = @max(ml, (tb[2] - tb[0]) * LIGHT_AUG_REACH_TILES);
            mt = @max(mt, (tb[3] - tb[1]) * LIGHT_AUG_REACH_TILES);
        }
        if (feat_bbox) |fbb| if (fi < fbb.len) if (fbb[fi]) |b| {
            if (b[2] < tb[0] - ml or b[0] > tb[2] + ml or b[3] < tb[1] - mt or b[1] > tb[3] + mt) continue;
        };
        if (!opts.suppress_points and hasAdditionalInfo(f)) {
            try emitCentredSymbol(a, cell.*, f, fi, geo, "INFORM01", 8, 2, z, x, y, tb, opts, surf);
        }
        // S-52 §10.1.10 overscale indication: every contributing cell's M_COVR
        // (CATCOV=1) coverage polygon rides the tile as an AP(OVERSC01) hatch
        // gated on `oscl` — emitted BESIDE the feature's normal portrayal (the
        // M_COVR boundary lines still draw). Gated like the cell's fills (the
        // whole-tile suppression rule) so hatch and fills appear/carry together.
        if (opts.oscl > 0 and !opts.suppress_fills and isCoverageFeature(f)) {
            try emitOverscaleHatch(a, cell.*, f, fi, geo, z, x, y, tb, box, opts, surf);
        }
        if (f.objl == 129) {
            const smeta = rs.FeatureMeta{
                .draw_prio = 18,
                .cat = 2,
                .class = "SOUNDG",
                .s57_json = if (opts.pick_attrs) try encodeS57Attrs(a, f) else "",
                .cell_name = if (opts.pick_attrs) cell.name else "",
                .scamin = featureScamin(f),
                .smax = opts.smax,
                .band = opts.band,
            };
            try emitSoundings(a, cell.*, f, smeta, z, x, y, tb, surf);
            continue;
        }
        if (f.objl == 163) {
            if (try buildSyminsPortrayal(a, f)) |sp| {
                try processFeatureParsed(a, cell.*, f, fi, geo, geo_world, sp, 2, 2, z, x, y, tb, box, opts, surf);
                continue;
            }
        }
        const stream: ?[]const u8 = if (portrayal) |pp| (if (fi < pp.len) pp[fi] else null) else null;
        const errored = stream != null and std.mem.startsWith(u8, stream.?, "ERROR:");
        if (stream) |s| {
            if (!errored) {
                const plain: ?[]const u8 = if (portrayal_plain) |pp| (if (fi < pp.len) pp[fi] else null) else null;
                const simplified: ?[]const u8 = if (portrayal_simplified) |pp| (if (fi < pp.len) pp[fi] else null) else null;
                try processFeatureInstr(a, cell.*, f, fi, geo, geo_world, s, plain, simplified, z, x, y, tb, box, opts, surf);
                continue;
            }
        }
        if (f.objl == 134) {
            try emitSweptAreaFallback(a, cell.*, f, fi, geo, z, x, y, tb, box, opts, surf);
            continue;
        }
        if (f.objl == 163) {
            try emitDashedBoundary(a, cell.*, f, fi, geo, "CHMGF", 1.5, z, x, y, tb, box, opts, surf);
            continue;
        }
        if (f.objl == 306 and f.prim == 3) {
            try emitNavSystemFallback(a, cell.*, f, fi, geo, z, x, y, tb, box, opts, surf);
            continue;
        }
        if (f.objl != s57.OBJL_TOPMAR and s101_adapt.resolveClass(f) == null) {
            if (!opts.suppress_points) try emitCentredSymbol(a, cell.*, f, fi, geo, "QUESMRK1", 6, 1, z, x, y, tb, opts, surf);
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
            if (opts.suppress_fills) continue;
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
            const parts = try orientAreaRings(a, rings.items);
            var aprops = std.ArrayList(mvt.Prop).empty;
            try aprops.append(a, .{ .key = "class", .value = .{ .string = cls.name } });
            try aprops.append(a, .{ .key = "color_token", .value = .{ .string = cls.color } });
            try aprops.append(a, .{ .key = "band", .value = .{ .int = opts.band } });
            // Band-handoff carry-down tag — the classify() schema predates appendMeta
            // but a carried copy still must hide past its handoff (style smax gate).
            if (opts.smax > 0) try aprops.append(a, .{ .key = "smax", .value = .{ .int = opts.smax } });
            // Quantized compilation scale (overscale fill ordering — see fillArea).
            if (opts.oscl > 0) try aprops.append(a, .{ .key = "oscl", .value = .{ .int = opts.oscl } });
            try appendDepthVals(a, &aprops, f);
            try ms.areas.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = aprops.items });
            continue;
        }

        if (opts.suppress_lines) continue;
        for (geo_parts) |gp| {
            if (gp.len < 2) continue;
            if (!overlaps(geomBounds(gp), tb)) continue;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (gp, 0..) |p, i| proj[i] = tile.project(p.lon(), p.lat(), z, x, y, tile.EXTENT);
            const sub = try clipSimplifyLine(a, proj, box);
            if (sub.len == 0) continue;
            const parts = try a.alloc([]const mvt.Point, sub.len);
            for (sub, 0..) |s, i| parts[i] = s;
            const lprops = try a.alloc(mvt.Prop, if (opts.smax > 0) 4 else 3);
            lprops[0] = .{ .key = "class", .value = .{ .string = cls.name } };
            lprops[1] = .{ .key = "color_token", .value = .{ .string = cls.color } };
            lprops[2] = .{ .key = "dash", .value = .{ .string = cls.dash } };
            if (opts.smax > 0) lprops[3] = .{ .key = "smax", .value = .{ .int = opts.smax } };
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

    // always_tenths (a CONVERTED value, e.g. feet): 32.8 keeps its tenth at every
    // magnitude — never collapse a conversion to a whole number. Native (metres) drops
    // the tenth >= 31 per SNDFRM04 (32.8 m -> "32").
    try std.testing.expectEqualStrings("SOUNDS23,SOUNDS12,SOUNDS58", try sndfrmSyms(a, "SOUNDS", 32.8, false, false, true));
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

test "appendSoundingProps: feet variant keeps one decimal place (not whole feet)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A 4.5 m obstruction: metres reads "4.5" (SOUNDS14,SOUNDS55); feet TRUNCATES to
    // "14.7" (4.5*3.280839895 = 14.76 → SNDFRM04 takes the first fractional digit, round
    // DOWN), NOT "14.8" (nearest) and NOT "15" (whole). Errs shallow = the safe direction.
    var props = std.ArrayList(mvt.Prop).empty;
    try std.testing.expect(try appendSoundingProps(a, &props, 4.5, false, false));
    var sym_s: []const u8 = "";
    var sym_s_ft: []const u8 = "";
    for (props.items) |p| {
        if (std.mem.eql(u8, p.key, "sym_s")) sym_s = p.value.string;
        if (std.mem.eql(u8, p.key, "sym_s_ft")) sym_s_ft = p.value.string;
    }
    try std.testing.expectEqualStrings("SOUNDS14,SOUNDS55", sym_s); // 4.5 m
    try std.testing.expectEqualStrings("SOUNDS21,SOUNDS14,SOUNDS57", sym_s_ft); // 14.7 ft (truncated)
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

test "shortenName: buoy/light names reduce to the QUOTED chart designation" {
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const al = arena_s.allocator();
    // Verbose NOAA OBJNAM tagged "by <name>" by the S-101 buoy rules -> the
    // designation IN QUOTES (paper-chart convention: not misread as a sounding).
    try std.testing.expectEqualStrings("\"78A\"", try shortenName(al, "by Chesapeake Channel Lighted Buoy 78A"));
    try std.testing.expectEqualStrings("\"CR\"", try shortenName(al, "by Chesapeake Channel Lighted Buoy CR"));
    try std.testing.expectEqualStrings("\"3\"", try shortenName(al, "by Tangier Sound Daybeacon 3"));
    try std.testing.expectEqualStrings("\"2CR\"", try shortenName(al, "by Lighted Whistle Buoy 2CR"));
    // No type-word -> the stripped name (already short), unquoted.
    try std.testing.expectEqualStrings("22", try shortenName(al, "by 22"));
    // No "by " prefix -> passthrough (depth label, light elevation, place name).
    try std.testing.expectEqualStrings(" 4.6m", try shortenName(al, " 4.6m"));
    try std.testing.expectEqualStrings("Herring Bay", try shortenName(al, "Herring Bay"));
    // "Light"/"Lt" are NOT split words -> a named light keeps its name (defensive; such
    // labels don't carry the "by " buoy prefix anyway).
    try std.testing.expectEqualStrings("Thomas Point Light", try shortenName(al, "by Thomas Point Light"));
    // Beacon names ("bn " prefix) reduce the same way.
    try std.testing.expectEqualStrings("\"2\"", try shortenName(al, "bn Turn Rock Daybeacon 2"));
}

test "listHasAny splits S-57 comma lists and matches any target" {
    try std.testing.expect(listHasAny("4", &.{ 4, 18 }));
    try std.testing.expect(listHasAny("6,18", &.{ 4, 18 }));
    try std.testing.expect(listHasAny(" 3 , 7 ", &.{ 3, 4, 5, 8, 9 }));
    try std.testing.expect(!listHasAny("1,2,6", &.{ 4, 18 }));
    try std.testing.expect(!listHasAny("", &.{18}));
}

test "orientAreaRings subtracts a hole: exterior CW (+), interior CCW (-)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A sea-area exterior square (CCW as authored) with a smaller island hole
    // inside it (also CCW as authored). y is down in tile space.
    const ext = [_]mvt.Point{
        .{ .x = 0, .y = 0 },     .{ .x = 0, .y = 100 },
        .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 0 },
    };
    const hole = [_]mvt.Point{
        .{ .x = 40, .y = 40 }, .{ .x = 40, .y = 60 },
        .{ .x = 60, .y = 60 }, .{ .x = 60, .y = 40 },
    };
    // Pass the hole first to prove ordering is by geometry, not input order.
    const rings = [_][]const mvt.Point{ hole[0..], ext[0..] };
    const out = try orientAreaRings(a, &rings);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    // First emitted ring is the exterior (positive signed area), then its hole
    // (negative). This is the winding MapLibre reads to cut the hole out.
    try std.testing.expect(ringSignedArea(out[0]) > 0);
    try std.testing.expect(ringSignedArea(out[1]) < 0);
    // The exterior must be the 100x100 ring, the hole the 20x20 one.
    try std.testing.expect(@abs(ringSignedArea(out[0])) > @abs(ringSignedArea(out[1])));
}

test "orientAreaRings keeps disjoint parts as separate exteriors (multipolygon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two disjoint squares (CTNARE-style multi-part area): both are exteriors,
    // both wound positive, neither becomes a hole of the other.
    const r0 = [_]mvt.Point{
        .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 },
    };
    const r1 = [_]mvt.Point{
        .{ .x = 50, .y = 50 }, .{ .x = 50, .y = 60 }, .{ .x = 60, .y = 60 }, .{ .x = 60, .y = 50 },
    };
    const rings = [_][]const mvt.Point{ r0[0..], r1[0..] };
    const out = try orientAreaRings(a, &rings);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expect(ringSignedArea(out[0]) > 0);
    try std.testing.expect(ringSignedArea(out[1]) > 0);
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

test "processFeatureInstr routes SCAMIN point to the bucket + carries draw_prio/scamin" {
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

    // SCAMIN-carrying point -> point_symbols_scamin, with draw_prio=7 + scamin=22000.
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
    try std.testing.expectEqual(@as(i64, 7), findProp(ms.points_scamin.items[0].properties, "draw_prio").?.int);
    try std.testing.expectEqual(@as(i64, 22000), findProp(ms.points_scamin.items[0].properties, "scamin").?.int);

    // No SCAMIN -> base point_symbols layer, draw_prio default 0, no scamin.
    const f_base = s57.Feature{
        .rcnm = 0,
        .rcid = 2,
        .prim = 1,
        .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    };
    try processFeatureInstr(a, cell, f_base, 0, null, null, "PointInstruction:BOYLAT01", null, null, 0, 0, 0, tb, box, .{}, surf);
    try std.testing.expectEqual(@as(usize, 1), ms.points.items.len);
    try std.testing.expectEqual(@as(i64, 0), findProp(ms.points.items[0].properties, "draw_prio").?.int);
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(ms.points.items[0].properties, "scamin"));
    // No point-style variant -> common pass: no `pts` tag (client coalesces to 2).
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(ms.points.items[0].properties, "pts"));
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

test "buildSyminsPortrayal parses SY/TX/LS/LC/AC/AP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const attrs = [_]s57.Attr{.{
        .code = SYMINS_ATTR,
        .value = "SY(BOYSPP01,45);TX('Hello',1,2,0,'15110',0,0,CHRED,28);" ++
            "LS(DASH,3,CHGRD);LS(SOLD,2,CHBLK);LC(NAVARE51);AC(DEPVS);AP(DIAMOND1)",
    }};
    const f = s57.Feature{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 163, .attrs = &attrs };

    const p = (try buildSyminsPortrayal(a, f)) orelse return error.NoPortrayal;

    try std.testing.expectEqual(@as(usize, 1), p.points.len);
    try std.testing.expectEqualStrings("BOYSPP01", p.points[0].symbol);
    try std.testing.expectEqual(@as(f64, 45), p.points[0].rotation);

    try std.testing.expectEqual(@as(usize, 1), p.texts.len);
    try std.testing.expectEqualStrings("Hello", p.texts[0].text);
    try std.testing.expectEqualStrings("CHRED", p.texts[0].color);
    try std.testing.expectEqual(@as(i64, 28), p.texts[0].group);

    try std.testing.expectEqual(@as(usize, 3), p.lines.len); // 2x LS + 1x LC
    try std.testing.expectEqualStrings("dash", p.lines[0].style); // DASH -> dashed
    try std.testing.expectEqual(@as(f64, 3), p.lines[0].width);
    try std.testing.expectEqualStrings("CHGRD", p.lines[0].color);
    try std.testing.expectEqualStrings("solid", p.lines[1].style); // SOLD -> solid
    try std.testing.expectEqualStrings("NAVARE51", p.lines[2].style); // LC name verbatim

    try std.testing.expectEqualStrings("DEPVS", p.fill_token.?);
    try std.testing.expectEqual(@as(usize, 1), p.patterns.len);
    try std.testing.expectEqualStrings("DIAMOND1", p.patterns[0]);

    // A blank / absent SYMINS yields no portrayal.
    const f_empty = s57.Feature{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 163, .attrs = &[_]s57.Attr{.{ .code = SYMINS_ATTR, .value = "   " }} };
    try std.testing.expect((try buildSyminsPortrayal(a, f_empty)) == null);

    // Instruction-splitting honours a ';' inside a quoted TX string.
    const f_semi = s57.Feature{ .rcnm = 100, .rcid = 3, .prim = 1, .objl = 163, .attrs = &[_]s57.Attr{.{ .code = SYMINS_ATTR, .value = "TX('a;b',1,2,0,'15110',0,0,CHBLK,28)" }} };
    const ps = (try buildSyminsPortrayal(a, f_semi)) orelse return error.NoPortrayal;
    try std.testing.expectEqual(@as(usize, 1), ps.texts.len);
    try std.testing.expectEqualStrings("a;b", ps.texts[0].text);
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
    _ = scamin_pts;
}

// ---- bundle-sourced replay (baked tile -> Surface calls) --------------------
//
// The tile schema is a serialized Surface-call stream, so a baked tile can be
// replayed onto any Surface — the substrate for rendering PMTiles bundles to
// pixels with no source cells. LOSSY by design: the bake-time portrayal
// context is frozen (SafetyContour/Depth 30); the live-swappable props the
// tile path bakes (danger_depth/sym_deep, sym_s/sym_g depth + quality-ring
// prefixes) are re-expanded here, so the mariner's danger swap, sounding
// bold/faint split, and display unit still evaluate LIVE.

fn propOf(props: []const mvt.Prop, key: []const u8) ?mvt.Value {
    for (props) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

fn propInt(props: []const mvt.Prop, key: []const u8, default: i64) i64 {
    const v = propOf(props, key) orelse return default;
    return switch (v) {
        .int => |i| i,
        .uint => |u| @intCast(u),
        .double => |d| @intFromFloat(d),
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

fn propF64(props: []const mvt.Prop, key: []const u8) ?f64 {
    const v = propOf(props, key) orelse return null;
    return switch (v) {
        .double => |d| d,
        .float => |f| f,
        .int => |i| @floatFromInt(i),
        .uint => |u| @floatFromInt(u),
        else => null,
    };
}

fn propStr(props: []const mvt.Prop, key: []const u8) []const u8 {
    const v = propOf(props, key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn metaFromProps(props: []const mvt.Prop) rs.FeatureMeta {
    return .{
        .draw_prio = propInt(props, "draw_prio", 0),
        .cat = propInt(props, "cat", 1),
        .vg = propInt(props, "vg", 0),
        .scamin = if (propOf(props, "scamin")) |_| propInt(props, "scamin", 0) else null,
        .smax = propInt(props, "smax", 0),
        .class = propStr(props, "class"),
        .band = @intCast(std.math.clamp(propInt(props, "band", 0), 0, 255)),
        .bnd = propInt(props, "bnd", 2),
        .pts = propInt(props, "pts", 2),
        .date_start = propStr(props, "date_start"),
        .date_end = propStr(props, "date_end"),
    };
}

/// Replay one decoded tile's layers as Surface calls (between the caller's
/// begin/endScene). Layer names route exactly as TileSurface emitted them.
pub fn replayTile(surf: rs.Surface, layers: []const mvt.DecodedLayer) !void {
    for (layers) |layer| {
        const is_areas = std.mem.startsWith(u8, layer.name, "areas");
        const is_patterns = std.mem.startsWith(u8, layer.name, "area_patterns");
        const is_lines = std.mem.startsWith(u8, layer.name, "lines");
        const is_points = std.mem.startsWith(u8, layer.name, "point_symbols");
        const is_soundings = std.mem.eql(u8, layer.name, "soundings");
        const is_text = std.mem.startsWith(u8, layer.name, "text");
        for (layer.features) |f| {
            const meta = metaFromProps(f.properties);
            try surf.beginFeature(&meta);
            defer surf.endFeature() catch {};
            if (is_patterns) {
                try surf.fillPattern(propStr(f.properties, "pattern_name"), f.parts);
            } else if (is_areas) {
                const d1 = propF64(f.properties, "drval1");
                const dr: ?rs.DepthRange = if (d1) |v| .{ .d1 = @floatCast(v), .d2 = @floatCast(propF64(f.properties, "drval2") orelse v) } else null;
                try surf.fillArea(propStr(f.properties, "color_token"), f.parts, dr);
            } else if (is_lines) {
                const dash: rs.Dash = if (std.mem.eql(u8, propStr(f.properties, "dash"), "solid")) .solid else .dashed;
                try surf.strokeLine(propStr(f.properties, "color_token"), propF64(f.properties, "width_px") orelse 1, dash, f.parts, propF64(f.properties, "valdco"));
            } else if (is_points) {
                if (f.parts.len == 0 or f.parts[0].len == 0) continue;
                try surf.drawSymbol(
                    propStr(f.properties, "symbol_name"),
                    f.parts[0][0],
                    propF64(f.properties, "rotation_deg") orelse 0,
                    propF64(f.properties, "scale") orelse SYMBOL_SCALE,
                    propInt(f.properties, "rot_north", 0) != 0,
                    .point,
                    propF64(f.properties, "danger_depth"), // live swap re-evaluates
                );
            } else if (is_soundings) {
                if (f.parts.len == 0 or f.parts[0].len == 0) continue;
                const depth = propF64(f.properties, "depth") orelse continue;
                // The quality-ring flags are encoded in the baked glyph list's
                // leading tokens (SNDFRM04 B1 swept / C2/C3 low-accuracy) —
                // recover them so the live recomposition keeps the rings.
                const sym_s = propStr(f.properties, "sym_s");
                const swept = std.mem.indexOf(u8, sym_s, "SB1") != null;
                const low_acc = std.mem.indexOf(u8, sym_s, "SC3") != null;
                try surf.drawSounding(depth, swept, low_acc, f.parts[0][0]);
            } else if (is_text) {
                if (f.parts.len == 0 or f.parts[0].len == 0) continue;
                var ox: f64 = 0;
                var oy: f64 = 0;
                const loff = propStr(f.properties, "loff");
                if (loff.len > 0) {
                    var it = std.mem.splitScalar(u8, loff, ',');
                    const TEXT_BODY_MM = 3.51;
                    ox = (std.fmt.parseFloat(f64, it.next() orelse "0") catch 0) * TEXT_BODY_MM;
                    oy = (std.fmt.parseFloat(f64, it.next() orelse "0") catch 0) * TEXT_BODY_MM;
                }
                const style = rs.TextStyle{
                    .color = propStr(f.properties, "color_token"),
                    .font_size = propF64(f.properties, "font_size_px") orelse 12,
                    .halign = propStr(f.properties, "halign"),
                    .valign = propStr(f.properties, "valign"),
                    .offset_x = ox,
                    .offset_y = oy,
                    .group = propInt(f.properties, "tgrp", 0),
                };
                try surf.drawText(propStr(f.properties, "text"), &style, f.parts[0][0]);
            }
        }
    }
}
