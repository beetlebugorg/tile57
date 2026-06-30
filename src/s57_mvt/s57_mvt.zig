//! Direct S-57 -> MVT tile generation (M6c demo, BYPASSING S-101 portrayal).
//!
//! Generates a vector tile for (z,x,y) straight from an S-57 cell with a small
//! hardcoded object-class -> S-52 color-token mapping, so the existing chart
//! style renders it. This proves cell -> MVT -> MapLibre end to end before the
//! S-101 Lua portrayal engine lands and replaces classify() with real rules.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57");
const tile = @import("tile");
const mvt = @import("mvt");
const mlt = @import("mlt");

/// Output tile encoding: classic Mapbox Vector Tile, or MapLibre Tile (optional).
pub const TileFormat = enum { mvt, mlt };
const s101 = @import("s100").s101_instr;
const catalogue = @import("s100").catalogue;

// S-52 symbol scale the Go baker emits for every point symbol / sounding. The
// style's icon-size = scale / ATLAS_PPU (0.08), so this renders symbols at
// ~0.354 — matching the reference. The live path previously used 0.08 (icon
// size 1.0), i.e. ~2.8x too large.
const SYMBOL_SCALE: f64 = 0.02834627777338028;

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

/// Port of SNDFRM04's sounding glyph composition: build the comma-joined glyph-name
/// string for a depth and prefix ("SOUNDS" bold/shallow or "SOUNDG" faint/deep).
/// Covers the swept (B1) and low-accuracy-ring (C3 shallow / C2 deep) quality
/// prefixes, the negative-value A-prefix (drying heights), and the full magnitude
/// range up to 5 digits. Glyph order matches the rule: B1, ring, A-prefix, digits.
/// `swept`/`low_acc` come from the feature's quality attributes (TECSOU/QUASOU/
/// STATUS). NOTE: the rule's spatial-QUAPOS fallback for the ring (when the direct
/// attrs are absent) is not yet wired — soundings whose only low-accuracy signal is
/// a poor spatial quality-of-position still miss the ring; the direct attrs match.
fn sndfrmSyms(a: Allocator, prefix: []const u8, depth: f64, swept: bool, low_acc: bool) ![]const u8 {
    const d = @abs(depth);
    // Round to tenths: depth is an f64 (z/somf), so naive truncation would hit binary
    // FP off-by-one on the tenths digit (12.3 stored as 12.299999…). Rounding d*10
    // recovers the exact tenths for all 0.1 m-precision SOUNDG data (somf=10), which
    // equals the oracle's decimal-string first-fractional digit (SNDFRM04:53-72).
    const tenths: i64 = @intFromFloat(@round(d * 10.0));
    const idepth: i64 = @divTrunc(tenths, 10);
    const frac: u8 = @intCast(@mod(tenths, 10));
    var dbuf: [12]u8 = undefined;
    const ds = std.fmt.bufPrint(&dbuf, "{d}", .{idepth}) catch return "";
    var toks = std.ArrayList([]const u8).empty;

    // Quality prefixes lead the composite (SNDFRM04:37-51). Swept soundings get a B1
    // ring; low-accuracy ones get a ring sized to the variant — C3 on the shallow
    // SOUNDS glyph, C2 on the deep SOUNDG glyph (the rule's lowAccuracySymbolRing).
    if (swept) try toks.append(a, try std.fmt.allocPrint(a, "{s}B1", .{prefix}));
    if (low_acc) {
        const ring = if (std.mem.eql(u8, prefix, "SOUNDS")) "C3" else "C2";
        try toks.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, ring }));
    }

    // Negative soundings (drying heights / heights above datum) get an A-prefix ring
    // (SNDFRM04:62-68): A3 if |d|>=10 with a fraction, A2 if |d|>=10 whole, else A1.
    // (Only SOUNDS* A-glyphs exist — a negative sounding is always <= safety depth so
    // the style picks the SOUNDS variant; the SOUNDG variant is composed but unused.)
    if (depth < 0) {
        if (idepth >= 10 and frac != 0) {
            try toks.append(a, try std.fmt.allocPrint(a, "{s}A3", .{prefix}));
        } else if (idepth >= 10) {
            try toks.append(a, try std.fmt.allocPrint(a, "{s}A2", .{prefix}));
        } else {
            try toks.append(a, try std.fmt.allocPrint(a, "{s}A1", .{prefix}));
        }
    }

    if (idepth < 10) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[0] }));
        if (frac != 0) try toks.append(a, try std.fmt.allocPrint(a, "{s}5{d}", .{ prefix, frac }));
    } else if (idepth < 31 and frac != 0) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}2{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[1] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}5{d}", .{ prefix, frac }));
    } else if (idepth < 100) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}0{c}", .{ prefix, ds[1] }));
    } else if (idepth < 1000) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}2{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[1] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}0{c}", .{ prefix, ds[2] }));
    } else if (idepth < 10000) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}2{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[1] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}0{c}", .{ prefix, ds[2] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}4{c}", .{ prefix, ds[3] }));
    } else {
        // >= 10000 m (deepest oceans ~11 km): 5 digits at codes 3,2,1,0,4.
        try toks.append(a, try std.fmt.allocPrint(a, "{s}3{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}2{c}", .{ prefix, ds[1] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[2] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}0{c}", .{ prefix, ds[3] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}4{c}", .{ prefix, ds[4] }));
    }
    return std.mem.join(a, ",", toks.items);
}

