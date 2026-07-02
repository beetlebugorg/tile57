//! InspectSurface: a RECORDING Surface backend for the `tile57 explore` debug /
//! learning tool. Unlike every other backend it DRAWS NOTHING — it captures each
//! Surface call, grouped per feature (beginFeature … endFeature), as structured
//! data an inspector can print back:
//!
//!   feature X produced: fillArea(DEPVS), drawSymbol(BOYLAT23 @…), drawText(…)
//!
//! It is the mirror image of noop.zig (which discards every call) and ascii.zig
//! (which lowers each call to a character): here the recording IS the output.
//!
//! Same rule as every surface (surface.zig): no s57 / s100 / portray imports.
//! The FeatureMeta the engine hands beginFeature already carries the S-57 class
//! acronym + the acronym→value pick blob, and the draw calls carry color tokens /
//! symbol names verbatim — everything the record needs is on the contract.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("surface.zig");

/// One recorded Surface draw call. The engine's projected geometry is tile-space
/// and not very illuminating for an S-57/S-101 learning tool, so ring/line
/// geometry is SUMMARISED (ring/line count + total vertex count) while point
/// anchors (symbols, soundings, text) are kept verbatim — those are where a
/// mariner actually looks ("what symbol landed here, at what rotation").
pub const Call = union(enum) {
    fill_area: struct { token: []const u8, rings: usize, verts: usize, depth: ?rs.DepthRange },
    fill_pattern: struct { name: []const u8, rings: usize, verts: usize },
    stroke_line: struct { token: []const u8, width_px: f64, dash: rs.Dash, lines: usize, verts: usize, valdco: ?f64 },
    draw_symbol: struct {
        name: []const u8,
        at: rs.TilePoint,
        rot_deg: f64,
        scale: f64,
        rot_north: bool,
        placement: rs.SymbolPlacement,
        danger_depth: ?f64,
    },
    draw_sounding: struct { depth_m: f64, swept: bool, low_acc: bool, at: rs.TilePoint },
    draw_text: struct {
        text: []const u8,
        color: []const u8,
        font_size: f64,
        halign: []const u8,
        valign: []const u8,
        at: rs.TilePoint,
    },
};

/// A snapshot of the per-feature FeatureMeta (surface.zig), taken at beginFeature.
/// Strings are duped into the surface's allocator because meta is valid only for
/// the duration of the call.
pub const Meta = struct {
    draw_prio: i64 = 0,
    cat: i64 = 1,
    vg: i64 = 0,
    scamin: ?i64 = null,
    overscale: bool = false,
    class: []const u8 = "",
    s57_json: []const u8 = "",
    cell_name: []const u8 = "",
    band: u8 = 0,
    bnd: i64 = 2,
    pts: i64 = 2,
    date_start: []const u8 = "",
    date_end: []const u8 = "",
};

/// One feature's recorded draw calls, bracketed by beginFeature / endFeature.
/// A single S-57 feature can produce SEVERAL of these — the boundary/point-style
/// variant passes (bnd/pts) and constructed sector figures each re-open a bracket
/// — so consumers key on `meta.s57_json` (+ class) to fold them back together.
pub const RecordedFeature = struct {
    meta: Meta,
    calls: std.ArrayList(Call) = .empty,
};

