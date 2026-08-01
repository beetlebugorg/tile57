//! QuerySurface: a Surface backend for cursor object-query (S-52 §10.8 pick).
//! Given a point in a tile's local coordinates, it replays that tile and records
//! which features the point falls in — an area you are inside, a line within a
//! small radius, or a symbol whose drawn mark covers the point. It reports each
//! hit feature's S-57 class + attribute JSON + source cell through a C callback.
//! The engine hands the class/s57_json/cell on the FeatureMeta contract, so no
//! S-57 decode is needed here.
const std = @import("std");
const rs = @import("surface.zig");
const resolve = @import("resolve.zig");
const sym = @import("symbols.zig");

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
    view_zoom: f64, // the view zoom, for the SCAMIN visibility cull
    cb: *const QueryCb,
    /// Catalogue symbol geometry, so a pick answers on the mark that is DRAWN.
    /// Null falls back to the anchor radius alone.
    store: ?sym.SymbolStore = null,
    /// Tile units per reference pixel: the tile extent over the 256-px native
    /// tile pitch (4096/256 = 16). A symbol's drawn size is fixed in reference
    /// px and the pick works in tile units, so the box test needs the ratio.
    /// The caller sets it from the extent it projected the query point into.
    units_per_px: f64 = 16.0,
    cur: rs.FeatureMeta = .{},
    hit: bool = false,
    visible: bool = false, // current feature passes SCAMIN at view_zoom

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
        .pick_area = pickArea,
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
        // Only report what the view actually shows: apply the same SCAMIN cull the
        // renderer does, so a zoomed-out click doesn't return finer-scale features.
        self.visible = resolve.scaminVisible(meta.scamin, self.view_zoom);
    }
    fn endFeature(ctx: *anyopaque) anyerror!void {
        const self = sp(ctx);
        if (!self.hit or !self.visible) return;
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
    /// A symbol is drawn AROUND its anchor, not on it: a buoy or a beacon puts
    /// nearly all of its mark above the charted position, and the mariner clicks
    /// the topmark that is visible. Test the drawn box.
    ///
    /// The transform is pixel.zig pushSymbol's: local = (c - pivot) * scale*100
    /// in reference px, then a rotation by rot_deg. Here it runs in tile units
    /// (units_per_px carries the conversion) and inverted, so the query point is
    /// compared in the symbol's own upright frame. The device scale is 1: the
    /// query API takes no Settings, so a mariner's physical-size multiplier is
    /// not visible here and the box only ever under-covers.
    ///
    /// False when the store is absent, the name is a catalogue gap, or the
    /// symbol has no geometry — the caller still has the anchor radius.
    fn inSymbolExtent(self: *QuerySurface, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64) bool {
        const store = self.store orelse return false;
        const s = store.get(name) orelse return false;
        const b = sym.bounds(s, scale * 100.0 * self.units_per_px) orelse return false;
        const dx = self.qx - @as(f64, @floatFromInt(at.x));
        const dy = self.qy - @as(f64, @floatFromInt(at.y));
        const rad = -rot_deg * std.math.pi / 180.0; // into the symbol's frame
        const c = @cos(rad);
        const s_r = @sin(rad);
        const lx = dx * c - dy * s_r;
        const ly = dx * s_r + dy * c;
        return lx >= b[0] and lx <= b[2] and ly >= b[1] and ly <= b[3];
    }

    fn fillArea(ctx: *anyopaque, _: rs.ColorToken, rings: []const []const rs.TilePoint, _: ?rs.DepthRange) anyerror!void {
        const self = sp(ctx);
        if (self.pointInRings(rings)) self.hit = true;
    }
    fn fillPattern(ctx: *anyopaque, _: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.pointInRings(rings)) self.hit = true;
    }
    /// An area the chart does not fill: a note area answers a pick anywhere
    /// inside it, not only under its INFORM01 marker.
    fn pickArea(ctx: *anyopaque, rings: []const []const rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.pointInRings(rings)) self.hit = true;
    }
    fn strokeLine(ctx: *anyopaque, _: rs.ColorToken, _: f64, _: rs.Dash, lines: []const []const rs.TilePoint, _: ?f64) anyerror!void {
        const self = sp(ctx);
        if (self.nearLines(lines)) self.hit = true;
    }
    /// The drawn box UNIONED with the anchor radius: the radius stays a floor,
    /// so a small symbol picks exactly as it did before and this test only adds
    /// hits. rot_north does not enter it, for the same reason it does not enter
    /// pushSymbol: the scene is north-up.
    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, _: bool, _: rs.SymbolPlacement, _: ?f64) anyerror!void {
        const self = sp(ctx);
        if (self.nearPoint(at) or self.inSymbolExtent(name, at, rot_deg, scale)) self.hit = true;
    }
    /// A sounding and a label keep the anchor test. A sounding's digits are laid
    /// out AROUND the anchor by their baked pivots and stay inside the radius,
    /// and reproducing either extent needs state the query path does not carry
    /// (an allocator and the mariner's depth unit for a sounding, the font face
    /// and shaping for a label).
    fn drawSounding(ctx: *anyopaque, _: f64, _: bool, _: bool, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.nearPoint(at)) self.hit = true;
    }
    fn drawText(ctx: *anyopaque, _: []const u8, _: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.nearPoint(at)) self.hit = true;
    }
};

