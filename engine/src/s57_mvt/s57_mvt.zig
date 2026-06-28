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
const s101 = @import("s100").s101_instr;

// S-52 symbol scale the Go baker emits for every point symbol / sounding. The
// style's icon-size = scale / ATLAS_PPU (0.08), so this renders symbols at
// ~0.354 — matching the reference. The live path previously used 0.08 (icon
// size 1.0), i.e. ~2.8x too large.
const SYMBOL_SCALE: f64 = 0.02834627777338028;

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

/// Port of SNDFRM04's core digit composition (the SOUNDG03 path): build the
/// comma-joined sounding glyph-name string for a depth and prefix ("SOUNDS"
/// bold/shallow or "SOUNDG" faint/deep). Omits the swept / low-accuracy-ring /
/// negative-value prefixes (they need quality attributes we don't read yet), so
/// soundings flagged with those won't match a sprite composite; the common ones
/// do. Returns "" for depths we don't compose (>= 1000 m).
fn sndfrmSyms(a: Allocator, prefix: []const u8, depth: f64) ![]const u8 {
    const d = @abs(depth);
    const tenths: i64 = @intFromFloat(@round(d * 10.0));
    const idepth: i64 = @divTrunc(tenths, 10);
    const frac: u8 = @intCast(@mod(tenths, 10));
    var dbuf: [8]u8 = undefined;
    const ds = std.fmt.bufPrint(&dbuf, "{d}", .{idepth}) catch return "";
    var toks = std.ArrayList([]const u8).empty;
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
    } else return "";
    return std.mem.join(a, ",", toks.items);
}

/// Emit a SOUNDG feature's multipoint soundings into the `soundings` layer, one
/// point per sounding, with sym_s/sym_g/depth so the style's SNDFRM glyphs and
/// the mariner safety-depth switch (soundings_image) render the depth digits.
fn emitSoundings(a: Allocator, cell: s57.Cell, f: s57.Feature, z: u8, x: u32, y: u32, tb: [4]f64, out: *std.ArrayList(mvt.Feature)) !void {
    const snds = cell.soundingsFor(a, f) catch return;
    for (snds) |s| {
        if (s.lon < tb[0] or s.lon > tb[2] or s.lat < tb[1] or s.lat > tb[3]) continue;
        const sym_s = try sndfrmSyms(a, "SOUNDS", s.depth);
        if (sym_s.len == 0) continue;
        const sym_g = try sndfrmSyms(a, "SOUNDG", s.depth);
        const pt = tile.project(s.lon, s.lat, z, x, y, tile.EXTENT);
        const parts = try a.alloc([]const mvt.Point, 1);
        const single = try a.alloc(mvt.Point, 1);
        single[0] = pt;
        parts[0] = single;
        const props = try a.alloc(mvt.Prop, 4);
        props[0] = .{ .key = "sym_s", .value = .{ .string = sym_s } };
        props[1] = .{ .key = "sym_g", .value = .{ .string = sym_g } };
        props[2] = .{ .key = "depth", .value = .{ .double = s.depth } };
        props[3] = .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } };
        try out.append(a, .{ .geom_type = .point, .parts = parts, .properties = props });
    }
}

fn overlaps(b0: [4]f64, b1: [4]f64) bool {
    return b0[0] <= b1[2] and b0[2] >= b1[0] and b0[1] <= b1[3] and b0[3] >= b1[1];
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
        b[0] = @min(b[0], p.lon);
        b[1] = @min(b[1], p.lat);
        b[2] = @max(b[2], p.lon);
        b[3] = @max(b[3], p.lat);
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
};

/// SCAMIN (1:N) denominator the feature carries, or null when absent/invalid.
fn featureScamin(f: s57.Feature) ?i64 {
    const v = f.attr(ATTR_SCAMIN) orelse return null;
    const n = std.fmt.parseInt(i64, std.mem.trim(u8, v, " "), 10) catch return null;
    return if (n > 0) n else null;
}

/// Append the metadata tags shared by every emitFromInstr feature: the S-52
/// draw priority (always) and, for SCAMIN-gated features, the 1:N denominator.
fn appendMeta(a: Allocator, props: *std.ArrayList(mvt.Prop), draw_prio: i64, scamin: ?i64) !void {
    try props.append(a, .{ .key = "draw_prio", .value = .{ .int = draw_prio } });
    if (scamin) |sc| try props.append(a, .{ .key = "scamin", .value = .{ .int = sc } });
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
        parts[i] = if (f.prim == 2 or f.prim == 3) (cell.lineGeometryParts(a, f) catch null) else null;
    }
    return parts;
}