/// Emit a SOUNDG feature's multipoint soundings into the `soundings` layer, one
/// point per sounding, with sym_s/sym_g/depth so the style's SNDFRM glyphs and
/// the mariner safety-depth switch (soundings_image) render the depth digits.
fn emitSoundings(a: Allocator, cell: s57.Cell, f: s57.Feature, meta: Meta, z: u8, x: u32, y: u32, tb: [4]f64, out: *std.ArrayList(mvt.Feature)) !void {
    const snds = cell.soundingsFor(a, f) catch return;
    // Per-feature quality flags (SNDFRM04): swept => B1, low-accuracy => C2/C3 ring.
    // These attributes apply to the whole SOUNDG feature, so derive them once.
    const swept = listHasAny(f.attr(s57.ATTR_TECSOU) orelse "", &.{ 4, 18 });
    const low_acc = listHasAny(f.attr(s57.ATTR_QUASOU) orelse "", &.{ 3, 4, 5, 8, 9 }) or
        listHasAny(f.attr(s57.ATTR_STATUS) orelse "", &.{18});
    for (snds) |s| {
        if (s.lon() < tb[0] or s.lon() > tb[2] or s.lat() < tb[1] or s.lat() > tb[3]) continue;
        const sym_s = try sndfrmSyms(a, "SOUNDS", s.depth, swept, low_acc);
        if (sym_s.len == 0) continue;
        const sym_g = try sndfrmSyms(a, "SOUNDG", s.depth, swept, low_acc);
        const pt = tile.project(s.lon(), s.lat(), z, x, y, tile.EXTENT);
        const parts = try a.alloc([]const mvt.Point, 1);
        const single = try a.alloc(mvt.Point, 1);
        single[0] = pt;
        parts[0] = single;
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(a, .{ .key = "sym_s", .value = .{ .string = sym_s } });
        try props.append(a, .{ .key = "sym_g", .value = .{ .string = sym_g } });
        try props.append(a, .{ .key = "depth", .value = .{ .double = s.depth } });
        try props.append(a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
        // Shared S-52 mariner-filter metadata (draw priority / display category /
        // band / SCAMIN / class) so soundings honour the client's category + SCAMIN
        // gating like every other feature — oracle routeSoundingGroup (bake.go:894).
        try appendMeta(a, &props, meta);
        try out.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
    }
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

/// Emit a feature styled by its S-101 instruction stream. Surfaces with a
/// ColorFill become `areas` polygons (color_token already depth-resolved by the
/// rule); curves with LineInstructions become `lines`. (Patterns / points /
/// text grow here next.)
const Layers = struct {
    areas: *std.ArrayList(mvt.Feature),
    area_patterns: *std.ArrayList(mvt.Feature),
    lines: *std.ArrayList(mvt.Feature),
    points: *std.ArrayList(mvt.Feature),
    texts: *std.ArrayList(mvt.Feature),
    // SCAMIN buckets: a feature carrying SCAMIN (s57 attr 133) routes here instead
    // of the base list, and carries a `scamin` property so the style gates its
    // display below the feature's 1:N scale (see s57_mvt.ATTR_SCAMIN / assets/style.zig).
    areas_scamin: *std.ArrayList(mvt.Feature),
    area_patterns_scamin: *std.ArrayList(mvt.Feature),
    lines_scamin: *std.ArrayList(mvt.Feature),
    points_scamin: *std.ArrayList(mvt.Feature),
    texts_scamin: *std.ArrayList(mvt.Feature),
    // NOAA navigational band of the cell being appended (0=berthing/finest …
    // 5=overview/coarsest). Emitted as the MVT `band` property so the style's
    // fill-sort-key draws finer-band area fills over coarser ones at band overlaps
    // (the live multi-cell path overlays all bands into one tile).
    band: u8 = 0,
    // Best-band coverage suppression (live multi-cell path): this cell is a COARSER
    // band overzoomed past its native range where a finer band's M_COVR coverage is
    // present, so its AREA fills (suppress_fills) and/or patterns (suppress_patterns)
    // are dropped — the finer cell carries the real data. Fills are suppressed only
    // where a finer band covers the WHOLE tile (no seam gap; the finer fill occludes
    // via the band sort-key); patterns, which draw above all fills, are suppressed by
    // the tile centre so they can't lap over finer land.
    suppress_fills: bool = false,
    suppress_patterns: bool = false,
    // Best-band suppression for the remaining geometry of an overzoomed coarser cell:
    //   suppress_lines  — drop boundary/line STROKES where a finer band covers the tile
    //     centre. Lines double-draw beside the finer copy (no opaque fill hides them),
    //     so this matches the Go line rule (coverageScaleAt at the tile centre).
    //   suppress_points — drop point symbols + text where a finer band covers the WHOLE
    //     tile. Conservative per-tile approximation of Go's per-point position test:
    //     a partly-covered seam tile keeps the coarse points/labels (the finer cell,
    //     drawn on top, wins where it has data); no labels lost over a coverage gap.
    suppress_lines: bool = false,
    suppress_points: bool = false,
    // Emit the per-feature pick-report attributes (the `s57` blob + `cell` name) for
    // the S-52 §10.8 cursor pick + dev inspector. Defaults ON (host wants a working
    // pick report in the local-first deployment); a lean bake can turn it off via the
    // C ABI to drop the bulky `s57` payload. See encodeS57Attrs / pickS57.
    pick_attrs: bool = true,
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
    "areas",         "areas_scamin",  "area_patterns", "area_patterns_scamin",
    "lines",         "lines_scamin",  "point_symbols", "point_symbols_scamin",
    "soundings",     "text",          "text_scamin",
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
fn appendTextProps(a: Allocator, props: *std.ArrayList(mvt.Prop), t: s101.Text) !void {
    try props.append(a, .{ .key = "text", .value = .{ .string = t.text } });
    try props.append(a, .{ .key = "color_token", .value = .{ .string = t.color } });
    try props.append(a, .{ .key = "font_size_px", .value = .{ .double = if (t.font_size > 0) t.font_size else 12 } });
    try props.append(a, .{ .key = "halign", .value = .{ .string = t.halign } });
    try props.append(a, .{ .key = "valign", .value = .{ .string = t.valign } });
    try props.append(a, .{ .key = "tgrp", .value = .{ .int = t.group } });
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
fn encodeS57Attrs(a: Allocator, f: s57.Feature) ![]const u8 {
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

/// The `s57` pick-report blob for `f`, or "" when pick attributes are disabled
/// (host opt-out flag) — so a lean bake stays free of the bulky attribute payload.
fn pickS57(a: Allocator, L: Layers, f: s57.Feature) ![]const u8 {
    return if (L.pick_attrs) encodeS57Attrs(a, f) else "";
}

/// The source-cell name for the pick report, or "" when pick attributes are disabled.
fn pickCell(L: Layers, cell_name: []const u8) []const u8 {
    return if (L.pick_attrs) cell_name else "";
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
/// tile-coord bbox — letting emitParsed skip a part that misses the clip box
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
fn featureParts(a: Allocator, cell: s57.Cell, geo: ?GeoParts, fi: usize, f: s57.Feature) ![][]s57.LonLat {
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

/// Emit one feature, tagging its primitives with the boundary/point-style variant
/// it varies under. Replicates the Go portrayer's Passes semantics (§8.6.1/§11.2.2):
///   - AREA features whose boundary changes under PlainBoundaries get two passes —
///     the default (symbolized, bnd=1) and the plain stream (bnd=0);
///   - (non-SOUNDG) POINT features whose symbol changes under SimplifiedSymbols get
///     two passes — the default (paper, pts=0) and the simplified stream (pts=1);
///   - everything else (including features whose variant stream is identical) stays
///     a single common pass (bnd=pts=2, tags omitted).
/// SOUNDG bypasses this path (emitted as a multipoint earlier), so it never doubles.
fn emitFromInstr(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, geo_world: ?GeoWorld, instr: []const u8, plain: ?[]const u8, simplified: ?[]const u8, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, L: Layers) !void {
    const base = try s101.parse(a, instr);

    // Point-symbol style (pts): a point feature whose simplified-symbol stream
    // differs is emitted twice (paper pts=0 + simplified pts=1); else common.
    if (f.prim == 1) {
        if (variantDiffers(instr, simplified)) {
            try emitParsed(a, cell, f, fi, geo, geo_world, base, 2, 0, z, x, y, tb, box, L);
            const sp = try s101.parse(a, simplified.?);
            try emitParsed(a, cell, f, fi, geo, geo_world, sp, 2, 1, z, x, y, tb, box, L);
        } else {
            try emitParsed(a, cell, f, fi, geo, geo_world, base, 2, 2, z, x, y, tb, box, L);
        }
        return;
    }
    // Boundary symbolization (bnd): an area feature whose plain-boundary stream
    // differs is emitted twice (symbolized bnd=1 + plain bnd=0); else common.
    if (f.prim == 3 and variantDiffers(instr, plain)) {
        try emitParsed(a, cell, f, fi, geo, geo_world, base, 1, 2, z, x, y, tb, box, L);
        const pl = try s101.parse(a, plain.?);
        try emitParsed(a, cell, f, fi, geo, geo_world, pl, 0, 2, z, x, y, tb, box, L);
        return;
    }
    // Lines, and any feature whose variant is absent/identical: one common pass.
    try emitParsed(a, cell, f, fi, geo, geo_world, base, 2, 2, z, x, y, tb, box, L);
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
fn emitAugFigures(a: Allocator, figs: []const s101.AugFigure, anchor: s57.LonLat, meta: Meta, z: u8, x: u32, y: u32, box: tile.Box, lines_l: *std.ArrayList(mvt.Feature)) !void {
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

        var fmeta = meta;
        fmeta.vg = if (fig.vg != 0) fig.vg else meta.vg; // sector arcs filter on their own VG
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(a, .{ .key = "color_token", .value = .{ .string = fig.color } });
        try props.append(a, .{ .key = "width_px", .value = .{ .double = fig.width_mm * pxmm } });
        try props.append(a, .{ .key = "dash", .value = .{ .string = if (fig.dashed) "dashed" else "solid" } });
        try appendMeta(a, &props, fmeta);
        try lines_l.append(a, .{ .geom_type = .linestring, .parts = kept.items, .properties = props.items });
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

/// Emit one parsed portrayal pass `p`, stamping every primitive with the pass's
/// boundary (`bnd`) and point-style (`pts`) variant tags.
fn emitParsed(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, geo_world: ?GeoWorld, p: s101.Portrayal, bnd: i64, pts: i64, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, L: Layers) !void {
    // Route each feature into its base layer or the *_scamin bucket depending on
    // whether it carries a SCAMIN (1:N) display limit. Same geometry/properties
    // either way; the bucket lets the style gate the feature below its scale.
    const scamin = featureScamin(f);
    const meta = Meta{
        .prio = p.draw_prio,
        .cat = p.cat,
        .vg = p.vg,
        .scamin = scamin,
        .class = catalogue.acronymByObjl(f.objl) orelse "",
        .s57 = try pickS57(a, L, f),
        .cell = pickCell(L, cell.name),
        .band = L.band,
        .date_start = p.date_start,
        .date_end = p.date_end,
        .bnd = bnd,
        .pts = pts,
    };
    const areas_l = if (scamin != null) L.areas_scamin else L.areas;
    const apat_l = if (scamin != null) L.area_patterns_scamin else L.area_patterns;
    const lines_l = if (scamin != null) L.lines_scamin else L.lines;
    const points_l = if (scamin != null) L.points_scamin else L.points;
    const texts_l = if (scamin != null) L.texts_scamin else L.texts;

    // Point features (buoys/beacons/lights/landmarks/soundings): symbols + text
    // placed at the feature's node.
    if (f.prim == 1) {
        const pg = cell.pointGeometry(f) orelse return;
        // Sector legs/arcs (LightSectored) are stroked around the light's node and
        // clipped to the tile box, so they render even when the node sits in the
        // buffer zone just off-tile. Emitted before the point's in-bounds gate below.
        try emitAugFigures(a, p.aug_figures, pg, meta, z, x, y, box, lines_l);
        if (pg.lon() < tb[0] or pg.lon() > tb[2] or pg.lat() < tb[1] or pg.lat() > tb[3]) return;
        const pt = tile.project(pg.lon(), pg.lat(), z, x, y, tile.EXTENT);
        const parts = try a.alloc([]const mvt.Point, 1);
        const single = try a.alloc(mvt.Point, 1);
        single[0] = pt;
        parts[0] = single;
        // Best-band suppression: a finer band covers this whole tile, so drop this
        // coarse cell's point symbols + text (the finer cell carries them).
        if (!L.suppress_points) for (p.points) |sym| {
            var props = std.ArrayList(mvt.Prop).empty;
            try props.append(a, .{ .key = "symbol_name", .value = .{ .string = sym.symbol } });
            try props.append(a, .{ .key = "rotation_deg", .value = .{ .double = sym.rotation } });
            if (sym.rot_north) try props.append(a, .{ .key = "rot_north", .value = .{ .int = 1 } });
            try props.append(a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
            try appendMeta(a, &props, meta);
            try points_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
        };
        if (!L.suppress_points) for (p.texts) |t| {
            var props = std.ArrayList(mvt.Prop).empty;
            try appendTextProps(a, &props, t);
            try appendMeta(a, &props, meta);
            try texts_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
        };
        return;
    }

    // Line/area features: assemble into connected parts (rings / chains) so
    // disjoint geometry isn't joined by a spurious straight jump across the cell.
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    // Project each usable part; quick-reject if none overlap the tile. Reproject
    // from the cell's precomputed world coords (cheap; no per-point tan/log) when
    // the baker supplied them, else project lon/lat directly (the live path).
    const wparts: ?[]const WPart = if (geo_world) |gw| (if (fi < gw.len) gw[fi] else null) else null;
    var projected = std.ArrayList([]mvt.Point).empty;
    var any_overlap = false;
    for (geo_parts, 0..) |gp, pi| {
        if (gp.len < 2) continue;
        const wp: ?WPart = if (wparts) |wps| (if (pi < wps.len and wps[pi].pts.len == gp.len) wps[pi] else null) else null;
        if (wp) |w| {
            // any_overlap keys on the RAW tile bbox (no buffer), exactly as before —
            // a feature touching only the buffer zone is still dropped.
            if (overlaps(w.bbox, tb)) any_overlap = true;
            // Exact tile-coord cull: worldToTile is linear+monotonic, so projecting
            // the part's world bbox corners gives its exact projected bbox. If that
            // misses the clip box the part clips to nothing — skip projecting its
            // points (byte-identical, just no wasted work). Big win on multi-part
            // features (coastlines, land/depth areas) that span a super-tile but
            // touch each leaf tile with only a few of their parts.
            const lo = tile.worldToTile(.{ w.wbbox[0], w.wbbox[1] }, z, x, y, tile.EXTENT);
            const hi = tile.worldToTile(.{ w.wbbox[2], w.wbbox[3] }, z, x, y, tile.EXTENT);
            if (hi.x < box.min or lo.x > box.max or hi.y < box.min or lo.y > box.max) continue;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (w.pts, 0..) |ww, i| proj[i] = tile.worldToTile(ww, z, x, y, tile.EXTENT);
            try projected.append(a, proj);
        } else {
            // Live path (single-tile): bbox-cull in lon/lat, project every part.
            if (overlaps(geomBounds(gp), tb)) any_overlap = true;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
            try projected.append(a, proj);
        }
    }
    if (!any_overlap or projected.items.len == 0) return;

    if (f.prim == 3) {
        // Clip each ring, then assemble ONE multipolygon per feature with the
        // rings wound exterior-vs-hole (orientAreaRings) so interior holes (e.g.
        // an island inside a sea/depth area) are subtracted, not filled — and
        // disjoint area parts still render. (Was: one polygon per ring, which
        // filled holes with the area's own colour.)
        var rings = std.ArrayList([]const mvt.Point).empty;
        for (projected.items) |proj| {
            const ring = try clipSimplifyPoly(a, proj, box);
            if (ring.len >= 3) try rings.append(a, ring);
        }
        // Best-band suppression: drop a coarser band's fill (where a finer band
        // covers the whole tile) and/or its pattern (where a finer band covers the
        // tile centre) so coarse water/shallow-pattern can't lap over finer land.
        if (rings.items.len > 0) {
            const parts = try orientAreaRings(a, rings.items);
            if (!L.suppress_fills) if (p.fill_token) |token| {
                var props = std.ArrayList(mvt.Prop).empty;
                try props.append(a, .{ .key = "color_token", .value = .{ .string = token } });
                try appendDepthVals(a, &props, f); // DEPARE/DRGARE -> drval1/drval2 (SEABED01)
                try appendMeta(a, &props, meta);
                try areas_l.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = props.items });
            };
            // AreaFillReference -> a tiled fill pattern (DRGARE/FOUL/quality fills).
            if (!L.suppress_patterns) for (p.patterns) |pat| {
                var props = std.ArrayList(mvt.Prop).empty;
                try props.append(a, .{ .key = "pattern_name", .value = .{ .string = pat } });
                try appendMeta(a, &props, meta);
                try apat_l.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = props.items });
            };
        }
    }
    // DEPCNT depth-contour value (metres), incl. the 0 m drying/chart-datum line:
    // baked whenever VALDCO is explicitly present (even 0) so the style can label
    // it; a missing VALDCO is unknown, not zero, so it's left off. Mirrors the Go
    // contourValdco fix (no `> 0` drop).
    const valdco: ?f64 = if (f.objl == 43) f.attrFloat(s57.ATTR_VALDCO) else null;

    // S-52 §8.6.2: masked (MASK==1) / data-limit (USAG==3) boundary edges must NOT be
    // drawn. The FILL above keeps full rings and labels use the full geometry, but the
    // STROKE uses the drawable subset — for BOTH simple solid strokes AND complex
    // (symbolized) linestyles, since the oracle masks the line geometry before
    // portrayal so a symbolized boundary skips masked/coast-coincident edges too.
    // `stroke_geo` is the lon/lat geometry the strokes draw along (the drawable subset
    // when masking applies, else the full geometry); `stroke_proj` is its projection
    // for the simple path. Fast path: with no mask/usag info the drawn geometry equals
    // the full geometry, so reuse `geo_parts`/`projected` (and its precomputed cull).
    var stroke_geo: []const []s57.LonLat = geo_parts;
    var stroke_proj: []const []mvt.Point = projected.items;
    if (!L.suppress_lines and p.lines.len > 0 and cell.needsDrawableBoundary(f)) {
        var stroke_storage = std.ArrayList([]mvt.Point).empty;
        const dparts = cell.drawableLineParts(a, f) catch &[_][]s57.LonLat{};
        stroke_geo = dparts;
        for (dparts) |dp| {
            if (dp.len < 2) continue;
            if (!overlaps(geomBounds(dp), tb)) continue;
            const proj = try a.alloc(mvt.Point, dp.len);
            for (dp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
            try stroke_storage.append(a, proj);
        }
        stroke_proj = stroke_storage.items;
    }

    // Best-band suppression: a finer band covers the tile centre, so drop this coarse
    // cell's line strokes (they'd double-draw beside the finer copy).
    if (!L.suppress_lines) for (p.lines) |ln| {
        // A named (complex) linestyle in the registered table is tessellated along the
        // geometry (dash runs + embedded symbols on the tangent); see emitComplexLine.
        if (!std.mem.eql(u8, ln.style, "solid")) {
            if (g_linestyles.get(ln.style)) |info| {
                // Draw the symbolized linestyle along the DRAWABLE subset (stroke_geo),
                // not the full ring — so a complex boundary skips masked / data-limit /
                // coast-coincident edges like the simple stroke does (S-52 §8.6.2).
                // e187d80 hoisted stroke_geo but left this call on geo_parts, so complex
                // linestyles still drew along the entire coastline; feed it stroke_geo.
                try emitComplexLine(a, stroke_geo, info, ln.color, !L.suppress_points, z, x, y, box, meta, lines_l, points_l);
                continue;
            }
        }
        // _simple_ -> solid; an UNregistered named style (or no table, e.g. the live
        // host path) is approximated as a dashed stroke rather than a bold solid one.
        const dash: []const u8 = if (std.mem.eql(u8, ln.style, "solid")) "solid" else "dashed";
        for (stroke_proj) |proj| {
            const sub = try clipSimplifyLine(a, proj, box);
            if (sub.len == 0) continue;
            const parts = try a.alloc([]const mvt.Point, sub.len);
            for (sub, 0..) |s, i| parts[i] = s;
            var props = std.ArrayList(mvt.Prop).empty;
            try props.append(a, .{ .key = "color_token", .value = .{ .string = ln.color } });
            try props.append(a, .{ .key = "width_px", .value = .{ .double = ln.width } });
            try props.append(a, .{ .key = "dash", .value = .{ .string = dash } });
            if (valdco) |v| try props.append(a, .{ .key = "valdco", .value = .{ .double = v } });
            try appendMeta(a, &props, meta);
            try lines_l.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = props.items });
        }
    };

    // Area / line labels (TextInstruction): placed at the feature's text anchor —
    // an area's representative point (centre of gravity; see areaRepresentativePoint),
    // a line's middle vertex (see featureAnchor). Without this only point-feature
    // labels show, so area/channel/place names were missing.
    // (suppress_points: a finer band covers the whole tile — drop coarse labels.)
    if (!L.suppress_points and p.texts.len > 0) {
        if (featureAnchor(a, cell, f, fi, geo_parts)) |rp| {
            if (rp.lon() >= tb[0] and rp.lon() <= tb[2] and rp.lat() >= tb[1] and rp.lat() <= tb[3]) {
                const cpt = tile.project(rp.lon(), rp.lat(), z, x, y, tile.EXTENT);
                const parts = try a.alloc([]const mvt.Point, 1);
                const single = try a.alloc(mvt.Point, 1);
                single[0] = cpt;
                parts[0] = single;
                for (p.texts) |t| {
                    var props = std.ArrayList(mvt.Prop).empty;
                    try appendTextProps(a, &props, t);
                    try appendMeta(a, &props, meta);
                    try texts_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
                }
            }
        }
    }

    // Point symbols on a LINE/AREA feature (PointInstruction). Go emits these at the
    // feature's anchor (CentreOnArea → area rep point; a line → its middle vertex);
    // place them there so centred-area marks (anchorage, restricted-area/entry, marine
    // farm, TSS arrows) aren't dropped — previously p.points was only emitted for
    // prim==1. (suppress_points: a finer band covers the whole tile — drop coarse symbols.)
    if (!L.suppress_points and p.points.len > 0) {
        if (featureAnchor(a, cell, f, fi, geo_parts)) |rp| {
            if (rp.lon() >= tb[0] and rp.lon() <= tb[2] and rp.lat() >= tb[1] and rp.lat() <= tb[3]) {
                const cpt = tile.project(rp.lon(), rp.lat(), z, x, y, tile.EXTENT);
                const parts = try a.alloc([]const mvt.Point, 1);
                const single = try a.alloc(mvt.Point, 1);
                single[0] = cpt;
                parts[0] = single;
                for (p.points) |sym| {
                    var props = std.ArrayList(mvt.Prop).empty;
                    try props.append(a, .{ .key = "symbol_name", .value = .{ .string = sym.symbol } });
                    try props.append(a, .{ .key = "rotation_deg", .value = .{ .double = sym.rotation } });
                    if (sym.rot_north) try props.append(a, .{ .key = "rot_north", .value = .{ .int = 1 } });
                    try props.append(a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
                    try appendMeta(a, &props, meta);
                    try points_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
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
/// Geometry/anchoring/clipping is handled by emitParsed exactly like a rule stream.
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
// (generateTileMulti only reads), so it needs no lock. Absent => named lines fall
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
fn emitComplexLine(a: Allocator, parts: []const []s57.LonLat, info: LsInfo, color: []const u8, emit_symbols: bool, z: u8, x: u32, y: u32, box: tile.Box, meta: Meta, lines_l: *std.ArrayList(mvt.Feature), points_l: *std.ArrayList(mvt.Feature)) !void {
    const ext: f64 = @floatFromInt(tile.EXTENT);
    const px_scale = ext / 256.0; // figures are laid out in 256-px-per-tile space
    const period = info.period_px * px_scale;
    if (period < 1e-6) return;
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
                    for (sub, 0..) |sp, i| seg[i] = tile.quantizeF(sp);
                    const segparts = try a.alloc([]const mvt.Point, 1);
                    segparts[0] = seg;
                    var props = std.ArrayList(mvt.Prop).empty;
                    try props.append(a, .{ .key = "color_token", .value = .{ .string = color } });
                    try props.append(a, .{ .key = "width_px", .value = .{ .double = info.width_px } });
                    try props.append(a, .{ .key = "dash", .value = .{ .string = "solid" } });
                    try appendMeta(a, &props, meta);
                    try lines_l.append(a, .{ .geom_type = .linestring, .parts = segparts, .properties = props.items });
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
                    const single = try a.alloc(mvt.Point, 1);
                    single[0] = qp;
                    const sparts = try a.alloc([]const mvt.Point, 1);
                    sparts[0] = single;
                    var sprops = std.ArrayList(mvt.Prop).empty;
                    try sprops.append(a, .{ .key = "symbol_name", .value = .{ .string = sym.name } });
                    try sprops.append(a, .{ .key = "rotation_deg", .value = .{ .double = rot } });
                    try sprops.append(a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
                    try sprops.append(a, .{ .key = "rot_north", .value = .{ .int = 1 } }); // turns with the chart
                    try appendMeta(a, &sprops, meta);
                    try points_l.append(a, .{ .geom_type = .point, .parts = sparts, .properties = sprops.items });
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
fn emitSweptAreaFallback(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, L: Layers) !void {
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const scamin = featureScamin(f);
    const lines_l = if (scamin != null) L.lines_scamin else L.lines;
    const points_l = if (scamin != null) L.points_scamin else L.points;
    const texts_l = if (scamin != null) L.texts_scamin else L.texts;
    const meta = Meta{ .prio = 6, .scamin = scamin, .class = catalogue.acronymByObjl(f.objl) orelse "", .s57 = try pickS57(a, L, f), .cell = pickCell(L, cell.name), .band = L.band };

    // Dashed CHGRD boundary on each ring (clipped to the tile). Best-band: drop the
    // stroke where a finer band covers the tile centre (suppress_lines).
    if (!L.suppress_lines) for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const sub = try clipSimplifyLine(a, proj, box);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(a, .{ .key = "color_token", .value = .{ .string = "CHGRD" } });
        try props.append(a, .{ .key = "width_px", .value = .{ .double = 1 } });
        try props.append(a, .{ .key = "dash", .value = .{ .string = "dashed" } });
        try appendMeta(a, &props, meta);
        try lines_l.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = props.items });
    };

    // SWPARE51 bracket + "swept to <DRVAL1>" label at the representative point. Drop
    // both where a finer band covers the whole tile (suppress_points).
    if (L.suppress_points) return;
    const rp = labelPoint(a, cell, fi, geo_parts) orelse return;
    if (rp.lon() < tb[0] or rp.lon() > tb[2] or rp.lat() < tb[1] or rp.lat() > tb[3]) return;
    const cpt = tile.project(rp.lon(), rp.lat(), z, x, y, tile.EXTENT);
    const parts = try a.alloc([]const mvt.Point, 1);
    const single = try a.alloc(mvt.Point, 1);
    single[0] = cpt;
    parts[0] = single;

    var sprops = std.ArrayList(mvt.Prop).empty;
    try sprops.append(a, .{ .key = "symbol_name", .value = .{ .string = "SWPARE51" } });
    try sprops.append(a, .{ .key = "rotation_deg", .value = .{ .double = 0 } });
    try sprops.append(a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
    try appendMeta(a, &sprops, meta);
    try points_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = sprops.items });

    if (f.attrFloat(s57.ATTR_DRVAL1)) |d1| {
        const label = try std.fmt.allocPrint(a, "swept to {d}", .{d1});
        var tprops = std.ArrayList(mvt.Prop).empty;
        try tprops.append(a, .{ .key = "text", .value = .{ .string = label } });
        try tprops.append(a, .{ .key = "color_token", .value = .{ .string = "CHBLK" } });
        try tprops.append(a, .{ .key = "font_size_px", .value = .{ .double = 11 } });
        try appendMeta(a, &tprops, meta);
        try texts_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = tprops.items });
    }
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
fn emitNavSystemFallback(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, L: Layers) !void {
    if (L.suppress_lines) return;
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const scamin = featureScamin(f);
    const lines_l = if (scamin != null) L.lines_scamin else L.lines;
    const points_l = if (scamin != null) L.points_scamin else L.points;
    const meta = Meta{ .prio = 12, .scamin = scamin, .class = catalogue.acronymByObjl(f.objl) orelse "", .s57 = try pickS57(a, L, f), .cell = pickCell(L, cell.name), .band = L.band };

    // ORIENT present -> direction-of-buoyage boundary (NAVARE51); else the plain
    // IALA A/B system boundary (MARSYS51). Both stroke in CHGRD.
    const boundary: []const u8 = if (f.attr(s57.ATTR_ORIENT) != null) "NAVARE51" else "MARSYS51";

    // Tessellate the registered complex linestyle (dashes + the A/B letter symbols).
    if (g_linestyles.get(boundary)) |info| {
        try emitComplexLine(a, geo_parts, info, "CHGRD", !L.suppress_points, z, x, y, box, meta, lines_l, points_l);
        return;
    }
    // No registered linestyle (live/host path, no table): a plain dashed CHGRD ring.
    for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const sub = try clipSimplifyLine(a, proj, box);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(a, .{ .key = "color_token", .value = .{ .string = "CHGRD" } });
        try props.append(a, .{ .key = "width_px", .value = .{ .double = 1 } });
        try props.append(a, .{ .key = "dash", .value = .{ .string = "dashed" } });
        try appendMeta(a, &props, meta);
        try lines_l.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = props.items });
    }
}

/// Native S-52 fallback for NEWOBJ (objl 163). NEWOBJ features map to S-101 classes
/// (e.g. VirtualAISAidToNavigation) whose rule may not portray the encoded geometry
/// (wrong primitive, unofficial stub, …); when portrayal yields nothing or errors,
/// draw the Go reference's newObjectBuild placeholder — a dashed CHMGF (magenta)
/// outline on the feature's line/area geometry. DrawingPriority 6.
/// Stroke a feature's line/area geometry as a dashed boundary in `color` — the
/// shared shape of several native S-52 fallbacks (NEWOBJ box; an area-encoded
/// RecommendedTrack whose Curve-only S-101 rule errors). DrawingPriority 6.
fn emitDashedBoundary(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, color: []const u8, width: f64, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, L: Layers) !void {
    if (f.prim != 2 and f.prim != 3) return;
    if (L.suppress_lines) return; // coarse band over finer M_COVR (centre): drop the stroke
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const scamin = featureScamin(f);
    const lines_l = if (scamin != null) L.lines_scamin else L.lines;
    const meta = Meta{ .prio = 6, .scamin = scamin, .class = catalogue.acronymByObjl(f.objl) orelse "", .s57 = try pickS57(a, L, f), .cell = pickCell(L, cell.name), .band = L.band };
    for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon(), pt.lat(), z, x, y, tile.EXTENT);
        const sub = try clipSimplifyLine(a, proj, box);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(a, .{ .key = "color_token", .value = .{ .string = color } });
        try props.append(a, .{ .key = "width_px", .value = .{ .double = width } });
        try props.append(a, .{ .key = "dash", .value = .{ .string = "dashed" } });
        try appendMeta(a, &props, meta);
        try lines_l.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = props.items });
    }
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
    /// Layers.suppress_* fields for the per-geometry whole-tile vs centre rules.
    suppress_fills: bool = false,
    suppress_patterns: bool = false,
    suppress_lines: bool = false,
    suppress_points: bool = false,
};

/// Generate MVT bytes (uncompressed) for tile (z,x,y) from a single `cell`.
/// `portrayal`, if given, is indexed by feature index and holds each feature's
/// S-101 instruction stream (from the Lua engine); features with an instruction
/// stream are styled by it, the rest fall back to classify().
pub fn generateTile(gpa: Allocator, cell: *s57.Cell, z: u8, x: u32, y: u32, portrayal: ?[]const ?[]const u8) ![]u8 {
    const one = [_]CellRef{.{ .cell = cell, .portrayal = portrayal }};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    return generateTileMulti(arena.allocator(), gpa, &one, z, x, y, .mvt, true);
}

/// Generate encoded tile bytes (uncompressed) for tile (z,x,y) overlaying one or
/// more cells (an ENC_ROOT). Each cell's features are appended into the shared
/// layers, so a tile spanning several cells carries all of them.
///
/// `scratch` holds all transient working memory (geometry assembly, clipped rings,
/// the per-layer feature lists). A batch baker passes a per-thread arena reset
/// between tiles; `out` owns only the returned encoded bytes (pass `scratch` too
/// when the result is consumed before the next reset, e.g. gzipped immediately).
pub fn generateTileMulti(scratch: Allocator, out: Allocator, cells: []const CellRef, z: u8, x: u32, y: u32, format: TileFormat, pick_attrs: bool) ![]u8 {
    const a = scratch;

    const tb = tile.tileBoundsLonLat(z, x, y);
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    var areas = std.ArrayList(mvt.Feature).empty;
    var area_patterns = std.ArrayList(mvt.Feature).empty;
    var lines = std.ArrayList(mvt.Feature).empty;
    var points = std.ArrayList(mvt.Feature).empty;
    var texts = std.ArrayList(mvt.Feature).empty;
    var areas_scamin = std.ArrayList(mvt.Feature).empty;
    var area_patterns_scamin = std.ArrayList(mvt.Feature).empty;
    var lines_scamin = std.ArrayList(mvt.Feature).empty;
    var points_scamin = std.ArrayList(mvt.Feature).empty;
    var texts_scamin = std.ArrayList(mvt.Feature).empty;
    var soundings = std.ArrayList(mvt.Feature).empty;
    const layers_ctx = Layers{
        .areas = &areas,
        .area_patterns = &area_patterns,
        .lines = &lines,
        .points = &points,
        .texts = &texts,
        .areas_scamin = &areas_scamin,
        .area_patterns_scamin = &area_patterns_scamin,
        .lines_scamin = &lines_scamin,
        .points_scamin = &points_scamin,
        .texts_scamin = &texts_scamin,
        .pick_attrs = pick_attrs,
    };

    for (cells) |cr| {
        var Lc = layers_ctx;
        Lc.band = cr.band; // so this cell's features carry its band for the sort key
        Lc.suppress_fills = cr.suppress_fills; // coarse band over finer M_COVR (whole-tile): drop fill
        Lc.suppress_patterns = cr.suppress_patterns; // coarse band over finer M_COVR (centre): drop pattern
        Lc.suppress_lines = cr.suppress_lines; // (centre): drop coarse boundary/line strokes
        Lc.suppress_points = cr.suppress_points; // (whole-tile): drop coarse point symbols + text
        try appendCellFeatures(a, Lc, &soundings, cr.cell, cr.portrayal, cr.portrayal_plain, cr.portrayal_simplified, cr.geo, cr.geo_world, cr.feat_bbox, z, x, y, tb, box);
    }

    var layers = std.ArrayList(mvt.Layer).empty;
    if (areas.items.len > 0) try layers.append(a, .{ .name = "areas", .features = areas.items });
    if (areas_scamin.items.len > 0) try layers.append(a, .{ .name = "areas_scamin", .features = areas_scamin.items });
    if (area_patterns.items.len > 0) try layers.append(a, .{ .name = "area_patterns", .features = area_patterns.items });
    if (area_patterns_scamin.items.len > 0) try layers.append(a, .{ .name = "area_patterns_scamin", .features = area_patterns_scamin.items });
    if (lines.items.len > 0) try layers.append(a, .{ .name = "lines", .features = lines.items });
    if (lines_scamin.items.len > 0) try layers.append(a, .{ .name = "lines_scamin", .features = lines_scamin.items });
    if (points.items.len > 0) try layers.append(a, .{ .name = "point_symbols", .features = points.items });
    if (points_scamin.items.len > 0) try layers.append(a, .{ .name = "point_symbols_scamin", .features = points_scamin.items });
    if (soundings.items.len > 0) try layers.append(a, .{ .name = "soundings", .features = soundings.items });
    if (texts.items.len > 0) try layers.append(a, .{ .name = "text", .features = texts.items });
    if (texts_scamin.items.len > 0) try layers.append(a, .{ .name = "text_scamin", .features = texts_scamin.items });
    if (layers.items.len == 0) return out.alloc(u8, 0); // empty tile

    return switch (format) {
        .mvt => mvt.encode(out, .{ .layers = layers.items }),
        .mlt => mlt.encode(out, .{ .layers = layers.items }),
    };
}

/// Append one cell's features for tile (z,x,y) into the shared layer lists.
fn appendCellFeatures(
    a: Allocator,
    L: Layers,
    soundings: *std.ArrayList(mvt.Feature),
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
    // Tile bbox expanded by the buffer zone, for the spatial cull (a feature whose
    // bbox misses this would clip to nothing, so skipping it is output-preserving).
    const mlon = (tb[2] - tb[0]) * @as(f64, @floatFromInt(tile.BUFFER)) / @as(f64, @floatFromInt(tile.EXTENT));
    const mlat = (tb[3] - tb[1]) * @as(f64, @floatFromInt(tile.BUFFER)) / @as(f64, @floatFromInt(tile.EXTENT));
    for (cell.features, 0..) |f, fi| {
        // Spatial cull: skip features whose precomputed bbox doesn't overlap the tile.
        // LIGHTS (objl 75) carry sector legs/arcs (emitAugFigures) that radiate a fixed
        // DISPLAY distance from the node — a near-constant tile fraction at any zoom,
        // well beyond the node-only point bbox. Widen the cull margin for them so the
        // feature is processed (and its arcs clipped in) on every tile the arcs cross,
        // instead of being dropped one tile out -> sector lights cut off at seams.
        var ml = mlon;
        var mt = mlat;
        if (f.objl == 75) {
            ml = @max(ml, (tb[2] - tb[0]) * LIGHT_AUG_REACH_TILES);
            mt = @max(mt, (tb[3] - tb[1]) * LIGHT_AUG_REACH_TILES);
        }
        if (feat_bbox) |fbb| if (fi < fbb.len) if (fbb[fi]) |b| {
            if (b[2] < tb[0] - ml or b[0] > tb[2] + ml or b[3] < tb[1] - mt or b[1] > tb[3] + mt) continue;
        };
        // S-52 §10.6.1.1 additional-information indicator: a SY(INFORM01) "info
        // available" marker at the feature's representative point whenever it carries
        // a non-blank INFORM/NINFOM/TXTDSC/NTXTDS/PICREP. Always draw priority 8,
        // category Other (overriding the feature's own category) so it clears Standard
        // display and only shows when the mariner enables Other — matching the oracle's
        // addInformSymbol + the bake's per-symbol category override (build.go:267 /
        // bake.go:854). Emitted here, before the dispatch below, so EVERY feature gets
        // it (Go wraps every buildFeature) regardless of which body path draws the
        // feature — even an unportrayed/suppressed one. (suppress_points: a finer band
        // covers the whole tile → drop this coarse cell's marker, like its symbols.)
        if (!L.suppress_points and hasAdditionalInfo(f)) {
            const rp: ?s57.LonLat = if (f.prim == 1)
                cell.pointGeometry(f)
            else rpblk: {
                const gp = featureParts(a, cell.*, geo, fi, f) catch break :rpblk null;
                break :rpblk featureAnchor(a, cell.*, f, fi, gp);
            };
            if (rp) |p| {
                if (p.lon() >= tb[0] and p.lon() <= tb[2] and p.lat() >= tb[1] and p.lat() <= tb[3]) {
                    const scamin = featureScamin(f);
                    const points_l = if (scamin != null) L.points_scamin else L.points;
                    const pt = tile.project(p.lon(), p.lat(), z, x, y, tile.EXTENT);
                    const parts = try a.alloc([]const mvt.Point, 1);
                    const single = try a.alloc(mvt.Point, 1);
                    single[0] = pt;
                    parts[0] = single;
                    var props = std.ArrayList(mvt.Prop).empty;
                    try props.append(a, .{ .key = "symbol_name", .value = .{ .string = "INFORM01" } });
                    try props.append(a, .{ .key = "rotation_deg", .value = .{ .double = 0 } });
                    try props.append(a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
                    try appendMeta(a, &props, .{
                        .prio = 8,
                        .cat = 2, // Other (overrides the feature's category)
                        .scamin = scamin,
                        .class = catalogue.acronymByObjl(f.objl) orelse "",
                        .s57 = try pickS57(a, L, f),
                        .cell = pickCell(L, cell.name),
                        .band = L.band,
                    });
                    try points_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
                }
            }
        }
        // SOUNDG (objl 129) is multipoint: emit its SG3D soundings directly into
        // the `soundings` layer (the flat S-101 instruction stream can't carry
        // per-sounding geometry). Bypasses the portrayal/classify dispatch.
        if (f.objl == 129) {
            // SOUNDG bypasses the portrayal dispatch (multipoint geometry can't ride
            // the flat instruction stream), so its feature-level Meta is built here.
            // SNDFRM04 portrayal is deterministic for the class: DrawingPriority 18,
            // display category Other (cat=2) — verified against the oracle's
            // routeSoundingGroup (fb.DisplayPriority / catRank(fb.DisplayCategory)).
            const smeta = Meta{
                .prio = 18,
                .cat = 2,
                .class = "SOUNDG",
                .s57 = try pickS57(a, L, f),
                .cell = pickCell(L, cell.name),
                .scamin = featureScamin(f),
                .band = L.band,
            };
            try emitSoundings(a, cell.*, f, smeta, z, x, y, tb, soundings);
            continue;
        }
        // NEWOBJ with a producer SYMINS attribute: portray the explicit S-52 symbol
        // instruction (SYMINS02) instead of the S-101 V-AIS alias the engine emitted.
        // Dispatched FIRST, exactly like Go buildFeatureBody (s101build.go:298-302).
        if (f.objl == 163) {
            if (try buildSyminsPortrayal(a, f)) |sp| {
                try emitParsed(a, cell.*, f, fi, geo, geo_world, sp, 2, 2, z, x, y, tb, box, L);
                continue;
            }
        }
        // S-101 portrayal stream for this feature: null = unmapped/unportrayed; an
        // "ERROR:" marker = the rule raised. A usable stream styles the feature;
        // otherwise fall through to the native S-52 fallbacks / classify().
        const stream: ?[]const u8 = if (portrayal) |pp| (if (fi < pp.len) pp[fi] else null) else null;
        const errored = stream != null and std.mem.startsWith(u8, stream.?, "ERROR:");
        if (stream) |s| {
            if (!errored) {
                // The boundary-style (area) / point-style (point) display variants
                // for this feature, if portrayed — emitFromInstr splits the feature
                // into two passes only when the variant actually differs.
                const plain: ?[]const u8 = if (portrayal_plain) |pp| (if (fi < pp.len) pp[fi] else null) else null;
                const simplified: ?[]const u8 = if (portrayal_simplified) |pp| (if (fi < pp.len) pp[fi] else null) else null;
                try emitFromInstr(a, cell.*, f, fi, geo, geo_world, s, plain, simplified, z, x, y, tb, box, L);
                continue;
            }
        }
        // No usable portrayal. Native S-52 fallbacks for classes the catalogue can't
        // portray (mirrors Go's buildFeatureBody); any other class that errored is
        // suppressed (drawn as nothing, as the Go reference does).
        if (f.objl == 134) { // SWPARE — the catalogue ships no SweptArea rule (IHO gap)
            try emitSweptAreaFallback(a, cell.*, f, fi, geo, z, x, y, tb, box, L);
            continue;
        }
        if (f.objl == 163) { // NEWOBJ — new-object box placeholder (dashed magenta)
            try emitDashedBoundary(a, cell.*, f, fi, geo, "CHMGF", 1.5, z, x, y, tb, box, L);
            continue;
        }
        if (f.objl == 109 and f.prim == 3) { // RECTRC area: Curve-only rule errors; draw the track limit
            try emitDashedBoundary(a, cell.*, f, fi, geo, "CHBLK", 1.0, z, x, y, tb, box, L);
            continue;
        }
        if (f.objl == 306 and f.prim == 3) { // M_NSYS — navSystemBuild (IALA A/B boundary linestyle)
            try emitNavSystemFallback(a, cell.*, f, fi, geo, z, x, y, tb, box, L);
            continue;
        }
        if (errored) continue; // genuine rule error on a normal class → suppress
        const cls = classify(f.objl);
        if (cls.kind == .skip) continue;
        const geo_parts = featureParts(a, cell.*, geo, fi, f) catch continue;
        if (geo_parts.len == 0) continue;

        if (cls.kind == .area) {
            if (L.suppress_fills) continue; // coarse band over finer M_COVR (whole tile): drop the fill
            // Collect the feature's clipped rings, then emit ONE multipolygon with
            // holes subtracted (see orientAreaRings) — same fix as the portrayal
            // path so a sea/depth hole over an island isn't filled.
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
            // Depth areas carry DRVAL1/DRVAL2 so the style's SEABED01 shading
            // applies (areasFillColor keys on `drval1`).
            var aprops = std.ArrayList(mvt.Prop).empty;
            try aprops.append(a, .{ .key = "class", .value = .{ .string = cls.name } });
            try aprops.append(a, .{ .key = "color_token", .value = .{ .string = cls.color } });
            try aprops.append(a, .{ .key = "band", .value = .{ .int = L.band } });
            try appendDepthVals(a, &aprops, f); // f32 + DRVAL2->DRVAL1 fallback (== oracle depthVals)
            try L.areas.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = aprops.items });
            continue;
        }

        // Line classes: drop the stroke where a finer band covers the tile centre.
        if (L.suppress_lines) continue;
        for (geo_parts) |gp| {
            if (gp.len < 2) continue;
            if (!overlaps(geomBounds(gp), tb)) continue;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (gp, 0..) |p, i| proj[i] = tile.project(p.lon(), p.lat(), z, x, y, tile.EXTENT);
            const sub = try clipSimplifyLine(a, proj, box);
            if (sub.len == 0) continue;
            const parts = try a.alloc([]const mvt.Point, sub.len);
            for (sub, 0..) |s, i| parts[i] = s;
            const lprops = try a.alloc(mvt.Prop, 3);
            lprops[0] = .{ .key = "class", .value = .{ .string = cls.name } };
            lprops[1] = .{ .key = "color_token", .value = .{ .string = cls.color } };
            lprops[2] = .{ .key = "dash", .value = .{ .string = cls.dash } };
            try L.lines.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = lprops });
        }
    }
}

