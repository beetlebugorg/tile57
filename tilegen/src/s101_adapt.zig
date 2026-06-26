//! S-57 -> S-101 feature adaptation for the portrayal engine: map each S-57
//! feature's object class to its S-101 feature class name and translate the
//! S-57 attribute codes the rules read into S-101 attribute names. A minimal,
//! growing port of internal/engine/s101/complex.go (resolveCode + buildRoot).
//!
//! The adapted features feed the Host* callbacks; geometry stays in s57.Cell and
//! is attached when instructions are translated to MVT.

const std = @import("std");
const s57 = @import("s57.zig");

pub const NameVal = struct { name: []const u8, value: []const u8 };

pub const Adapted = struct {
    feature_index: usize, // index into cell.features (for geometry)
    code: []const u8, // S-101 feature class name (== rule file name)
    primitive: []const u8, // "Point" | "Curve" | "Surface"
    attrs: []NameVal, // S-101 attribute name -> value
};

/// S-57 object class (OBJL) -> S-101 feature class name. Minimal set; grows as
/// classes are added. (Some S-57 classes alias by attribute — LIGHTS, MORFAC,
/// ADMARE — handled later.)
pub fn resolveCode(objl: u16) ?[]const u8 {
    return switch (objl) {
        42 => "DepthArea",
        46 => "DredgedArea",
        71 => "LandArea",
        119 => "BuiltUpArea",
        30 => "Coastline",
        122 => "ShorelineConstruction",
        74 => "DepthContour",
        129 => "Sounding",
        else => null,
    };
}

/// S-57 attribute code -> S-101 attribute name (the camelCase names the rules
/// read). Minimal set covering the supported classes.
fn s101AttrName(code: u16) ?[]const u8 {
    return switch (code) {
        s57.ATTR_DRVAL1 => "depthRangeMinimumValue",
        s57.ATTR_DRVAL2 => "depthRangeMaximumValue",
        s57.ATTR_VALSOU => "valueOfSounding",
        s57.ATTR_VALDCO => "valueOfDepthContour",
        else => null,
    };
}

fn primitiveName(prim: u8) []const u8 {
    return switch (prim) {
        1 => "Point",
        2 => "Curve",
        3 => "Surface",
        else => "",
    };
}

/// Adapt all mappable features of a cell. Allocates into `a` (use an arena).
pub fn adaptCell(a: std.mem.Allocator, cell: *const s57.Cell) ![]Adapted {
    var out = std.ArrayList(Adapted).empty;
    for (cell.features, 0..) |f, i| {
        const code = resolveCode(f.objl) orelse continue;
        const prim = primitiveName(f.prim);
        if (prim.len == 0) continue;
        var attrs = std.ArrayList(NameVal).empty;
        for (f.attrs) |at| {
            if (s101AttrName(at.code)) |name|
                try attrs.append(a, .{ .name = name, .value = at.value });
        }
        try out.append(a, .{ .feature_index = i, .code = code, .primitive = prim, .attrs = attrs.items });
    }
    return out.items;
}

test "adapt a depth area" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_DRVAL1, .value = "5" },
        .{ .code = s57.ATTR_DRVAL2, .value = "10" },
        .{ .code = 999, .value = "x" }, // unmapped -> dropped
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .attrs = &attrs },
        .{ .rcnm = 100, .rcid = 2, .prim = 1, .objl = 9999 }, // unmapped class -> dropped
    };
    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = std.AutoHashMap(u32, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer cell.arena.deinit();

    const adapted = try adaptCell(a, &cell);
    try std.testing.expectEqual(@as(usize, 1), adapted.len);
    try std.testing.expectEqualStrings("DepthArea", adapted[0].code);
    try std.testing.expectEqualStrings("Surface", adapted[0].primitive);
    try std.testing.expectEqual(@as(usize, 2), adapted[0].attrs.len);
    try std.testing.expectEqualStrings("depthRangeMinimumValue", adapted[0].attrs[0].name);
    try std.testing.expectEqualStrings("5", adapted[0].attrs[0].value);
}