/// The feature's assembled line/area parts: the baker's cached copy if present,
/// else assembled now (the live path).
fn featureParts(a: Allocator, cell: s57.Cell, geo: ?GeoParts, fi: usize, f: s57.Feature) ![][]s57.LonLat {
    if (geo) |g| if (fi < g.len) if (g[fi]) |p| return p;
    return cell.lineGeometryParts(a, f);
}

fn emitFromInstr(a: Allocator, cell: s57.Cell, f: s57.Feature, fi: usize, geo: ?GeoParts, instr: []const u8, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, L: Layers) !void {
    const p = try s101.parse(a, instr);
    const prio = p.draw_prio;

    // Route each feature into its base layer or the *_scamin bucket depending on
    // whether it carries a SCAMIN (1:N) display limit. Same geometry/properties
    // either way; the bucket lets the style gate the feature below its scale.
    const scamin = featureScamin(f);
    const areas_l = if (scamin != null) L.areas_scamin else L.areas;
    const apat_l = if (scamin != null) L.area_patterns_scamin else L.area_patterns;
    const lines_l = if (scamin != null) L.lines_scamin else L.lines;
    const points_l = if (scamin != null) L.points_scamin else L.points;
    const texts_l = if (scamin != null) L.texts_scamin else L.texts;

    // Point features (buoys/beacons/lights/landmarks/soundings): symbols + text
    // placed at the feature's node.
    if (f.prim == 1) {
        const pg = cell.pointGeometry(f) orelse return;
        if (pg.lon < tb[0] or pg.lon > tb[2] or pg.lat < tb[1] or pg.lat > tb[3]) return;
        const pt = tile.project(pg.lon, pg.lat, z, x, y, tile.EXTENT);
        const parts = try a.alloc([]const mvt.Point, 1);
        const single = try a.alloc(mvt.Point, 1);
        single[0] = pt;
        parts[0] = single;
        for (p.points) |sym| {
            var props = std.ArrayList(mvt.Prop).empty;
            try props.append(a, .{ .key = "symbol_name", .value = .{ .string = sym.symbol } });
            try props.append(a, .{ .key = "rotation_deg", .value = .{ .double = sym.rotation } });
            try props.append(a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
            try appendMeta(a, &props, prio, scamin);
            try points_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
        }
        for (p.texts) |t| {
            var props = std.ArrayList(mvt.Prop).empty;
            try props.append(a, .{ .key = "text", .value = .{ .string = t.text } });
            try props.append(a, .{ .key = "color_token", .value = .{ .string = t.color } });
            try props.append(a, .{ .key = "font_size_px", .value = .{ .double = 11 } });
            try appendMeta(a, &props, prio, scamin);
            try texts_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
        }
        return;
    }

    // Line/area features: assemble into connected parts (rings / chains) so
    // disjoint geometry isn't joined by a spurious straight jump across the cell.
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    // Project each usable part; quick-reject if none overlap the tile.
    var projected = std.ArrayList([]mvt.Point).empty;
    var any_overlap = false;
    for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (overlaps(geomBounds(gp), tb)) any_overlap = true;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon, pt.lat, z, x, y, tile.EXTENT);
        try projected.append(a, proj);
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
            const ring = try tile.clipPolygon(a, proj, box);
            if (ring.len >= 3) try rings.append(a, ring);
        }
        if (rings.items.len > 0) {
            const parts = try orientAreaRings(a, rings.items);
            if (p.fill_token) |token| {
                var props = std.ArrayList(mvt.Prop).empty;
                try props.append(a, .{ .key = "color_token", .value = .{ .string = token } });
                try appendMeta(a, &props, prio, scamin);
                try areas_l.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = props.items });
            }
            // AreaFillReference -> a tiled fill pattern (DRGARE/FOUL/quality fills).
            for (p.patterns) |pat| {
                var props = std.ArrayList(mvt.Prop).empty;
                try props.append(a, .{ .key = "pattern_name", .value = .{ .string = pat } });
                try appendMeta(a, &props, prio, scamin);
                try apat_l.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = props.items });
            }
        }
    }
    // DEPCNT depth-contour value (metres), incl. the 0 m drying/chart-datum line:
    // baked whenever VALDCO is explicitly present (even 0) so the style can label
    // it; a missing VALDCO is unknown, not zero, so it's left off. Mirrors the Go
    // contourValdco fix (no `> 0` drop).
    const valdco: ?f64 = if (f.objl == 43) f.attrFloat(s57.ATTR_VALDCO) else null;

    for (p.lines) |ln| {
        // _simple_ -> solid; any named/complex line style (NAVLNE/RECTRC leading
        // lines, CTNARE limits, …) is approximated as dashed rather than a bold
        // solid stroke (full along-line symbology is a later step).
        const dash: []const u8 = if (std.mem.eql(u8, ln.style, "solid")) "solid" else "dashed";
        for (projected.items) |proj| {
            const sub = try tile.clipLine(a, proj, box);
            if (sub.len == 0) continue;
            const parts = try a.alloc([]const mvt.Point, sub.len);
            for (sub, 0..) |s, i| parts[i] = s;
            var props = std.ArrayList(mvt.Prop).empty;
            try props.append(a, .{ .key = "color_token", .value = .{ .string = ln.color } });
            try props.append(a, .{ .key = "width_px", .value = .{ .double = ln.width } });
            try props.append(a, .{ .key = "dash", .value = .{ .string = dash } });
            if (valdco) |v| try props.append(a, .{ .key = "valdco", .value = .{ .double = v } });
            try appendMeta(a, &props, prio, scamin);
            try lines_l.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = props.items });
        }
    }

    // Area / line labels (TextInstruction): placed at the area representative
    // point (centre of gravity; see areaRepresentativePoint). Without this only
    // point-feature labels show, so area/channel/place names were missing.
    if (p.texts.len > 0) {
        if (s57.areaRepresentativePoint(geo_parts)) |rp| {
            if (rp.lon >= tb[0] and rp.lon <= tb[2] and rp.lat >= tb[1] and rp.lat <= tb[3]) {
                const cpt = tile.project(rp.lon, rp.lat, z, x, y, tile.EXTENT);
                const parts = try a.alloc([]const mvt.Point, 1);
                const single = try a.alloc(mvt.Point, 1);
                single[0] = cpt;
                parts[0] = single;
                for (p.texts) |t| {
                    var props = std.ArrayList(mvt.Prop).empty;
                    try props.append(a, .{ .key = "text", .value = .{ .string = t.text } });
                    try props.append(a, .{ .key = "color_token", .value = .{ .string = t.color } });
                    try props.append(a, .{ .key = "font_size_px", .value = .{ .double = 11 } });
                    try appendMeta(a, &props, prio, scamin);
                    try texts_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = props.items });
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
    const prio: i64 = 6;

    // Dashed CHGRD boundary on each ring (clipped to the tile).
    for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon, pt.lat, z, x, y, tile.EXTENT);
        const sub = try tile.clipLine(a, proj, box);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(a, .{ .key = "color_token", .value = .{ .string = "CHGRD" } });
        try props.append(a, .{ .key = "width_px", .value = .{ .double = 1 } });
        try props.append(a, .{ .key = "dash", .value = .{ .string = "dashed" } });
        try appendMeta(a, &props, prio, scamin);
        try lines_l.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = props.items });
    }

    // SWPARE51 bracket + "swept to <DRVAL1>" label at the representative point.
    const rp = s57.areaRepresentativePoint(geo_parts) orelse return;
    if (rp.lon < tb[0] or rp.lon > tb[2] or rp.lat < tb[1] or rp.lat > tb[3]) return;
    const cpt = tile.project(rp.lon, rp.lat, z, x, y, tile.EXTENT);
    const parts = try a.alloc([]const mvt.Point, 1);
    const single = try a.alloc(mvt.Point, 1);
    single[0] = cpt;
    parts[0] = single;

    var sprops = std.ArrayList(mvt.Prop).empty;
    try sprops.append(a, .{ .key = "symbol_name", .value = .{ .string = "SWPARE51" } });
    try sprops.append(a, .{ .key = "rotation_deg", .value = .{ .double = 0 } });
    try sprops.append(a, .{ .key = "scale", .value = .{ .double = SYMBOL_SCALE } });
    try appendMeta(a, &sprops, prio, scamin);
    try points_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = sprops.items });

    if (f.attrFloat(s57.ATTR_DRVAL1)) |d1| {
        const label = try std.fmt.allocPrint(a, "swept to {d}", .{d1});
        var tprops = std.ArrayList(mvt.Prop).empty;
        try tprops.append(a, .{ .key = "text", .value = .{ .string = label } });
        try tprops.append(a, .{ .key = "color_token", .value = .{ .string = "CHBLK" } });
        try tprops.append(a, .{ .key = "font_size_px", .value = .{ .double = 11 } });
        try appendMeta(a, &tprops, prio, scamin);
        try texts_l.append(a, .{ .geom_type = .point, .parts = parts, .properties = tprops.items });
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
    const geo_parts = featureParts(a, cell, geo, fi, f) catch return;
    if (geo_parts.len == 0) return;

    const scamin = featureScamin(f);
    const lines_l = if (scamin != null) L.lines_scamin else L.lines;
    for (geo_parts) |gp| {
        if (gp.len < 2) continue;
        if (!overlaps(geomBounds(gp), tb)) continue;
        const proj = try a.alloc(mvt.Point, gp.len);
        for (gp, 0..) |pt, i| proj[i] = tile.project(pt.lon, pt.lat, z, x, y, tile.EXTENT);
        const sub = try tile.clipLine(a, proj, box);
        if (sub.len == 0) continue;
        const parts = try a.alloc([]const mvt.Point, sub.len);
        for (sub, 0..) |s, i| parts[i] = s;
        var props = std.ArrayList(mvt.Prop).empty;
        try props.append(a, .{ .key = "color_token", .value = .{ .string = color } });
        try props.append(a, .{ .key = "width_px", .value = .{ .double = width } });
        try props.append(a, .{ .key = "dash", .value = .{ .string = "dashed" } });
        try appendMeta(a, &props, 6, scamin);
        try lines_l.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = props.items });
    }
}

