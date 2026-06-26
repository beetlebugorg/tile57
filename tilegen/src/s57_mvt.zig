//! Direct S-57 -> MVT tile generation (M6c demo, BYPASSING S-101 portrayal).
//!
//! Generates a vector tile for (z,x,y) straight from an S-57 cell with a small
//! hardcoded object-class -> S-52 color-token mapping, so the existing chart
//! style renders it. This proves cell -> MVT -> MapLibre end to end before the
//! S-101 Lua portrayal engine lands and replaces classify() with real rules.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57.zig");
const tile = @import("tile.zig");
const mvt = @import("mvt.zig");
const s101 = @import("s101_instr.zig");

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
        const props = try a.alloc(mvt.Prop, 3);
        props[0] = .{ .key = "sym_s", .value = .{ .string = sym_s } };
        props[1] = .{ .key = "sym_g", .value = .{ .string = sym_g } };
        props[2] = .{ .key = "depth", .value = .{ .double = s.depth } };
        try out.append(a, .{ .geom_type = .point, .parts = parts, .properties = props });
    }
}

fn overlaps(b0: [4]f64, b1: [4]f64) bool {
    return b0[0] <= b1[2] and b0[2] >= b1[0] and b0[1] <= b1[3] and b0[3] >= b1[1];
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
};

fn emitFromInstr(a: Allocator, cell: s57.Cell, f: s57.Feature, instr: []const u8, z: u8, x: u32, y: u32, tb: [4]f64, box: tile.Box, L: Layers) !void {
    const p = try s101.parse(a, instr);

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
            const props = try a.alloc(mvt.Prop, 3);
            props[0] = .{ .key = "symbol_name", .value = .{ .string = sym.symbol } };
            props[1] = .{ .key = "rotation_deg", .value = .{ .double = sym.rotation } };
            props[2] = .{ .key = "scale", .value = .{ .double = 0.08 } };
            try L.points.append(a, .{ .geom_type = .point, .parts = parts, .properties = props });
        }
        for (p.texts) |t| {
            const props = try a.alloc(mvt.Prop, 3);
            props[0] = .{ .key = "text", .value = .{ .string = t.text } };
            props[1] = .{ .key = "color_token", .value = .{ .string = t.color } };
            props[2] = .{ .key = "font_size_px", .value = .{ .double = 11 } };
            try L.texts.append(a, .{ .geom_type = .point, .parts = parts, .properties = props });
        }
        return;
    }

    // Line/area features: assemble into connected parts (rings / chains) so
    // disjoint geometry isn't joined by a spurious straight jump across the cell.
    const geo_parts = cell.lineGeometryParts(a, f) catch return;
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
        // Clip each ring once (each as its own polygon: avoids hole/winding
        // misinterpretation; correct for disjoint area parts).
        var rings = std.ArrayList([]const mvt.Point).empty;
        for (projected.items) |proj| {
            const ring = try tile.clipPolygon(a, proj, box);
            if (ring.len >= 3) try rings.append(a, ring);
        }
        if (p.fill_token) |token| {
            for (rings.items) |ring| {
                const parts = try a.alloc([]const mvt.Point, 1);
                parts[0] = ring;
                const props = try a.alloc(mvt.Prop, 1);
                props[0] = .{ .key = "color_token", .value = .{ .string = token } };
                try L.areas.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = props });
            }
        }
        // AreaFillReference -> a tiled fill pattern (DRGARE/FOUL/quality fills).
        for (p.patterns) |pat| {
            for (rings.items) |ring| {
                const parts = try a.alloc([]const mvt.Point, 1);
                parts[0] = ring;
                const props = try a.alloc(mvt.Prop, 1);
                props[0] = .{ .key = "pattern_name", .value = .{ .string = pat } };
                try L.area_patterns.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = props });
            }
        }
    }
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
            const props = try a.alloc(mvt.Prop, 3);
            props[0] = .{ .key = "color_token", .value = .{ .string = ln.color } };
            props[1] = .{ .key = "width_px", .value = .{ .double = ln.width } };
            props[2] = .{ .key = "dash", .value = .{ .string = dash } };
            try L.lines.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = props });
        }
    }
}