test "SNDFRM04 digit composition matches the Lua rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("SOUNDS12,SOUNDS57", try sndfrmSyms(a, "SOUNDS", 2.7, false, false));
    try std.testing.expectEqualStrings("SOUNDS10,SOUNDS56", try sndfrmSyms(a, "SOUNDS", 0.6, false, false));
    try std.testing.expectEqualStrings("SOUNDS15", try sndfrmSyms(a, "SOUNDS", 5.0, false, false));
    try std.testing.expectEqualStrings("SOUNDG22,SOUNDG11,SOUNDG56", try sndfrmSyms(a, "SOUNDG", 21.6, false, false));
    try std.testing.expectEqualStrings("SOUNDS14,SOUNDS07", try sndfrmSyms(a, "SOUNDS", 47.0, false, false));

    // >= 1000 m (4-digit, codes 2,1,0,4) — previously dropped entirely.
    try std.testing.expectEqualStrings("SOUNDG21,SOUNDG12,SOUNDG03,SOUNDG44", try sndfrmSyms(a, "SOUNDG", 1234.0, false, false));
    try std.testing.expectEqualStrings("SOUNDG21,SOUNDG10,SOUNDG00,SOUNDG40", try sndfrmSyms(a, "SOUNDG", 1000.0, false, false));
    // >= 10000 m (5-digit, codes 3,2,1,0,4) — deepest oceans.
    try std.testing.expectEqualStrings("SOUNDG31,SOUNDG20,SOUNDG19,SOUNDG09,SOUNDG44", try sndfrmSyms(a, "SOUNDG", 10994.0, false, false));

    // Negative soundings (drying heights): A-prefix ring by sign/magnitude.
    try std.testing.expectEqualStrings("SOUNDSA3,SOUNDS21,SOUNDS12,SOUNDS53", try sndfrmSyms(a, "SOUNDS", -12.3, false, false));
    try std.testing.expectEqualStrings("SOUNDSA2,SOUNDS11,SOUNDS05", try sndfrmSyms(a, "SOUNDS", -15.0, false, false));
    try std.testing.expectEqualStrings("SOUNDSA1,SOUNDS15", try sndfrmSyms(a, "SOUNDS", -5.0, false, false));
    try std.testing.expectEqualStrings("SOUNDSA1,SOUNDS10,SOUNDS56", try sndfrmSyms(a, "SOUNDS", -0.6, false, false));

    // Quality prefixes (SNDFRM04:37-51): B1 (swept) and the low-accuracy ring lead
    // the composite, ring sized to the variant (C3 shallow / C2 deep).
    try std.testing.expectEqualStrings("SOUNDSB1,SOUNDS15", try sndfrmSyms(a, "SOUNDS", 5.0, true, false));
    try std.testing.expectEqualStrings("SOUNDSC3,SOUNDS15", try sndfrmSyms(a, "SOUNDS", 5.0, false, true));
    try std.testing.expectEqualStrings("SOUNDGC2,SOUNDG15", try sndfrmSyms(a, "SOUNDG", 5.0, false, true));
    // B1 then ring then A-prefix then digits, all together.
    try std.testing.expectEqualStrings("SOUNDSB1,SOUNDSC3,SOUNDSA3,SOUNDS21,SOUNDS12,SOUNDS53", try sndfrmSyms(a, "SOUNDS", -12.3, true, true));
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
        .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 100 },
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

