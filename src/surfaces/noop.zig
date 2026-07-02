//! No-op surface: discards all draw calls and returns empty bytes.
//!
//! Used for benchmarking the engine in isolation — run the same scene with
//! the noop surface to measure pure engine cost (portray + parse + project/clip).
//! Subtract from the MVT or PNG surface cost to get the per-format overhead.
//!
//! See specs/render-engine.md §Non-goals (v1) and §Verification gates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("render_surface");

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
    fn drawSymbol(_: *anyopaque, _: rs.SymbolName, _: rs.TilePoint, _: f64, _: f64, _: bool, _: ?f64) anyerror!void {}
    fn drawSounding(_: *anyopaque, _: f64, _: bool, _: bool, _: rs.TilePoint) anyerror!void {}
    fn drawText(_: *anyopaque, _: []const u8, _: *const rs.TextStyle, _: rs.TilePoint) anyerror!void {}
    fn endFeature(_: *anyopaque) anyerror!void {}
    fn endScene(_: *anyopaque, out: Allocator) anyerror![]u8 {
        return out.alloc(u8, 0);
    }
};