pub const InspectSurface = struct {
    a: Allocator,
    scene_z: u8 = 0,
    features: std.ArrayList(RecordedFeature) = .empty,

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

    /// `a` should outlive whatever reads `features` — an arena is ideal (the
    /// duped meta strings + call fields live in it). The surface never frees.
    pub fn init(a: Allocator) InspectSurface {
        return .{ .a = a };
    }

    pub fn asSurface(self: *InspectSurface) rs.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn sp(ctx: *anyopaque) *InspectSurface {
        return @ptrCast(@alignCast(ctx));
    }

    fn dup(self: *InspectSurface, s: []const u8) []const u8 {
        return self.a.dupe(u8, s) catch "";
    }

    /// The feature currently being recorded (the last opened bracket), or null
    /// if a draw call arrives outside any feature (shouldn't happen, but the
    /// recorder never crashes on a malformed lifecycle).
    fn cur(self: *InspectSurface) ?*RecordedFeature {
        if (self.features.items.len == 0) return null;
        return &self.features.items[self.features.items.len - 1];
    }

    fn push(self: *InspectSurface, call: Call) void {
        if (self.cur()) |f| f.calls.append(self.a, call) catch {};
    }

    fn vertsOf(parts: []const []const rs.TilePoint) usize {
        var n: usize = 0;
        for (parts) |p| n += p.len;
        return n;
    }

    // ---- Surface impl ---------------------------------------------------------

    fn beginScene(ctx: *anyopaque, z: u8) anyerror!void {
        sp(ctx).scene_z = z;
    }

    fn beginFeature(ctx: *anyopaque, meta: *const rs.FeatureMeta) anyerror!void {
        const self = sp(ctx);
        try self.features.append(self.a, .{ .meta = .{
            .draw_prio = meta.draw_prio,
            .cat = meta.cat,
            .vg = meta.vg,
            .scamin = meta.scamin,
            .overscale = meta.overscale,
            .class = self.dup(meta.class),
            .s57_json = self.dup(meta.s57_json),
            .cell_name = self.dup(meta.cell_name),
            .band = meta.band,
            .bnd = meta.bnd,
            .pts = meta.pts,
            .date_start = self.dup(meta.date_start),
            .date_end = self.dup(meta.date_end),
        } });
    }

    fn fillArea(ctx: *anyopaque, token: rs.ColorToken, rings: []const []const rs.TilePoint, depth: ?rs.DepthRange) anyerror!void {
        const self = sp(ctx);
        self.push(.{ .fill_area = .{ .token = self.dup(token), .rings = rings.len, .verts = vertsOf(rings), .depth = depth } });
    }

    fn fillPattern(ctx: *anyopaque, name: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        self.push(.{ .fill_pattern = .{ .name = self.dup(name), .rings = rings.len, .verts = vertsOf(rings) } });
    }

    fn strokeLine(ctx: *anyopaque, token: rs.ColorToken, width_px: f64, dash: rs.Dash, lines: []const []const rs.TilePoint, valdco: ?f64) anyerror!void {
        const self = sp(ctx);
        self.push(.{ .stroke_line = .{ .token = self.dup(token), .width_px = width_px, .dash = dash, .lines = lines.len, .verts = vertsOf(lines), .valdco = valdco } });
    }

    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: rs.SymbolPlacement, danger_depth: ?f64) anyerror!void {
        const self = sp(ctx);
        self.push(.{ .draw_symbol = .{
            .name = self.dup(name),
            .at = at,
            .rot_deg = rot_deg,
            .scale = scale,
            .rot_north = rot_north,
            .placement = placement,
            .danger_depth = danger_depth,
        } });
    }

    fn drawSounding(ctx: *anyopaque, depth_m: f64, swept: bool, low_acc: bool, at: rs.TilePoint) anyerror!void {
        sp(ctx).push(.{ .draw_sounding = .{ .depth_m = depth_m, .swept = swept, .low_acc = low_acc, .at = at } });
    }

    fn drawText(ctx: *anyopaque, text: []const u8, style: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        self.push(.{ .draw_text = .{
            .text = self.dup(text),
            .color = self.dup(style.color),
            .font_size = style.font_size,
            .halign = self.dup(style.halign),
            .valign = self.dup(style.valign),
            .at = at,
        } });
    }

    fn endFeature(_: *anyopaque) anyerror!void {}

    /// The record lives in `self.features`; the encoded byte stream is empty
    /// (there is nothing to serialize — an inspector reads the struct directly).
    fn endScene(_: *anyopaque, out: Allocator) anyerror![]u8 {
        return out.alloc(u8, 0);
    }
};

// ---- tests -------------------------------------------------------------------