/// One cell plus its optional per-feature S-101 instruction streams.
pub const CellRef = struct { cell: *s57.Cell, portrayal: ?[]const ?[]const u8 = null, geo: ?GeoParts = null };

/// Generate MVT bytes (uncompressed) for tile (z,x,y) from a single `cell`.
/// `portrayal`, if given, is indexed by feature index and holds each feature's
/// S-101 instruction stream (from the Lua engine); features with an instruction
/// stream are styled by it, the rest fall back to classify().
pub fn generateTile(gpa: Allocator, cell: *s57.Cell, z: u8, x: u32, y: u32, portrayal: ?[]const ?[]const u8) ![]u8 {
    const one = [_]CellRef{.{ .cell = cell, .portrayal = portrayal }};
    return generateTileMulti(gpa, &one, z, x, y);
}

/// Generate MVT bytes (uncompressed) for tile (z,x,y) overlaying one or more
/// cells (an ENC_ROOT). Each cell's features are appended into the shared layers,
/// so a tile spanning several cells carries all of them.
pub fn generateTileMulti(gpa: Allocator, cells: []const CellRef, z: u8, x: u32, y: u32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

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
    };

    for (cells) |cr| try appendCellFeatures(a, layers_ctx, &soundings, cr.cell, cr.portrayal, cr.geo, z, x, y, tb, box);

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
    if (layers.items.len == 0) return gpa.alloc(u8, 0); // empty tile

    return mvt.encode(gpa, .{ .layers = layers.items });
}

