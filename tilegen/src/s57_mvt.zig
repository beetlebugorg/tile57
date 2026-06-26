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
        74 => .{ .kind = .line, .name = "DEPCNT", .color = "DEPCN", .dash = "solid" }, // depth contour
        53 => .{ .kind = .line, .name = "DYKCON", .color = "CSTLN" },
        else => .{ .kind = .skip, .name = "", .color = "" },
    };
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

/// Generate MVT bytes (uncompressed) for tile (z,x,y) from `cell`.
pub fn generateTile(gpa: Allocator, cell: *s57.Cell, z: u8, x: u32, y: u32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const tb = tile.tileBoundsLonLat(z, x, y);
    const box = tile.Box.default(tile.EXTENT, tile.BUFFER);

    var areas = std.ArrayList(mvt.Feature).empty;
    var lines = std.ArrayList(mvt.Feature).empty;

    for (cell.features) |f| {
        const cls = classify(f.objl);
        if (cls.kind == .skip) continue;
        const g = cell.lineGeometry(a, f) catch continue;
        if (g.len < 2) continue;
        if (!overlaps(geomBounds(g), tb)) continue;

        // Project to tile coordinates.
        const proj = try a.alloc(mvt.Point, g.len);
        for (g, 0..) |p, i| proj[i] = tile.project(p.lon, p.lat, z, x, y, tile.EXTENT);

        const props = try a.alloc(mvt.Prop, 2);
        props[0] = .{ .key = "class", .value = .{ .string = cls.name } };
        props[1] = .{ .key = "color_token", .value = .{ .string = cls.color } };

        if (cls.kind == .area) {
            const ring = try tile.clipPolygon(a, proj, box);
            if (ring.len < 3) continue;
            const parts = try a.alloc([]const mvt.Point, 1);
            parts[0] = ring;
            try areas.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = props });
        } else {
            const sub = try tile.clipLine(a, proj, box);
            if (sub.len == 0) continue;
            const parts = try a.alloc([]const mvt.Point, sub.len);
            for (sub, 0..) |s, i| parts[i] = s;
            const lprops = try a.alloc(mvt.Prop, 3);
            lprops[0] = props[0];
            lprops[1] = props[1];
            lprops[2] = .{ .key = "dash", .value = .{ .string = cls.dash } };
            try lines.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = lprops });
        }
    }

    var layers = std.ArrayList(mvt.Layer).empty;
    if (areas.items.len > 0) try layers.append(a, .{ .name = "areas", .features = areas.items });
    if (lines.items.len > 0) try layers.append(a, .{ .name = "lines", .features = lines.items });
    if (layers.items.len == 0) return gpa.alloc(u8, 0); // empty tile

    return mvt.encode(gpa, .{ .layers = layers.items });
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
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer cell.deinit();
    const out = try generateTile(gpa, &cell, 14, 4711, 6262);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
