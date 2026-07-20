//! Paint order — the one definition of it.
//!
//! Every surface has to answer "what covers what", and each one used to answer
//! it separately: pixel, ascii and vector each declared their own OpLayer and
//! their own comparator, byte-identical and free to drift. They did drift, and
//! a host that rebuilt the rule for itself drifted further — the same spec bug
//! (applying OVERRADAR precedence with no radar overlay) had to be fixed in
//! three places.
//!
//! So the rule lives here, once, and everything else compares integers.

const std = @import("std");

/// Geometry class. NOT the primary ordering axis — S-52 PresLib §10.3.4.1 makes
/// it the TIEBREAK, used only when display priority is equal:
///
///   "The display priority applies irrespective of whether an object is a point,
///    line or area. If the display priority is equal among objects, line objects
///    have to be drawn on top of area objects whereas point objects have to be
///    drawn on top of both."
///
/// The values ARE that tiebreak order, which is why `pattern` sits between area
/// and line: an area-fill pattern paints over its fill and under its boundary.
pub const Layer = enum(u8) {
    area = 0,
    pattern = 1,
    line = 2,
    symbol = 3,
    sounding = 4,
    text = 5,
};

/// S-101 DrawingPriority range (the catalogue's values are 0..30).
pub const PRIO_MAX: u32 = 30;

/// One past the largest `key`. A host sizes a bucket array with it.
pub const KEY_MAX: u32 = 4 * (PRIO_MAX + 1) * @typeInfo(Layer).@"enum".fields.len;

/// Fold one draw call's ordering into a single comparable integer.
///
/// The levels, in order:
///   1. text last          — §10.3.4.1 ("Text must be drawn last ... in priority
///                           8") and §16 rule 3. AddTextInstruction inherits its
///                           feature's priority (LandArea passes 3), so ordering
///                           labels by priority alone would sink them under the
///                           fills they annotate.
///   2. DisplayPlane       — §10.3.4.2, and ONLY with a radar overlay: "When the
///                           RADAR overlay is present ... the OVERRADAR flag
///                           takes precedence over the objects display priority."
///                           Ungated it lifts OverRadar features above every
///                           higher-priority one.
///   3. display priority   — the dominant axis, class-independent.
///   4. geometry class     — the tiebreak above.
///
/// Emission order breaks what remains and is preserved by keeping the calls in
/// sequence, so it needs no bits here. The catalogue leans on that: an area
/// emits its fill then its boundary at ONE priority (Gate.lua:127-129), and a
/// light arc emits casing then core (LightSectored.lua:141-143).
pub fn key(layer: Layer, display_priority: i64, display_plane: i64, radar: bool) u32 {
    const is_text: u32 = if (layer == .text) 1 else 0;
    const plane: u32 = if (radar and display_plane != 0) 1 else 0;
    const prio: u32 = @intCast(std.math.clamp(display_priority, 0, @as(i64, PRIO_MAX)));
    const classes: u32 = @typeInfo(Layer).@"enum".fields.len;
    return ((is_text * 2 + plane) * (PRIO_MAX + 1) + prio) * classes + @intFromEnum(layer);
}

const testing = std.testing;

test "paint: priority outranks class" {
    // The bug this encodes against: a light sector arc is a LINE at priority 24,
    // a wreck is a SYMBOL at 12. Class-major ordering buried the arc.
    const arc = key(.line, 24, 0, false);
    const wreck = key(.symbol, 12, 0, false);
    try testing.expect(wreck < arc);
}

test "paint: class breaks ties only at equal priority" {
    const p = 12;
    try testing.expect(key(.area, p, 0, false) < key(.pattern, p, 0, false));
    try testing.expect(key(.pattern, p, 0, false) < key(.line, p, 0, false));
    try testing.expect(key(.line, p, 0, false) < key(.symbol, p, 0, false));
}

test "paint: DisplayPlane orders only under a radar overlay" {
    const over = key(.area, 12, 1, false);
    const under = key(.line, 24, 0, false);
    try testing.expect(under > over); // no radar: priority leads

    const over_r = key(.area, 12, 1, true);
    const under_r = key(.line, 24, 0, true);
    try testing.expect(over_r > under_r); // radar: the OverRadar area wins
}

test "paint: text is last whatever its priority" {
    try testing.expect(key(.text, 3, 0, false) > key(.symbol, 30, 0, false));
}

test "paint: every key fits the advertised bound" {
    for ([_]Layer{ .area, .pattern, .line, .symbol, .sounding, .text }) |l| {
        for ([_]i64{ 0, 12, 30, 99, -5 }) |p| {
            for ([_]i64{ 0, 1 }) |pl| {
                try testing.expect(key(l, p, pl, true) < KEY_MAX);
                try testing.expect(key(l, p, pl, false) < KEY_MAX);
            }
        }
    }
}
