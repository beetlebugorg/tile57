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
pub const Point = struct { symbol: []const u8, rotation: f64, offset_x: f64, offset_y: f64, rot_north: bool = false };
pub const Text = struct { text: []const u8, color: []const u8, group: i64 = 0 };

pub const Portrayal = struct {
    fill_token: ?[]const u8 = null, // ColorFill (last wins)
    patterns: []const []const u8 = &.{}, // AreaFillReference
    lines: []const Line = &.{},
    points: []const Point = &.{},
    texts: []const Text = &.{},
    // S-52 DrawingPriority for the feature = the MAX priority over its draw
    // instructions (mirrors the Go s101build feature DisplayPriority). 0 when the
    // stream carries no DrawingPriority. Surfaced as the MVT `draw_prio` property
    // so the style can paint area fills in S-52 display order (DEPARE 3 < LNDARE 12).
    draw_prio: i64 = 0,
    // S-52 display-category rank (§10.3.4): 0=base, 1=standard, 2=other. The feature
    // takes the MOST-VISIBLE (lowest) band over its instructions' viewing groups;
    // standard (1) when none carries a category band. Surfaced as the MVT `cat`
    // property so the mariner's Base/Standard/Other selection filters client-side.
    cat: i64 = 1,
    // Date-dependent validity (S-52 §10.4.1.1), from the feature-level `Date:start,
    // end` instruction. S-100 truncated dates: a "--" prefix marks a recurring
    // month-day bound. Empty when the feature is undated. Surfaced as the MVT
    // date_start/date_end/date_recurring properties.
    date_start: []const u8 = "",
    date_end: []const u8 = "",
};

/// Display-category rank for a viewing group, from its leading digit (S-52 §10.3.4):
/// 1xxxx Base, 2xxxx Standard, 3xxxx/9xxxx Other. Anything else (text-group
/// selectors, <10000) carries no category band -> -1. Mirrors the Go
/// displayCategoryForViewingGroup (internal/engine/portrayal/s101build.go).
fn categoryRank(vg: i64) i64 {
    return switch (@divTrunc(vg, 10000)) {
        1 => 0, // Display Base
        2 => 1, // Display Standard
        3, 9 => 2, // Display Other (incl. 9xxxx quality/CATZOC overlays)
        else => -1, // no display-category band
    };
}

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
    var draw_prio: i64 = 0; // feature DrawingPriority = max seen in the stream
    var cat: i64 = -1; // most-visible display-category rank; -1 until a banded VG is seen
    var date_start: []const u8 = "";
    var date_end: []const u8 = "";
    // running state set by modifier instructions, applied at the next verb
    var cur_width: f64 = 1;
    var cur_color: []const u8 = "CHBLK";
    var cur_style: []const u8 = "_simple_";
    var cur_rot: f64 = 0;
    var cur_rot_north: bool = false; // Rotation CRS == GeographicCRS (rotates with true north)
    var cur_ox: f64 = 0;
    var cur_oy: f64 = 0;
    var cur_font: []const u8 = "CHBLK";
    var cur_tgrp: i64 = 0; // text group (S-52 §14.5) of the most recent ViewingGroup

    var it = std.mem.splitScalar(u8, stream, ';');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
        const key = item[0..colon];
        const val = item[colon + 1 ..];

        if (std.mem.eql(u8, key, "ColorFill")) {
            fill_token = val;
        } else if (std.mem.eql(u8, key, "AreaFillReference")) {
            // DIAMOND1 (SEABED01 shallow-water pattern) is owned by the client's
            // toggle-aware, live-safety-contour layer; baking it would double the
            // shading and ignore the toggle (mirrors Go s101build.go:371).
            if (!std.mem.eql(u8, val, "DIAMOND1")) try patterns.append(a, val);
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
            // S-101 form "Rotation:<CRS>,<angle>" (GeographicCRS=true-north, else
            // screen); a bare "Rotation:<angle>" with no CRS is screen-referenced.
            const crs = nthCsv(val, 0);
            const ang = nthCsv(val, 1);
            if (ang.len == 0) {
                cur_rot = toFloat(crs); // bare angle
                cur_rot_north = false;
            } else {
                cur_rot = toFloat(ang);
                cur_rot_north = std.mem.eql(u8, std.mem.trim(u8, crs, " "), "GeographicCRS");
            }
        } else if (std.mem.eql(u8, key, "LocalOffset")) {
            cur_ox = toFloat(nthCsv(val, 0));
            cur_oy = toFloat(nthCsv(val, 1));
        } else if (std.mem.eql(u8, key, "PointInstruction")) {
            try points.append(a, .{ .symbol = val, .rotation = cur_rot, .offset_x = cur_ox, .offset_y = cur_oy, .rot_north = cur_rot_north });
        } else if (std.mem.eql(u8, key, "FontColor")) {
            cur_font = val;
        } else if (std.mem.eql(u8, key, "TextInstruction")) {
            try texts.append(a, .{ .text = val, .color = cur_font, .group = cur_tgrp });
        } else if (std.mem.eql(u8, key, "DrawingPriority")) {
            // S-52 display priority. A feature draws across several viewing groups,
            // each with its own DrawingPriority; the feature's priority is the MAX
            // (matches Go s101build's `priority = max(c.Priority)`).
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, val, " "), 10) catch continue;
            if (v > draw_prio) draw_prio = v;
        } else if (std.mem.eql(u8, key, "ViewingGroup")) {
            // The feature's display category is the most-visible (lowest-rank) band
            // over its instructions. Text instructions carry ViewingGroup:<textGroup>,
            // <drawVG>; arg 0 there is the small text-group number, which categoryRank
            // maps to -1 (no band), so it correctly never lowers the category.
            const vg = std.fmt.parseInt(i64, std.mem.trim(u8, nthCsv(val, 0), " "), 10) catch continue;
            cur_tgrp = vg; // for a text instruction, arg 0 is its S-52 text group
            const rank = categoryRank(vg);
            if (rank >= 0 and (cat < 0 or rank < cat)) cat = rank;
        } else if (std.mem.eql(u8, key, "Date")) {
            // Feature-level validity period "start,end" (either bound may be empty).
            date_start = std.mem.trim(u8, nthCsv(val, 0), " ");
            date_end = std.mem.trim(u8, nthCsv(val, 1), " ");
        }
        // DisplayPlane / AlertReference / etc. are display metadata we don't map yet.
    }

    return .{
        .fill_token = fill_token,
        .patterns = patterns.items,
        .lines = lines.items,
        .points = points.items,
        .texts = texts.items,
        .draw_prio = draw_prio,
        .cat = if (cat < 0) 1 else cat, // no banded VG -> Standard
        .date_start = date_start,
        .date_end = date_end,
    };
}