/// Generate MVT bytes (uncompressed) for tile (z,x,y) from `cell`.
/// `portrayal`, if given, is indexed by feature index and holds each feature's
/// S-101 instruction stream (from the Lua engine); features with an instruction
/// stream are styled by it, the rest fall back to classify().
pub fn generateTile(gpa: Allocator, cell: *s57.Cell, z: u8, x: u32, y: u32, portrayal: ?[]const ?[]const u8) ![]u8 {
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
    var soundings = std.ArrayList(mvt.Feature).empty;
    const layers_ctx = Layers{ .areas = &areas, .area_patterns = &area_patterns, .lines = &lines, .points = &points, .texts = &texts };

    for (cell.features, 0..) |f, fi| {
        // SOUNDG (objl 129) is multipoint: emit its SG3D soundings directly into
        // the `soundings` layer (the flat S-101 instruction stream can't carry
        // per-sounding geometry). Bypasses the portrayal/classify dispatch.
        if (f.objl == 129) {
            try emitSoundings(a, cell.*, f, z, x, y, tb, &soundings);
            continue;
        }
        // S-101 portrayal path: style this feature from its instruction stream.
        if (portrayal) |pp| {
            if (fi < pp.len) if (pp[fi]) |instr| {
                try emitFromInstr(a, cell.*, f, instr, z, x, y, tb, box, layers_ctx);
                continue;
            };
        }
        const cls = classify(f.objl);
        if (cls.kind == .skip) continue;
        const geo_parts = cell.lineGeometryParts(a, f) catch continue;
        if (geo_parts.len == 0) continue;

        for (geo_parts) |gp| {
            if (gp.len < 2) continue;
            if (!overlaps(geomBounds(gp), tb)) continue;
            const proj = try a.alloc(mvt.Point, gp.len);
            for (gp, 0..) |p, i| proj[i] = tile.project(p.lon, p.lat, z, x, y, tile.EXTENT);

            if (cls.kind == .area) {
                const ring = try tile.clipPolygon(a, proj, box);
                if (ring.len < 3) continue;
                const parts = try a.alloc([]const mvt.Point, 1);
                parts[0] = ring;
                // Depth areas carry DRVAL1/DRVAL2 so the style's SEABED01 shading
                // applies (areasFillColor keys on `drval1`).
                var aprops = std.ArrayList(mvt.Prop).empty;
                try aprops.append(a, .{ .key = "class", .value = .{ .string = cls.name } });
                try aprops.append(a, .{ .key = "color_token", .value = .{ .string = cls.color } });
                if (f.attrFloat(s57.ATTR_DRVAL1)) |d1| try aprops.append(a, .{ .key = "drval1", .value = .{ .double = d1 } });
                if (f.attrFloat(s57.ATTR_DRVAL2)) |d2| try aprops.append(a, .{ .key = "drval2", .value = .{ .double = d2 } });
                try areas.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = aprops.items });
            } else {
                const sub = try tile.clipLine(a, proj, box);
                if (sub.len == 0) continue;
                const parts = try a.alloc([]const mvt.Point, sub.len);
                for (sub, 0..) |s, i| parts[i] = s;
                const lprops = try a.alloc(mvt.Prop, 3);
                lprops[0] = .{ .key = "class", .value = .{ .string = cls.name } };
                lprops[1] = .{ .key = "color_token", .value = .{ .string = cls.color } };
                lprops[2] = .{ .key = "dash", .value = .{ .string = cls.dash } };
                try lines.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = lprops });
            }
        }
    }

    var layers = std.ArrayList(mvt.Layer).empty;
    if (areas.items.len > 0) try layers.append(a, .{ .name = "areas", .features = areas.items });
    if (area_patterns.items.len > 0) try layers.append(a, .{ .name = "area_patterns", .features = area_patterns.items });
    if (lines.items.len > 0) try layers.append(a, .{ .name = "lines", .features = lines.items });
    if (points.items.len > 0) try layers.append(a, .{ .name = "point_symbols", .features = points.items });
    if (soundings.items.len > 0) try layers.append(a, .{ .name = "soundings", .features = soundings.items });
    if (texts.items.len > 0) try layers.append(a, .{ .name = "text", .features = texts.items });
    if (layers.items.len == 0) return gpa.alloc(u8, 0); // empty tile

    return mvt.encode(gpa, .{ .layers = layers.items });
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