test "emitFromInstr routes SCAMIN point to the bucket + carries draw_prio/scamin" {
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

    var areas = std.ArrayList(mvt.Feature).empty;
    var area_patterns = std.ArrayList(mvt.Feature).empty;
    var lines = std.ArrayList(mvt.Feature).empty;
    var points = std.ArrayList(mvt.Feature).empty;
    var texts = std.ArrayList(mvt.Feature).empty;
    var areas_s = std.ArrayList(mvt.Feature).empty;
    var apat_s = std.ArrayList(mvt.Feature).empty;
    var lines_s = std.ArrayList(mvt.Feature).empty;
    var points_s = std.ArrayList(mvt.Feature).empty;
    var texts_s = std.ArrayList(mvt.Feature).empty;
    const L = Layers{
        .areas = &areas,         .area_patterns = &area_patterns,        .lines = &lines,
        .points = &points,       .texts = &texts,
        .areas_scamin = &areas_s, .area_patterns_scamin = &apat_s,       .lines_scamin = &lines_s,
        .points_scamin = &points_s, .texts_scamin = &texts_s,
    };
    const tb = [4]f64{ -1, -1, 1, 1 };
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    // SCAMIN-carrying point -> point_symbols_scamin, with draw_prio=7 + scamin=22000.
    const f_sc = s57.Feature{
        .rcnm = 0, .rcid = 1, .prim = 1, .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
        .attrs = &.{.{ .code = ATTR_SCAMIN, .value = "22000" }},
    };
    try emitFromInstr(a, cell, f_sc, 0, null, null, "DrawingPriority:7;PointInstruction:BOYLAT01", null, null, 0, 0, 0, tb, box, L);
    try std.testing.expectEqual(@as(usize, 0), points.items.len);
    try std.testing.expectEqual(@as(usize, 1), points_s.items.len);
    try std.testing.expectEqual(@as(i64, 7), findProp(points_s.items[0].properties, "draw_prio").?.int);
    try std.testing.expectEqual(@as(i64, 22000), findProp(points_s.items[0].properties, "scamin").?.int);

    // No SCAMIN -> base point_symbols layer, draw_prio default 0, no scamin.
    const f_base = s57.Feature{
        .rcnm = 0, .rcid = 2, .prim = 1, .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    };
    try emitFromInstr(a, cell, f_base, 0, null, null, "PointInstruction:BOYLAT01", null, null, 0, 0, 0, tb, box, L);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(i64, 0), findProp(points.items[0].properties, "draw_prio").?.int);
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(points.items[0].properties, "scamin"));
    // No point-style variant -> common pass: no `pts` tag (client coalesces to 2).
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(points.items[0].properties, "pts"));
}

