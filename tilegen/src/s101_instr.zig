//! S-101 drawing-instruction stream -> structured portrayal, for translation to
//! MVT. The S-101 rules emit a ';'-separated stream of `Key:Value` instructions
//! (e.g. `ColorFill:DEPMS;AreaFillReference:DIAMOND1;LineStyle:_simple_,,0.96,
//! CHGRD;LineInstruction:_simple_;PointInstruction:BCNCAR01`). This parses one
//! feature's stream into fills / patterns / lines / points / texts that
//! s57_mvt maps onto the chart's MVT layers (color_token, etc.).
//!
//! Mirrors internal/engine/portrayal/s101emit.go (the instruction interpreter).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Line = struct { style: []const u8, width: f64, color: []const u8 };
pub const Point = struct { symbol: []const u8, rotation: f64, offset_x: f64, offset_y: f64 };
pub const Text = struct { text: []const u8, color: []const u8 };

pub const Portrayal = struct {
    fill_token: ?[]const u8 = null, // ColorFill (last wins)
    patterns: []const []const u8 = &.{}, // AreaFillReference
    lines: []const Line = &.{},
    points: []const Point = &.{},
    texts: []const Text = &.{},
};

fn nthCsv(s: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) if (i == n) return part;
    return "";
}

fn toFloat(s: []const u8) f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch 0;
}

/// Parse one feature's instruction stream. Allocates into `a` (use an arena).
pub fn parse(a: Allocator, stream: []const u8) !Portrayal {
    var patterns = std.ArrayList([]const u8).empty;
    var lines = std.ArrayList(Line).empty;
    var points = std.ArrayList(Point).empty;
    var texts = std.ArrayList(Text).empty;

    var fill_token: ?[]const u8 = null;
    // running state set by modifier instructions, applied at the next verb
    var cur_width: f64 = 1;
    var cur_color: []const u8 = "CHBLK";
    var cur_style: []const u8 = "_simple_";
    var cur_rot: f64 = 0;
    var cur_ox: f64 = 0;
    var cur_oy: f64 = 0;
    var cur_font: []const u8 = "CHBLK";

    var it = std.mem.splitScalar(u8, stream, ';');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
        const key = item[0..colon];
        const val = item[colon + 1 ..];

        if (std.mem.eql(u8, key, "ColorFill")) {
            fill_token = val;
        } else if (std.mem.eql(u8, key, "AreaFillReference")) {
            try patterns.append(a, val);
        } else if (std.mem.eql(u8, key, "LineStyle")) {
            // _simple_,,<width>,<color>
            cur_style = nthCsv(val, 0);
            cur_width = toFloat(nthCsv(val, 2));
            cur_color = nthCsv(val, 3);
        } else if (std.mem.eql(u8, key, "LineInstruction")) {
            if (std.mem.eql(u8, val, "_simple_")) {
                try lines.append(a, .{ .style = "solid", .width = cur_width, .color = cur_color });
            } else {
                // named complex line pattern
                try lines.append(a, .{ .style = val, .width = cur_width, .color = cur_color });
            }
        } else if (std.mem.eql(u8, key, "Rotation")) {
            cur_rot = toFloat(val);
        } else if (std.mem.eql(u8, key, "LocalOffset")) {
            cur_ox = toFloat(nthCsv(val, 0));
            cur_oy = toFloat(nthCsv(val, 1));
        } else if (std.mem.eql(u8, key, "PointInstruction")) {
            try points.append(a, .{ .symbol = val, .rotation = cur_rot, .offset_x = cur_ox, .offset_y = cur_oy });
        } else if (std.mem.eql(u8, key, "FontColor")) {
            cur_font = val;
        } else if (std.mem.eql(u8, key, "TextInstruction")) {
            try texts.append(a, .{ .text = val, .color = cur_font });
        }
        // ViewingGroup / DrawingPriority / DisplayPlane / AlertReference / etc.
        // are display metadata we don't need for the MVT mapping yet.
    }

    return .{
        .fill_token = fill_token,
        .patterns = patterns.items,
        .lines = lines.items,
        .points = points.items,
        .texts = texts.items,
    };
}

test "parse the real DEPARE03 instruction stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The actual output from chartshot-zig --s101portray (DepthArea, 5-10 m).
    const stream =
        "ViewingGroup:13030;DrawingPriority:3;DisplayPlane:UnderRadar;" ++
        "AlertReference:SafetyContour;ColorFill:DEPMS;" ++
        "ViewingGroup:90000;DrawingPriority:9;DisplayPlane:UnderRadar;AreaFillReference:DIAMOND1";
    const p = try parse(a, stream);
    try std.testing.expectEqualStrings("DEPMS", p.fill_token.?);
    try std.testing.expectEqual(@as(usize, 1), p.patterns.len);
    try std.testing.expectEqualStrings("DIAMOND1", p.patterns[0]);
}

test "parse line + point + text instructions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = try parse(a, "ViewingGroup:32050;LineStyle:_simple_,,0.96,CHGRD;LineInstruction:_simple_");
    try std.testing.expectEqual(@as(usize, 1), line.lines.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.96), line.lines[0].width, 1e-9);
    try std.testing.expectEqualStrings("CHGRD", line.lines[0].color);

    const pt = try parse(a, "LocalOffset:1,-2;Rotation:45;PointInstruction:BCNCAR01");
    try std.testing.expectEqual(@as(usize, 1), pt.points.len);
    try std.testing.expectEqualStrings("BCNCAR01", pt.points[0].symbol);
    try std.testing.expectApproxEqAbs(@as(f64, 45), pt.points[0].rotation, 1e-9);

    const tx = try parse(a, "FontColor:CHBLK;TextInstruction:Fl.R.4s");
    try std.testing.expectEqual(@as(usize, 1), tx.texts.len);
    try std.testing.expectEqualStrings("Fl.R.4s", tx.texts[0].text);
}
