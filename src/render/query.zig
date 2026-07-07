//! QuerySurface: a Surface backend for cursor object-query (S-52 §10.8 pick).
//! Given a point in a tile's local coordinates, it replays that tile and records
//! which features the point falls in — area point-in-polygon, line/point within
//! a small radius — reporting each hit feature's S-57 class + attribute JSON +
//! source cell through a C callback. The engine hands the class/s57_json/cell on
//! the FeatureMeta contract, so no S-57 decode is needed here.
const std = @import("std");
const rs = @import("surface.zig");

/// C callback: one call per feature the query point falls in. Pointers are valid
/// only for the duration of the call.
pub const QueryCb = extern struct {
    ctx: ?*anyopaque,
    feature: *const fn (?*anyopaque, cls: [*]const u8, cls_len: usize, s57: [*]const u8, s57_len: usize, cell: [*]const u8, cell_len: usize) callconv(.c) void,
};

pub const QuerySurface = struct {
    qx: f64,
    qy: f64,
    radius: f64, // near-hit radius for line/point features (tile units)
    cb: *const QueryCb,
    cur: rs.FeatureMeta = .{},
    hit: bool = false,

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

    pub fn asSurface(self: *QuerySurface) rs.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn sp(ctx: *anyopaque) *QuerySurface {
        return @ptrCast(@alignCast(ctx));
    }

    fn beginScene(_: *anyopaque, _: u8) anyerror!void {}
    fn beginFeature(ctx: *anyopaque, meta: *const rs.FeatureMeta) anyerror!void {
        const self = sp(ctx);
        self.cur = meta.*;
        self.hit = false;
    }
    fn endFeature(ctx: *anyopaque) anyerror!void {
        const self = sp(ctx);
        if (!self.hit) return;
        const m = self.cur;
        self.cb.feature(self.cb.ctx, m.class.ptr, m.class.len, m.s57_json.ptr, m.s57_json.len, m.cell_name.ptr, m.cell_name.len);
    }
    fn endScene(_: *anyopaque, out: std.mem.Allocator) anyerror![]u8 {
        return out.alloc(u8, 0);
    }

    // ---- point tests (tile-local coordinates) ------------------------------
    fn pointInRings(self: *QuerySurface, rings: []const []const rs.TilePoint) bool {
        // Even-odd across every ring (exterior + holes): a point in a hole
        // toggles twice and is correctly excluded.
        var inside = false;
        for (rings) |ring| {
            if (ring.len < 3) continue;
            var j: usize = ring.len - 1;
            var i: usize = 0;
            while (i < ring.len) : (i += 1) {
                const xi: f64 = @floatFromInt(ring[i].x);
                const yi: f64 = @floatFromInt(ring[i].y);
                const xj: f64 = @floatFromInt(ring[j].x);
                const yj: f64 = @floatFromInt(ring[j].y);
                if ((yi > self.qy) != (yj > self.qy)) {
                    const xint = (xj - xi) * (self.qy - yi) / (yj - yi) + xi;
                    if (self.qx < xint) inside = !inside;
                }
                j = i;
            }
        }
        return inside;
    }
    fn distSeg(self: *QuerySurface, a: rs.TilePoint, b: rs.TilePoint) f64 {
        const ax: f64 = @floatFromInt(a.x);
        const ay: f64 = @floatFromInt(a.y);
        const dx: f64 = @as(f64, @floatFromInt(b.x)) - ax;
        const dy: f64 = @as(f64, @floatFromInt(b.y)) - ay;
        const len2 = dx * dx + dy * dy;
        var t: f64 = 0;
        if (len2 > 1e-9) t = std.math.clamp(((self.qx - ax) * dx + (self.qy - ay) * dy) / len2, 0, 1);
        const ex = self.qx - (ax + t * dx);
        const ey = self.qy - (ay + t * dy);
        return @sqrt(ex * ex + ey * ey);
    }
    fn nearLines(self: *QuerySurface, lines: []const []const rs.TilePoint) bool {
        for (lines) |line| {
            var k: usize = 0;
            while (k + 1 < line.len) : (k += 1)
                if (self.distSeg(line[k], line[k + 1]) <= self.radius) return true;
        }
        return false;
    }
    fn nearPoint(self: *QuerySurface, at: rs.TilePoint) bool {
        const dx = @as(f64, @floatFromInt(at.x)) - self.qx;
        const dy = @as(f64, @floatFromInt(at.y)) - self.qy;
        return dx * dx + dy * dy <= self.radius * self.radius;
    }

    fn fillArea(ctx: *anyopaque, _: rs.ColorToken, rings: []const []const rs.TilePoint, _: ?rs.DepthRange) anyerror!void {
        const self = sp(ctx);
        if (self.pointInRings(rings)) self.hit = true;
    }
    fn fillPattern(ctx: *anyopaque, _: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.pointInRings(rings)) self.hit = true;
    }
    fn strokeLine(ctx: *anyopaque, _: rs.ColorToken, _: f64, _: rs.Dash, lines: []const []const rs.TilePoint, _: ?f64) anyerror!void {
        const self = sp(ctx);
        if (self.nearLines(lines)) self.hit = true;
    }
    fn drawSymbol(ctx: *anyopaque, _: rs.SymbolName, at: rs.TilePoint, _: f64, _: f64, _: bool, _: rs.SymbolPlacement, _: ?f64) anyerror!void {
        const self = sp(ctx);
        if (self.nearPoint(at)) self.hit = true;
    }
    fn drawSounding(ctx: *anyopaque, _: f64, _: bool, _: bool, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.nearPoint(at)) self.hit = true;
    }
    fn drawText(ctx: *anyopaque, _: []const u8, _: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.nearPoint(at)) self.hit = true;
    }
};