test "InspectSurface records each call, grouped per feature, with meta" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var is = InspectSurface.init(a);
    const surf = is.asSurface();

    try surf.beginScene(13);

    // Feature 1: a depth area — one fill.
    const water_meta = rs.FeatureMeta{ .draw_prio = 3, .cat = 0, .vg = 13030, .class = "DEPARE", .s57_json = "{\"DRVAL1\":\"2\",\"DRVAL2\":\"5\"}" };
    try surf.beginFeature(&water_meta);
    const ring = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const rings = [_][]const rs.TilePoint{&ring};
    try surf.fillArea("DEPVS", &rings, .{ .d1 = 2, .d2 = 5 });
    try surf.endFeature();

    // Feature 2: a lateral buoy — a symbol, a stroke and a label.
    const buoy_meta = rs.FeatureMeta{ .draw_prio = 24, .cat = 1, .vg = 26050, .scamin = 30000, .class = "BOYLAT", .s57_json = "{\"OBJNAM\":\"CR\"}" };
    try surf.beginFeature(&buoy_meta);
    const line = [_]rs.TilePoint{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } };
    const lines = [_][]const rs.TilePoint{&line};
    try surf.strokeLine("CHBLK", 2.0, .dashed, &lines, 12.0);
    try surf.drawSymbol("BOYLAT23", .{ .x = 5, .y = 6 }, 45, 1, true, .point, null);
    const style = rs.TextStyle{ .color = "CHBLK", .font_size = 10, .halign = "right", .valign = "bottom" };
    try surf.drawText("CR", &style, .{ .x = 7, .y = 6 });
    try surf.endFeature();

    const out = try surf.endScene(a);
    try std.testing.expectEqual(@as(usize, 0), out.len); // nothing serialized
    try std.testing.expectEqual(@as(u8, 13), is.scene_z);

    // Two features recorded, in emission order.
    try std.testing.expectEqual(@as(usize, 2), is.features.items.len);

    const f0 = is.features.items[0];
    try std.testing.expectEqualStrings("DEPARE", f0.meta.class);
    try std.testing.expectEqual(@as(i64, 3), f0.meta.draw_prio);
    try std.testing.expectEqual(@as(i64, 0), f0.meta.cat);
    try std.testing.expectEqual(@as(usize, 1), f0.calls.items.len);
    switch (f0.calls.items[0]) {
        .fill_area => |fa| {
            try std.testing.expectEqualStrings("DEPVS", fa.token);
            try std.testing.expectEqual(@as(usize, 1), fa.rings);
            try std.testing.expectEqual(@as(usize, 4), fa.verts);
            try std.testing.expectEqual(@as(f32, 2), fa.depth.?.d1);
        },
        else => return error.WrongCall,
    }

    const f1 = is.features.items[1];
    try std.testing.expectEqualStrings("BOYLAT", f1.meta.class);
    try std.testing.expectEqual(@as(?i64, 30000), f1.meta.scamin);
    try std.testing.expectEqual(@as(usize, 3), f1.calls.items.len);
    // Recorded in call order: stroke, symbol, text.
    switch (f1.calls.items[0]) {
        .stroke_line => |s| {
            try std.testing.expectEqualStrings("CHBLK", s.token);
            try std.testing.expectEqual(rs.Dash.dashed, s.dash);
            try std.testing.expectEqual(@as(f64, 12.0), s.valdco.?);
        },
        else => return error.WrongCall,
    }
    switch (f1.calls.items[1]) {
        .draw_symbol => |ds| {
            try std.testing.expectEqualStrings("BOYLAT23", ds.name);
            try std.testing.expectEqual(@as(i32, 5), ds.at.x);
            try std.testing.expectEqual(@as(f64, 45), ds.rot_deg);
            try std.testing.expect(ds.rot_north);
            try std.testing.expectEqual(rs.SymbolPlacement.point, ds.placement);
        },
        else => return error.WrongCall,
    }
    switch (f1.calls.items[2]) {
        .draw_text => |dt| {
            try std.testing.expectEqualStrings("CR", dt.text);
            try std.testing.expectEqualStrings("right", dt.halign);
        },
        else => return error.WrongCall,
    }
}

test "InspectSurface: a draw call outside any feature is dropped, not a crash" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var is = InspectSurface.init(a);
    const surf = is.asSurface();
    try surf.beginScene(0);
    // No beginFeature — the recorder simply has nowhere to attach it.
    try surf.drawSounding(4.2, false, false, .{ .x = 1, .y = 1 });
    try std.testing.expectEqual(@as(usize, 0), is.features.items.len);
}