test "variantDiffers: absent/errored/identical = common, real change = split" {
    try std.testing.expect(!variantDiffers("PointInstruction:A", null));
    try std.testing.expect(!variantDiffers("PointInstruction:A", "ERROR: boom"));
    try std.testing.expect(!variantDiffers("PointInstruction:A", "PointInstruction:A"));
    try std.testing.expect(variantDiffers("PointInstruction:BOYLAT01", "PointInstruction:BOYLAT11"));
}

test "emitFromInstr tags pts 0/1 when a point's simplified symbol differs" {
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

    var areas = std.ArrayList(mvt.Feature).empty;
    var area_patterns = std.ArrayList(mvt.Feature).empty;
    var lines = std.ArrayList(mvt.Feature).empty;
    var points = std.ArrayList(mvt.Feature).empty;
    var texts = std.ArrayList(mvt.Feature).empty;
    var areas_s = std.ArrayList(mvt.Feature).empty;
    var apat_s = std.ArrayList(mvt.Feature).empty;
    var lines_s = std.ArrayList(mvt.Feature).empty;
    var points_s = std.ArrayList(mvt.Feature).empty;
    var texts_s = std.ArrayList(mvt.Feature).empty;
    const L = Layers{
        .areas = &areas,            .area_patterns = &area_patterns,    .lines = &lines,
        .points = &points,          .texts = &texts,
        .areas_scamin = &areas_s,   .area_patterns_scamin = &apat_s,    .lines_scamin = &lines_s,
        .points_scamin = &points_s, .texts_scamin = &texts_s,
    };
    const tb = [4]f64{ -1, -1, 1, 1 };
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    const f = s57.Feature{
        .rcnm = 0, .rcid = 1, .prim = 1, .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    };
    // Paper -> BOYLAT01; simplified -> BOYLAT11. Two passes: pts=0 then pts=1.
    try emitFromInstr(a, cell, f, 0, null, null, "PointInstruction:BOYLAT01", null, "PointInstruction:BOYLAT11", 0, 0, 0, tb, box, L);
    try std.testing.expectEqual(@as(usize, 2), points.items.len);
    try std.testing.expectEqual(@as(i64, 0), findProp(points.items[0].properties, "pts").?.int);
    try std.testing.expectEqualStrings("BOYLAT01", findProp(points.items[0].properties, "symbol_name").?.string);
    try std.testing.expectEqual(@as(i64, 1), findProp(points.items[1].properties, "pts").?.int);
    try std.testing.expectEqualStrings("BOYLAT11", findProp(points.items[1].properties, "symbol_name").?.string);
    // Boundary axis untouched on a point: no `bnd` tag.
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(points.items[0].properties, "bnd"));
}

