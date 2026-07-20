//! Label-tier resolver — maps a geographic-name feature (its S-57 object class,
//! SCAMIN, and category attribute) to a text size / weight / slant so a major
//! city reads bolder and larger than a creek. This is a deliberate extension
//! beyond S-52, which portrays every label medium / pica-10 / black; the
//! extension only scales important names UP and never below the pica-10 floor
//! (§3.1.5 "text size should never be decreased when zooming out").
//!
//! Pure over primitives + the font weight/slant twins: `scene` reads the S-57
//! values (class, SCAMIN, the category attribute from `categoryCode`) and calls
//! `resolve`. Only geographic-name classes are tiered — everything else returns
//! null and keeps the portrayal rule's own text style.

const std = @import("std");
const font = @import("font.zig");

pub const Tier = struct {
    size_px: f64,
    weight: font.Weight,
    slant: font.Slant,
};

/// S-52 readable-from-1m floor: pica-10 (≈3.51 mm). No tier goes below this.
const floor_px: f64 = 10;
/// A feature the cartographer keeps at a broad display scale (small SCAMIN
/// denominator) is one they judged important; at or below this it earns the
/// larger size. A null SCAMIN (shown at every scale) counts as broad-scale.
const major_scamin: i64 = 20000;

/// The S-57 attribute code whose value ranks names within `class`, or null for a
/// name class with no category axis (the caller then passes `category = null`).
pub fn categoryCode(class: []const u8) ?u16 {
    if (std.mem.eql(u8, class, "BUAARE")) return 10; // CATBUA
    if (std.mem.eql(u8, class, "SEAARE")) return 59; // CATSEA
    return null;
}

/// The tier for a geographic-name label, or null when `class` is not a
/// name-bearing class (the caller keeps the rule's own text style). `scamin` is
/// the feature's SCAMIN denominator (null = shown at every scale); `category` is
/// the value of `categoryCode(class)` on the feature (null = absent).
pub fn resolve(class: []const u8, scamin: ?i64, category: ?i64) ?Tier {
    const broad_scale = if (scamin) |s| s <= major_scamin else true;

    // Populated places — the boldest names on the chart, upright. City / Town
    // (CATBUA 5 / 4) or a broad-scale place gets the large size.
    if (std.mem.eql(u8, class, "BUAARE")) {
        const big = broad_scale or (category != null and (category.? == 5 or category.? == 4));
        return .{ .size_px = if (big) 14 else 12, .weight = .bold, .slant = .upright };
    }

    // Water bodies and watercourses — italic, the universal hydrographic
    // convention. Area waters (Bay / Basin / Lake / Reach) or broad-scale ones
    // read one step larger than creeks, rivers and canals.
    if (isWater(class)) {
        const big = broad_scale or isAreaWater(category);
        return .{ .size_px = if (big) 12 else floor_px, .weight = .regular, .slant = .italic };
    }

    // Other land names — points, capes, marshes, landmarks: regular upright at
    // the floor. (NOAA hangs "X Point" names on LNDRGN regardless of CATLND, so
    // the class, not the category, is the signal here.)
    if (isLandName(class)) {
        return .{ .size_px = floor_px, .weight = .regular, .slant = .upright };
    }

    return null;
}

fn isWater(class: []const u8) bool {
    return eqAny(class, &.{ "SEAARE", "RIVERS", "CANALS", "LAKARE", "TIDEWY" });
}

/// CATSEA values that name a sizeable water body rather than a narrow watercourse:
/// Bay(5), Basin(7), Lake(52), Reach(54). River(53) / Canal(51) / Narrows(12) /
/// Shoal(13) stay at the floor.
fn isAreaWater(category: ?i64) bool {
    const c = category orelse return false;
    return c == 5 or c == 7 or c == 52 or c == 54;
}

fn isLandName(class: []const u8) bool {
    return eqAny(class, &.{ "LNDRGN", "LNDMRK" });
}

fn eqAny(s: []const u8, set: []const []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

// ---- tests -------------------------------------------------------------------

test "labeltier: major city is big + bold, minor place small + bold" {
    const city = resolve("BUAARE", 17999, 5).?; // City, broad scale
    try std.testing.expectEqual(@as(f64, 14), city.size_px);
    try std.testing.expectEqual(font.Weight.bold, city.weight);
    try std.testing.expectEqual(font.Slant.upright, city.slant);

    const hood = resolve("BUAARE", 89999, 1).?; // Urban area, fine scale
    try std.testing.expectEqual(@as(f64, 12), hood.size_px);
    try std.testing.expectEqual(font.Weight.bold, hood.weight);
}

test "labeltier: water is italic, bays larger than creeks" {
    const bay = resolve("SEAARE", 89999, 5).?; // Bay by category despite fine scale
    try std.testing.expectEqual(@as(f64, 12), bay.size_px);
    try std.testing.expectEqual(font.Slant.italic, bay.slant);
    try std.testing.expectEqual(font.Weight.regular, bay.weight);

    const creek = resolve("SEAARE", 89999, 53).?; // River/creek, fine scale
    try std.testing.expectEqual(@as(f64, 10), creek.size_px);
    try std.testing.expectEqual(font.Slant.italic, creek.slant);

    const river = resolve("RIVERS", 89999, null).?;
    try std.testing.expectEqual(font.Slant.italic, river.slant);
    try std.testing.expectEqual(@as(f64, 10), river.size_px);
}

test "labeltier: land names upright at the floor; non-name classes untouched" {
    const point = resolve("LNDRGN", 89999, 2).?;
    try std.testing.expectEqual(@as(f64, 10), point.size_px);
    try std.testing.expectEqual(font.Slant.upright, point.slant);
    try std.testing.expectEqual(font.Weight.regular, point.weight);

    try std.testing.expectEqual(@as(?Tier, null), resolve("BRIDGE", 259999, null));
    try std.testing.expectEqual(@as(?Tier, null), resolve("LIGHTS", null, null));
}

test "labeltier: null SCAMIN counts as broad scale" {
    const place = resolve("BUAARE", null, 1).?; // no display limit => major
    try std.testing.expectEqual(@as(f64, 14), place.size_px);
    try std.testing.expectEqual(@as(?u16, 10), categoryCode("BUAARE"));
    try std.testing.expectEqual(@as(?u16, 59), categoryCode("SEAARE"));
    try std.testing.expectEqual(@as(?u16, null), categoryCode("LNDRGN"));
}