test "a symbol answers a pick on the mark it draws, above the anchor" {
    const cv = @import("canvas.zig");
    const Seen = struct {
        var n: usize = 0;
        fn feature(_: ?*anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) void {
            n += 1;
        }
    };
    const cb = QueryCb{ .ctx = null, .feature = Seen.feature };

    // A beacon-shaped symbol: 2 mm wide, 20 mm tall, all of it ABOVE the pivot.
    const Fake = struct {
        mark: sym.Symbol,
        const vt = sym.SymbolStore.VTable{ .get = get, .getPattern = getPattern };
        fn getPattern(_: *anyopaque, _: []const u8, _: f32) ?*const cv.Pattern {
            return null;
        }
        fn get(ctx: *anyopaque, _: []const u8) ?*const sym.Symbol {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return &self.mark;
        }
    };
    const ring = [_]cv.Point{ .{ .x = -1, .y = -20 }, .{ .x = 1, .y = -20 }, .{ .x = 1, .y = 0 }, .{ .x = -1, .y = 0 } };
    const contours = [_][]const cv.Point{&ring};
    var fake = Fake{ .mark = .{
        .paths = &.{.{ .fill = .{ .r = 0, .g = 0, .b = 0 }, .contours = &contours }},
        .pivot = .{ .x = 0, .y = 0 },
    } };
    const store = sym.SymbolStore{ .ptr = &fake, .vtable = &Fake.vt };

    // scale 0.01 x 100 x 16 tile units per px = k 16, so the drawn box spans
    // x -16..16 and y -320..0 tile units about the anchor. Radius 96.
    const meta = rs.FeatureMeta{ .class = "BCNLAT" };
    const anchor = rs.TilePoint{ .x = 2048, .y = 2048 };
    const Case = struct { dx: f64, dy: f64, rot: f64, store: bool, want: usize };
    for ([_]Case{
        // The mariner clicks the topmark, 200 units above the anchor. Without a
        // store that is the old anchor-radius pick, and it misses.
        .{ .dx = 0, .dy = -200, .rot = 0, .store = false, .want = 0 },
        .{ .dx = 0, .dy = -200, .rot = 0, .store = true, .want = 1 },
        .{ .dx = 0, .dy = -400, .rot = 0, .store = true, .want = 0 }, // past the mark
        .{ .dx = 30, .dy = -200, .rot = 0, .store = true, .want = 0 }, // a box, not a fat radius
        .{ .dx = 0, .dy = 50, .rot = 0, .store = true, .want = 1 }, // the radius floor holds
        // Rotated a half turn, the mark hangs BELOW the anchor.
        .{ .dx = 0, .dy = -200, .rot = 180, .store = true, .want = 0 },
        .{ .dx = 0, .dy = 200, .rot = 180, .store = true, .want = 1 },
    }) |c| {
        Seen.n = 0;
        var qs = QuerySurface{
            .qx = @as(f64, @floatFromInt(anchor.x)) + c.dx,
            .qy = @as(f64, @floatFromInt(anchor.y)) + c.dy,
            .radius = 96,
            .view_zoom = 16,
            .cb = &cb,
            .store = if (c.store) store else null,
            .units_per_px = 16,
        };
        const surf = qs.asSurface();
        try surf.beginFeature(&meta);
        try surf.drawSymbol("BCNGEN03", anchor, c.rot, 0.01, false, .point, null);
        try surf.endFeature();
        try std.testing.expectEqual(c.want, Seen.n);
    }
}

test "a note area answers a pick inside it, and only inside it" {
    const Seen = struct {
        var n: usize = 0;
        fn feature(_: ?*anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) void {
            n += 1;
        }
    };
    const cb = QueryCb{ .ctx = null, .feature = Seen.feature };
    // A square from (100,100) to (900,900) — the note area, which draws no fill.
    const ring = [_]rs.TilePoint{
        .{ .x = 100, .y = 100 }, .{ .x = 900, .y = 100 },
        .{ .x = 900, .y = 900 }, .{ .x = 100, .y = 900 },
    };
    const rings = [_][]const rs.TilePoint{&ring};
    const meta = rs.FeatureMeta{ .class = "M_NPUB" };

    for ([_][2]f64{ .{ 500, 500 }, .{ 2000, 500 } }, [_]usize{ 1, 0 }) |at, want| {
        Seen.n = 0;
        var qs = QuerySurface{ .qx = at[0], .qy = at[1], .radius = 96, .view_zoom = 12, .cb = &cb };
        const surf = qs.asSurface();
        try surf.beginFeature(&meta);
        try surf.pickArea(&rings);
        try surf.endFeature();
        try std.testing.expectEqual(want, Seen.n);
    }
}
