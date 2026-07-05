//! Differential test: decode a real Go-baked MVT tile (extracted from
//! reference/tiles/annapolis.pmtiles, z14/4711/6262, gunzipped) and check the
//! Zig decoder against the Go oracle's known layer/feature counts and a sample
//! property. Then re-encode it with the Zig encoder and confirm a clean
//! round-trip — validating the encoder on real-world feature shapes.

const std = @import("std");
const mvt = @import("tiles").mvt;
const mlt = @import("tiles").mlt;

const fixture = @embedFile("mvt_fixture");

fn findLayer(layers: []mvt.DecodedLayer, name: []const u8) mvt.DecodedLayer {
    for (layers) |L| if (std.mem.eql(u8, L.name, name)) return L;
    unreachable;
}

fn prop(f: mvt.DecodedFeature, key: []const u8) ?mvt.Value {
    for (f.properties) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

test "decode real Go-baked tile matches the oracle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const layers = try mvt.decode(a, fixture);
    try std.testing.expectEqual(@as(usize, 11), layers.len);

    var counts = std.StringHashMap(usize).init(a);
    for (layers) |L| {
        try std.testing.expectEqual(@as(u32, 4096), L.extent);
        try counts.put(L.name, L.features.len);
    }
    // Expected per-layer feature counts for the embedded fixture tile (cross-
    // checked against `tile57 inspect` over the same tile).
    try std.testing.expectEqual(@as(usize, 104), counts.get("areas").?);
    try std.testing.expectEqual(@as(usize, 138), counts.get("areas_scamin").?);
    try std.testing.expectEqual(@as(usize, 146), counts.get("lines").?);
    try std.testing.expectEqual(@as(usize, 386), counts.get("point_symbols").?);
    try std.testing.expectEqual(@as(usize, 283), counts.get("soundings").?);
    try std.testing.expectEqual(@as(usize, 68), counts.get("text").?);

    const areas = findLayer(layers, "areas");
    try std.testing.expectEqualStrings("OBSTRN", prop(areas.features[0], "class").?.string);
    try std.testing.expectEqualStrings("DEPVS", prop(areas.features[0], "color_token").?.string);

    // A point feature decodes to a single point.
    const psym = findLayer(layers, "point_symbols");
    try std.testing.expectEqual(mvt.GeomType.point, psym.features[0].geom_type);
    try std.testing.expectEqual(@as(usize, 1), psym.features[0].parts.len);
    try std.testing.expectEqual(@as(usize, 1), psym.features[0].parts[0].len);
}

test "re-encode the real tile round-trips (encoder on real shapes)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const layers = try mvt.decode(a, fixture);

    // Convert decoded layers back into encoder input.
    var enc_layers = std.ArrayList(mvt.Layer).empty;
    for (layers) |L| {
        var feats = std.ArrayList(mvt.Feature).empty;
        for (L.features) |f| {
            try feats.append(a, .{
                .geom_type = f.geom_type,
                .parts = f.parts,
                .properties = f.properties,
            });
        }
        try enc_layers.append(a, .{ .name = L.name, .extent = L.extent, .features = feats.items });
    }

    const bytes = try mvt.encode(std.testing.allocator, .{ .layers = enc_layers.items });
    defer std.testing.allocator.free(bytes);

    // Decode again; the layer/feature structure must be identical.
    const layers2 = try mvt.decode(a, bytes);
    try std.testing.expectEqual(layers.len, layers2.len);
    for (layers, layers2) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqual(x.features.len, y.features.len);
    }

    // Spot-check geometry survived: every polygon ring keeps its vertex count.
    const a1 = findLayer(layers, "areas");
    const a2 = findLayer(layers2, "areas");
    for (a1.features, a2.features) |f1, f2| {
        try std.testing.expectEqual(f1.parts.len, f2.parts.len);
        for (f1.parts, f2.parts) |r1, r2|
            try std.testing.expectEqual(r1.len, r2.len);
    }
}

test "MLT re-encode of the real tile matches the MVT decode (cross-codec parity)" {
    // mlt-default.md acceptance: an MLT bake of the same model must decode to the
    // SAME layer/feature structure an MVT bake does — the bundle's post-bake
    // collection (sounding composites + SCAMIN manifest) and the JS renderer both
    // ride on that equivalence.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const layers = try mvt.decode(a, fixture);

    var enc_layers = std.ArrayList(mvt.Layer).empty;
    for (layers) |L| {
        var feats = std.ArrayList(mvt.Feature).empty;
        for (L.features) |f| {
            try feats.append(a, .{ .geom_type = f.geom_type, .parts = f.parts, .properties = f.properties });
        }
        try enc_layers.append(a, .{ .name = L.name, .extent = L.extent, .features = feats.items });
    }

    const bytes = try mlt.encode(std.testing.allocator, .{ .layers = enc_layers.items });
    defer std.testing.allocator.free(bytes);

    const layers2 = try mlt.decode(a, bytes);
    try std.testing.expectEqual(layers.len, layers2.len);
    for (layers, layers2) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqual(x.extent, y.extent);
        try std.testing.expectEqual(x.features.len, y.features.len);
        // Geometry parity: every feature keeps its type, part count and vertices.
        for (x.features, y.features) |f1, f2| {
            try std.testing.expectEqual(f1.geom_type, f2.geom_type);
            try std.testing.expectEqual(f1.parts.len, f2.parts.len);
            for (f1.parts, f2.parts) |r1, r2| {
                try std.testing.expectEqual(r1.len, r2.len);
                for (r1, r2) |p1, p2| try std.testing.expectEqual(p1, p2);
            }
        }
    }

    // Property parity on the streams the BakeSink collector depends on: the
    // scamin denominators (SCAMIN ladder) and the soundings glyph stacks
    // (sym_s/sym_g composites) must survive the MLT round-trip unchanged.
    for (layers, layers2) |x, y| {
        for (x.features, y.features) |f1, f2| {
            for ([_][]const u8{ "scamin", "sym_s", "sym_g", "sym_s_ft", "sym_g_ft", "symbol_names", "class", "color_token" }) |key| {
                const v1 = prop(f1, key) orelse continue;
                const v2 = prop(f2, key) orelse return error.MissingProp;
                switch (v1) {
                    .string => |s| try std.testing.expectEqualStrings(s, v2.string),
                    .int => |n| try std.testing.expectEqual(n, v2.int),
                    else => {},
                }
            }
        }
    }
}