/// Append one cell's features for tile (z,x,y) into the shared layer lists.
fn appendCellFeatures(
    a: Allocator,
    L: Layers,
    soundings: *std.ArrayList(mvt.Feature),
    cell: *s57.Cell,
    portrayal: ?[]const ?[]const u8,
    geo: ?GeoParts,
    z: u8,
    x: u32,
    y: u32,
    tb: [4]f64,
    box: tile.Box,
) !void {
    for (cell.features, 0..) |f, fi| {
        // SOUNDG (objl 129) is multipoint: emit its SG3D soundings directly into
        // the `soundings` layer (the flat S-101 instruction stream can't carry
        // per-sounding geometry). Bypasses the portrayal/classify dispatch.
        if (f.objl == 129) {
            try emitSoundings(a, cell.*, f, z, x, y, tb, soundings);
            continue;
        }
        // S-101 portrayal stream for this feature: null = unmapped/unportrayed; an
        // "ERROR:" marker = the rule raised. A usable stream styles the feature;
        // otherwise fall through to the native S-52 fallbacks / classify().
        const stream: ?[]const u8 = if (portrayal) |pp| (if (fi < pp.len) pp[fi] else null) else null;
        const errored = stream != null and std.mem.startsWith(u8, stream.?, "ERROR:");
        if (stream) |s| {
            if (!errored) {
                try emitFromInstr(a, cell.*, f, fi, geo, s, z, x, y, tb, box, L);
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
        if (errored) continue; // genuine rule error on a normal class → suppress
        const cls = classify(f.objl);
        if (cls.kind == .skip) continue;
        const geo_parts = featureParts(a, cell.*, geo, fi, f) catch continue;
        if (geo_parts.len == 0) continue;

        if (cls.kind == .area) {
            // Collect the feature's clipped rings, then emit ONE multipolygon with
            // holes subtracted (see orientAreaRings) — same fix as the portrayal
            // path so a sea/depth hole over an island isn't filled.
            var rings = std.ArrayList([]const mvt.Point).empty;
            for (geo_parts) |gp| {
                if (gp.len < 2) continue;
                if (!overlaps(geomBounds(gp), tb)) continue;
                const proj = try a.alloc(mvt.Point, gp.len);
                for (gp, 0..) |p, i| proj[i] = tile.project(p.lon, p.lat, z, x, y, tile.EXTENT);
                const ring = try tile.clipPolygon(a, proj, box);
                if (ring.len >= 3) try rings.append(a, ring);
            }
            if (rings.items.len == 0) continue;
            const parts = try orientAreaRings(a, rings.items);
            // Depth areas carry DRVAL1/DRVAL2 so the style's SEABED01 shading
            // applies (areasFillColor keys on `drval1`).
            var aprops = std.ArrayList(mvt.Prop).empty;
            try aprops.append(a, .{ .key = "class", .value = .{ .string = cls.name } });
            try aprops.append(a, .{ .key = "color_token", .value = .{ .string = cls.color } });
            if (f.attrFloat(s57.ATTR_DRVAL1)) |d1| try aprops.append(a, .{ .key = "drval1", .value = .{ .double = d1 } });
            if (f.attrFloat(s57.ATTR_DRVAL2)) |d2| try aprops.append(a, .{ .key = "drval2", .value = .{ .double = d2 } });
            try L.areas.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = aprops.items });
            continue;
        }

        for (geo_parts) |gp| {
            if (gp.len < 2) continue;
            if (!overlaps(geomBounds(gp), tb)) continue;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (gp, 0..) |p, i| proj[i] = tile.project(p.lon, p.lat, z, x, y, tile.EXTENT);
            const sub = try tile.clipLine(a, proj, box);
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
    try std.testing.expectEqualStrings("SOUNDS12,SOUNDS57", try sndfrmSyms(a, "SOUNDS", 2.7));
    try std.testing.expectEqualStrings("SOUNDS10,SOUNDS56", try sndfrmSyms(a, "SOUNDS", 0.6));
    try std.testing.expectEqualStrings("SOUNDS15", try sndfrmSyms(a, "SOUNDS", 5.0));
    try std.testing.expectEqualStrings("SOUNDG22,SOUNDG11,SOUNDG56", try sndfrmSyms(a, "SOUNDG", 21.6));
    try std.testing.expectEqualStrings("SOUNDS14,SOUNDS07", try sndfrmSyms(a, "SOUNDS", 47.0));
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
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 1, .{ .lon = 0, .lat = 0 });

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
    try emitFromInstr(a, cell, f_sc, 0, null, "DrawingPriority:7;PointInstruction:BOYLAT01", 0, 0, 0, tb, box, L);
    try std.testing.expectEqual(@as(usize, 0), points.items.len);
    try std.testing.expectEqual(@as(usize, 1), points_s.items.len);
    try std.testing.expectEqual(@as(i64, 7), findProp(points_s.items[0].properties, "draw_prio").?.int);
    try std.testing.expectEqual(@as(i64, 22000), findProp(points_s.items[0].properties, "scamin").?.int);

    // No SCAMIN -> base point_symbols layer, draw_prio default 0, no scamin.
    const f_base = s57.Feature{
        .rcnm = 0, .rcid = 2, .prim = 1, .objl = 14,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }},
    };
    try emitFromInstr(a, cell, f_base, 0, null, "PointInstruction:BOYLAT01", 0, 0, 0, tb, box, L);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(i64, 0), findProp(points.items[0].properties, "draw_prio").?.int);
    try std.testing.expectEqual(@as(?mvt.Value, null), findProp(points.items[0].properties, "scamin"));
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
