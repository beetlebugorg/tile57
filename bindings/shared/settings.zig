//! settings — parse a mariner-settings JSON blob into `chartstyle.MarinerSettings`.
//!
//! Shared by the wasm entry point (bindings/wasm/style_wasm.zig) and the native
//! parity harness (bindings/parity/parity.zig) so the two CANNOT drift: a parity
//! diff then exercises the identical settings->buildStyle path on both targets.
//!
//! Schema: a JSON object whose keys mirror the MarinerSettings field names. Enums
//! are their string forms ("day"/"dusk"/"night", "meters"/"feet",
//! "symbolized"/"plain"). Any absent or malformed field keeps its canonical
//! default, so a partial (or empty, or invalid) blob still yields a usable style.

const std = @import("std");
const chartstyle = @import("assets").chartstyle;

pub const MarinerSettings = chartstyle.MarinerSettings;

fn asF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn getBool(o: *const std.json.ObjectMap, key: []const u8, dflt: bool) bool {
    if (o.get(key)) |v| if (v == .bool) return v.bool;
    return dflt;
}

fn getF64(o: *const std.json.ObjectMap, key: []const u8, dflt: f64) f64 {
    if (o.get(key)) |v| if (asF64(v)) |n| return n;
    return dflt;
}

fn getStr(o: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (o.get(key)) |v| if (v == .string) return v.string;
    return null;
}

/// Parse `json` into MarinerSettings. `a` must outlive the returned settings AND
/// the subsequent buildStyle call (a pinned `date_view` string is duped into it).
pub fn parse(a: std.mem.Allocator, json: []const u8) MarinerSettings {
    var m = MarinerSettings{};
    if (json.len == 0) return m;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return m;
    if (parsed != .object) return m;
    const o = &parsed.object;

    if (getStr(o, "scheme")) |s| {
        if (std.mem.eql(u8, s, "night")) {
            m.scheme = .night;
        } else if (std.mem.eql(u8, s, "dusk")) {
            m.scheme = .dusk;
        } else {
            m.scheme = .day;
        }
    }
    if (getStr(o, "depth_unit")) |s|
        m.depth_unit = if (std.mem.eql(u8, s, "feet")) .feet else .meters;
    if (getStr(o, "boundary_style")) |s|
        m.boundary_style = if (std.mem.eql(u8, s, "plain")) .plain else .symbolized;

    m.shallow_contour = getF64(o, "shallow_contour", m.shallow_contour);
    m.safety_contour = getF64(o, "safety_contour", m.safety_contour);
    m.deep_contour = getF64(o, "deep_contour", m.deep_contour);
    m.safety_depth = getF64(o, "safety_depth", m.safety_depth);
    m.four_shade_water = getBool(o, "four_shade_water", m.four_shade_water);

    m.display_base = getBool(o, "display_base", m.display_base);
    m.display_standard = getBool(o, "display_standard", m.display_standard);
    m.display_other = getBool(o, "display_other", m.display_other);

    m.data_quality = getBool(o, "data_quality", m.data_quality);
    m.show_inform_callouts = getBool(o, "show_inform_callouts", m.show_inform_callouts);
    m.show_meta_bounds = getBool(o, "show_meta_bounds", m.show_meta_bounds);
    m.show_isolated_dangers_shallow = getBool(o, "show_isolated_dangers_shallow", m.show_isolated_dangers_shallow);

    m.simplified_points = getBool(o, "simplified_points", m.simplified_points);
    m.show_full_sector_lines = getBool(o, "show_full_sector_lines", m.show_full_sector_lines);

    m.text_names = getBool(o, "text_names", m.text_names);
    m.show_light_descriptions = getBool(o, "show_light_descriptions", m.show_light_descriptions);
    m.text_other = getBool(o, "text_other", m.text_other);

    m.date_dependent = getBool(o, "date_dependent", m.date_dependent);
    m.highlight_date_dependent = getBool(o, "highlight_date_dependent", m.highlight_date_dependent);
    if (getStr(o, "date_view")) |s| m.date_view = a.dupe(u8, s) catch "";

    return m;
}

test "parse: empty / invalid -> all defaults" {
    const a = std.testing.allocator;
    const d = MarinerSettings{};
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const m = parse(arena.allocator(), "");
        try std.testing.expectEqual(d.scheme, m.scheme);
        try std.testing.expectEqual(d.safety_contour, m.safety_contour);
    }
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const m = parse(arena.allocator(), "{not json");
        try std.testing.expectEqual(d.depth_unit, m.depth_unit);
    }
}

test "parse: fields + enums + partial override" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const m = parse(arena.allocator(),
        \\{"scheme":"night","depth_unit":"feet","boundary_style":"plain",
        \\ "safety_contour":12.5,"deep_contour":40,"four_shade_water":false,
        \\ "display_other":true,"date_view":"20240115"}
    );
    try std.testing.expectEqual(chartstyle.Scheme.night, m.scheme);
    try std.testing.expectEqual(chartstyle.DepthUnit.feet, m.depth_unit);
    try std.testing.expectEqual(chartstyle.BoundaryStyle.plain, m.boundary_style);
    try std.testing.expectEqual(@as(f64, 12.5), m.safety_contour);
    try std.testing.expectEqual(@as(f64, 40), m.deep_contour);
    try std.testing.expectEqual(false, m.four_shade_water);
    try std.testing.expectEqual(true, m.display_other);
    try std.testing.expectEqualStrings("20240115", m.date_view);
    // untouched field keeps its default
    try std.testing.expectEqual(@as(f64, 2.0), m.shallow_contour);
}
