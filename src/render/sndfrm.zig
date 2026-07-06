//! SNDFRM04 sounding glyph composition — the SHARED routine: the tile engine
//! bakes sym_s/sym_g (+_ft) glyph lists from it, and the PixelSurface composes
//! the same lists live at the mariner's real safety depth / display unit. One
//! implementation, so the two paths cannot drift.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Metres -> feet, for the recreational whole-feet display variant.
pub const M_TO_FT: f64 = 3.280839895;

/// The S-52 symbol scale every point symbol / sounding is drawn at: screen px
/// per 0.01 mm symbol unit (2.8346 px/mm = the classic 72 dpi mm). The tile
/// path emits it as the `scale` prop (icon-size = scale / atlas ppu); the
/// pixel path multiplies symbol-mm geometry by 100x this.
pub const SYMBOL_SCALE: f64 = 0.02834627777338028;

/// Port of SNDFRM04's sounding glyph composition: build the comma-joined glyph-name
/// string for a depth and prefix ("SOUNDS" bold/shallow or "SOUNDG" faint/deep).
/// Covers the swept (B1) and low-accuracy-ring (C3 shallow / C2 deep) quality
/// prefixes, the negative-value A-prefix (drying heights), and the full magnitude
/// range up to 5 digits. Glyph order matches the rule: B1, ring, A-prefix, digits.
/// `swept`/`low_acc` come from the feature's quality attributes (TECSOU/QUASOU/
/// STATUS). NOTE: the rule's spatial-QUAPOS fallback for the ring (when the direct
/// attrs are absent) is not yet wired — soundings whose only low-accuracy signal is
/// a poor spatial quality-of-position still miss the ring; the direct attrs match.
pub fn syms(a: Allocator, prefix: []const u8, depth: f64, swept: bool, low_acc: bool, whole_feet: bool) ![]const u8 {
    const d = @abs(depth);
    // TRUNCATE to tenths (round DOWN), matching SNDFRM04: the rule splits the depth's
    // decimal string and takes string.sub(fractional, 1, 1) — the FIRST fractional
    // digit, discarding the rest (SNDFRM04.lua:53,72). So 4.57 m -> "4.5", never "4.6":
    // a sounding always errs SHALLOW (toward the surface), the safe direction for
    // navigation. The +1e-6 absorbs binary-FP error so an exact charted tenth stored a
    // hair low (4.1 as 4.0999…) still truncates to itself, not a notch shallower — while
    // a genuine sub-tenth value (a unit conversion, e.g. metres->feet) still floors down.
    // Was @round (nearest), which rounded UP across the half (14.76 ft -> 14.8) — both a
    // spec divergence AND the unsafe direction.
    const raw_tenths: i64 = @intFromFloat(@floor(d * 10.0 + 1e-6));
    // The feet display is a recreational unit shown as WHOLE feet — drop the tenth
    // (still truncated DOWN, so it stays shallow-erring). 14.76 ft -> "14", 32.8 -> "32".
    // Metres keep SNDFRM04's first-fractional-digit tenth (below 31 m).
    const tenths: i64 = if (whole_feet) @divTrunc(raw_tenths, 10) * 10 else raw_tenths;
    const idepth: i64 = @divTrunc(tenths, 10);
    const frac: u8 = @intCast(@mod(tenths, 10));
    var dbuf: [12]u8 = undefined;
    const ds = std.fmt.bufPrint(&dbuf, "{d}", .{idepth}) catch return "";
    var toks = std.ArrayList([]const u8).empty;

    // Quality prefixes lead the composite (SNDFRM04:37-51). Swept soundings get a B1
    // ring; low-accuracy ones get a ring sized to the variant — C3 on the shallow
    // SOUNDS glyph, C2 on the deep SOUNDG glyph (the rule's lowAccuracySymbolRing).
    if (swept) try toks.append(a, try std.fmt.allocPrint(a, "{s}B1", .{prefix}));
    if (low_acc) {
        const ring = if (std.mem.eql(u8, prefix, "SOUNDS")) "C3" else "C2";
        try toks.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, ring }));
    }

    // Negative soundings (drying heights / heights above datum) get an A-prefix ring
    // (SNDFRM04:62-68): A3 if |d|>=10 with a fraction, A2 if |d|>=10 whole, else A1.
    // (Only SOUNDS* A-glyphs exist — a negative sounding is always <= safety depth so
    // the style picks the SOUNDS variant; the SOUNDG variant is composed but unused.)
    if (depth < 0) {
        if (idepth >= 10 and frac != 0) {
            try toks.append(a, try std.fmt.allocPrint(a, "{s}A3", .{prefix}));
        } else if (idepth >= 10) {
            try toks.append(a, try std.fmt.allocPrint(a, "{s}A2", .{prefix}));
        } else {
            try toks.append(a, try std.fmt.allocPrint(a, "{s}A1", .{prefix}));
        }
    }

    if (idepth < 10) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[0] }));
        if (frac != 0) try toks.append(a, try std.fmt.allocPrint(a, "{s}5{d}", .{ prefix, frac }));
    } else if (idepth < 100 and frac != 0 and idepth < 31) {
        // Two integer digits + a subscript tenth — SNDFRM04's native metres rule below
        // 31 m. Feet never reaches here: `whole_feet` zeroed the tenth above (frac == 0),
        // so a converted sounding shows as whole feet, not a subscript fraction.
        try toks.append(a, try std.fmt.allocPrint(a, "{s}2{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[1] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}5{d}", .{ prefix, frac }));
    } else if (idepth < 100) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}0{c}", .{ prefix, ds[1] }));
    } else if (idepth < 1000) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}2{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[1] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}0{c}", .{ prefix, ds[2] }));
    } else if (idepth < 10000) {
        try toks.append(a, try std.fmt.allocPrint(a, "{s}2{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[1] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}0{c}", .{ prefix, ds[2] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}4{c}", .{ prefix, ds[3] }));
    } else {
        // >= 10000 m (deepest oceans ~11 km): 5 digits at codes 3,2,1,0,4.
        try toks.append(a, try std.fmt.allocPrint(a, "{s}3{c}", .{ prefix, ds[0] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}2{c}", .{ prefix, ds[1] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}1{c}", .{ prefix, ds[2] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}0{c}", .{ prefix, ds[3] }));
        try toks.append(a, try std.fmt.allocPrint(a, "{s}4{c}", .{ prefix, ds[4] }));
    }
    return std.mem.join(a, ",", toks.items);
}