test "emitFromInstr tags bnd 1/0 when an area's plain boundary differs" {
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
    // A square ring, pre-assembled below so emitFromInstr skips edge resolution.
    const ring = [_]s57.LonLat{
        s57.LonLat.init(-0.5, -0.5), s57.LonLat.init(0.5, -0.5),
        s57.LonLat.init(0.5, 0.5),   s57.LonLat.init(-0.5, 0.5),
        s57.LonLat.init(-0.5, -0.5),
    };

    var areas = std.ArrayList(mvt.Feature).empty;
    var area_patterns = std.ArrayList(mvt.Feature).empty;
    var lines = std.ArrayList(mvt.Feature).empty;
    var points = std.ArrayList(mvt.Feature).empty;
    var texts = std.ArrayList(mvt.Feature).empty;
    var areas_s = std.ArrayList(mvt.Feature).empty;
    var apat_s = std.ArrayList(mvt.Feature).empty;
    var lines_s = std.ArrayList(mvt.Feature).empty;
    var points_s = std.ArrayList(mvt.Feature).empty;
    var texts_s = std.ArrayList(mvt.Feature).empty;
    const L = Layers{
        .areas = &areas,            .area_patterns = &area_patterns,    .lines = &lines,
        .points = &points,          .texts = &texts,
        .areas_scamin = &areas_s,   .area_patterns_scamin = &apat_s,    .lines_scamin = &lines_s,
        .points_scamin = &points_s, .texts_scamin = &texts_s,
    };
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
    try emitFromInstr(a, cell, f, 0, geo_one, null, symbolized, plain, null, 0, 0, 0, tb, box, L);
    // Both passes emit the fill: one tagged bnd=1 (symbolized), one bnd=0 (plain).
    try std.testing.expectEqual(@as(usize, 2), areas.items.len);
    try std.testing.expectEqual(@as(i64, 1), findProp(areas.items[0].properties, "bnd").?.int);
    try std.testing.expectEqual(@as(i64, 0), findProp(areas.items[1].properties, "bnd").?.int);
    // Symbolized + plain boundary line, each tagged with its pass's bnd.
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqual(@as(i64, 1), findProp(lines.items[0].properties, "bnd").?.int);
    try std.testing.expectEqual(@as(i64, 0), findProp(lines.items[1].properties, "bnd").?.int);
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
    const out = try generateTile(gpa, &cell, 14, 4711, 6262, null);
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