test "parse the real DEPARE03 instruction stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The actual output from chartplotter-render --s101portray (DepthArea, 5-10 m).
    const stream =
        "ViewingGroup:13030;DrawingPriority:3;DisplayPlane:UnderRadar;" ++
        "AlertReference:SafetyContour;ColorFill:DEPMS;" ++
        "ViewingGroup:90000;DrawingPriority:9;DisplayPlane:UnderRadar;AreaFillReference:DIAMOND1";
    const p = try parse(a, stream);
    try std.testing.expectEqualStrings("DEPMS", p.fill_token.?);
    // DIAMOND1 is dropped (client-owned shallow-water pattern), so no patterns remain.
    try std.testing.expectEqual(@as(usize, 0), p.patterns.len);
    // draw_prio = max(3, 9) over the two viewing-group sections.
    try std.testing.expectEqual(@as(i64, 9), p.draw_prio);
    // Display category = most visible over {13030 -> Base, 90000 -> Other} = Base.
    try std.testing.expectEqual(@as(i64, 0), p.cat);
}

test "display category defaults to Standard when no banded viewing group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A text-only stream: ViewingGroup carries a text-group number (no category band).
    const p = try parse(a, "ViewingGroup:21,26070;DrawingPriority:24;FontColor:CHBLK;TextInstruction:Foo");
    try std.testing.expectEqual(@as(i64, 1), p.cat); // Standard
    try std.testing.expectEqual(@as(usize, 1), p.texts.len);
}

test "parse line + point + text instructions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = try parse(a, "ViewingGroup:32050;DrawingPriority:9;LineStyle:_simple_,,0.96,CHGRD;LineInstruction:_simple_");
    try std.testing.expectEqual(@as(usize, 1), line.lines.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.96), line.lines[0].width, 1e-9);
    try std.testing.expectEqualStrings("CHGRD", line.lines[0].color);
    try std.testing.expectEqual(@as(i64, 9), line.draw_prio);

    // No DrawingPriority in the stream -> default 0.
    const nopri = try parse(a, "FontColor:CHBLK;TextInstruction:foo");
    try std.testing.expectEqual(@as(i64, 0), nopri.draw_prio);

    const pt = try parse(a, "LocalOffset:1,-2;Rotation:45;PointInstruction:BCNCAR01");
    try std.testing.expectEqual(@as(usize, 1), pt.points.len);
    try std.testing.expectEqualStrings("BCNCAR01", pt.points[0].symbol);
    try std.testing.expectApproxEqAbs(@as(f64, 45), pt.points[0].rotation, 1e-9);
    try std.testing.expect(!pt.points[0].rot_north); // bare form is screen-referenced

    // CRS-qualified rotation (the production form): angle is arg 1, GeographicCRS=true-north.
    const rg = try parse(a, "Rotation:GeographicCRS,135;PointInstruction:LIGHTS11");
    try std.testing.expectApproxEqAbs(@as(f64, 135), rg.points[0].rotation, 1e-9);
    try std.testing.expect(rg.points[0].rot_north);
    const rp = try parse(a, "Rotation:PortrayalCRS,200;PointInstruction:LIGHTS11");
    try std.testing.expectApproxEqAbs(@as(f64, 200), rp.points[0].rotation, 1e-9);
    try std.testing.expect(!rp.points[0].rot_north);

    const tx = try parse(a, "FontColor:CHBLK;TextInstruction:Fl.R.4s");
    try std.testing.expectEqual(@as(usize, 1), tx.texts.len);
    try std.testing.expectEqualStrings("Fl.R.4s", tx.texts[0].text);
}
