//! No-op surface: discards all draw calls and returns empty bytes.
//!
//! Used for benchmarking the engine in isolation — run the same scene with
//! the noop surface to measure pure engine cost (portray + parse + project/clip).
//! Subtract from the MVT or PNG surface cost to get the per-format overhead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("surface.zig");

pub const NoopSurface = struct {
    const vtable = rs.Surface.VTable{
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

    pub fn init() NoopSurface {
        return .{};
    }

    pub fn asSurface(self: *NoopSurface) rs.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn beginScene(_: *anyopaque, _: u8) anyerror!void {}
    fn beginFeature(_: *anyopaque, _: *const rs.FeatureMeta) anyerror!void {}
    fn fillArea(_: *anyopaque, _: rs.ColorToken, _: []const []const rs.TilePoint, _: ?rs.DepthRange) anyerror!void {}
    fn fillPattern(_: *anyopaque, _: rs.SymbolName, _: []const []const rs.TilePoint) anyerror!void {}
    fn strokeLine(_: *anyopaque, _: rs.ColorToken, _: f64, _: rs.Dash, _: []const []const rs.TilePoint, _: ?f64) anyerror!void {}
    fn drawSymbol(_: *anyopaque, _: rs.SymbolName, _: rs.TilePoint, _: f64, _: f64, _: bool, _: rs.SymbolPlacement, _: ?f64) anyerror!void {}
    fn drawSounding(_: *anyopaque, _: f64, _: bool, _: bool, _: rs.TilePoint) anyerror!void {}
    fn drawText(_: *anyopaque, _: []const u8, _: *const rs.TextStyle, _: rs.TilePoint) anyerror!void {}
    fn endFeature(_: *anyopaque) anyerror!void {}
    fn endScene(_: *anyopaque, out: Allocator) anyerror![]u8 {
        return out.alloc(u8, 0);
    }
};

test "noop surface satisfies the full Surface lifecycle" {
    const a = std.testing.allocator;
    var ns = NoopSurface.init();
    const surf = ns.asSurface();

    try surf.beginScene(13);
    const meta = rs.FeatureMeta{ .display_priority = 5, .display_category = 1 };
    try surf.beginFeature(&meta);
    const ring = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 } };
    const rings = [_][]const rs.TilePoint{&ring};
    try surf.fillArea("DEPMS", &rings, .{ .d1 = 0, .d2 = 10 });
    try surf.fillPattern("DIAMOND1", &rings);
    try surf.strokeLine("CHBLK", 1.5, .dashed, &rings, 12.0);
    try surf.drawSymbol("BCNCAR01", .{ .x = 5, .y = 5 }, 0, 1, true, .point, 3.2);
    try surf.drawSounding(4.7, false, false, .{ .x = 5, .y = 5 });
    const style = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .halign = "center", .valign = "middle", .offset_x = 0, .offset_y = 0, .group = 25 };
    try surf.drawText("12", &style, .{ .x = 5, .y = 5 });
    try surf.endFeature();

    const out = try surf.endScene(a);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
