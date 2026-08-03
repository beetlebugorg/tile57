//! S-57 decode for the pick report.
//!
//! The cell stores acronyms and enum codes. This module translates them:
//! COLOUR 4 becomes "Green", and a LIGHTS object gets its characteristic
//! "Q G 1s". Every shell reads the same decode.
//!
//! The decode is conservative. An acronym or a code that the catalogue
//! does not contain passes through unchanged.
//!
//! catalog.zig holds the S-57 attribute catalogue as data. This file holds
//! the chart shorthand (the chart prints "Fl(2) G 6s"; the catalogue does
//! not) and the value print rules.

const std = @import("std");
const catalog = @import("catalog.zig");
const catalog_s101 = @import("catalog_s101.zig");

// ---- catalogue lookups ------------------------------------------------------

/// The label for an attribute, or the attribute itself when no catalogue
/// contains it. S-57 acronyms read the S-57 catalogue. S-101 codes read
/// the generated Feature Catalogue tables. The two stay separate: S-101
/// changed attributes that it took from S-57, so an S-57 code must not
/// read the S-101 tables.
pub fn attrName(acronym: []const u8) []const u8 {
    for (catalog.attribute_names) |e| {
        if (std.mem.eql(u8, e.acronym, acronym)) return e.name;
    }
    for (catalog_s101.attribute_names) |e| {
        if (std.mem.eql(u8, e.acronym, acronym)) return e.name;
    }
    return acronym;
}

fn enumValue(acronym: []const u8, code: u16) ?[]const u8 {
    for (catalog.enum_values) |e| {
        if (e.code == code and std.mem.eql(u8, e.acronym, acronym)) return e.value;
    }
    for (catalog_s101.enum_values) |e| {
        if (e.code == code and std.mem.eql(u8, e.acronym, acronym)) return e.value;
    }
    return null;
}

// ---- portrayal shorthand ----------------------------------------------------

/// The chart's abbreviation for a light character (LITCHR). The catalogue
/// says "quick-flashing"; the chart prints "Q".
const litchr_abbrev = [_]struct { code: u16, abbr: []const u8 }{
    .{ .code = 1, .abbr = "F" },       .{ .code = 2, .abbr = "Fl" },
    .{ .code = 3, .abbr = "LFl" },     .{ .code = 4, .abbr = "Q" },
    .{ .code = 5, .abbr = "VQ" },      .{ .code = 6, .abbr = "UQ" },
    .{ .code = 7, .abbr = "Iso" },     .{ .code = 8, .abbr = "Oc" },
    .{ .code = 9, .abbr = "IQ" },      .{ .code = 10, .abbr = "IVQ" },
    .{ .code = 11, .abbr = "IUQ" },    .{ .code = 12, .abbr = "Mo" },
    .{ .code = 13, .abbr = "FFl" },    .{ .code = 25, .abbr = "Q+LFl" },
    .{ .code = 26, .abbr = "VQ+LFl" }, .{ .code = 28, .abbr = "Al" },
};

/// The chart's letter for a light colour (COLOUR).
const colour_abbrev = [_]struct { code: u16, abbr: []const u8 }{
    .{ .code = 1, .abbr = "W" },   .{ .code = 3, .abbr = "R" },
    .{ .code = 4, .abbr = "G" },   .{ .code = 5, .abbr = "Bu" },
    .{ .code = 6, .abbr = "Y" },   .{ .code = 9, .abbr = "Am" },
    .{ .code = 10, .abbr = "Vi" }, .{ .code = 11, .abbr = "Or" },
};

fn abbrevOf(comptime table: anytype, code: u16) ?[]const u8 {
    for (table) |e| if (e.code == code) return e.abbr;
    return null;
}

// ---- value decoding ---------------------------------------------------------

/// The separator for a decoded value list. COLOUR joins with "over": the
/// list gives the order of the bands on the mark.
fn listSeparator(acronym: []const u8) []const u8 {
    return if (std.mem.eql(u8, acronym, "COLOUR")) " over " else ", ";
}

/// Decode one attribute value. The caller owns the returned slice's arena.
/// Returns null when the tables cannot read the value; the caller keeps the
/// raw text.
pub fn decodeValue(a: std.mem.Allocator, acronym: []const u8, raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;
    if (std.mem.eql(u8, acronym, "SIGPER")) return withUnit(a, raw, "s");
    if (std.mem.eql(u8, acronym, "HEIGHT") or std.mem.eql(u8, acronym, "ELEVAT") or
        std.mem.eql(u8, acronym, "VERCLR") or std.mem.eql(u8, acronym, "HORCLR") or
        std.mem.eql(u8, acronym, "VERLEN"))
        return withUnit(a, raw, "m"); // heights stay metric: the chart's rule
    if (std.mem.eql(u8, acronym, "VALNMR")) return withUnit(a, raw, "M");
    if (std.mem.eql(u8, acronym, "SECTR1") or std.mem.eql(u8, acronym, "SECTR2") or
        std.mem.eql(u8, acronym, "ORIENT"))
        return withUnit(a, raw, "°");
    if (std.mem.eql(u8, acronym, "SIGSEQ")) return sequence(a, raw);
    if (std.mem.eql(u8, acronym, "SCAMIN")) return scamin(a, raw);
    if (std.mem.eql(u8, acronym, "SORIND")) return sorind(a, raw);
    if (std.mem.eql(u8, acronym, "SORDAT") or std.mem.eql(u8, acronym, "RECDAT") or
        std.mem.eql(u8, acronym, "PEREND") or std.mem.eql(u8, acronym, "PERSTA") or
        std.mem.eql(u8, acronym, "DATSTA") or std.mem.eql(u8, acronym, "DATEND"))
        return date(a, raw);
    return decodeEnumList(a, acronym, raw);
}

/// Decode a comma list such as "3,1": each code through the catalogue,
/// joined by the attribute's separator. Returns null when no code in the
/// list is known.
fn decodeEnumList(a: std.mem.Allocator, acronym: []const u8, raw: []const u8) ?[]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    var any = false;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " ");
        const code = std.fmt.parseInt(u16, p, 10) catch {
            parts.append(a, p) catch return null;
            continue;
        };
        if (enumValue(acronym, code)) |v| {
            parts.append(a, v) catch return null;
            any = true;
        } else {
            parts.append(a, p) catch return null;
        }
    }
    if (!any or parts.items.len == 0) return null;
    return std.mem.join(a, listSeparator(acronym), parts.items) catch null;
}

/// Append a unit to a plain number. A value that already contains text
/// stays unchanged, so a formatted value does not get a second unit.
fn withUnit(a: std.mem.Allocator, raw: []const u8, unit: []const u8) ?[]const u8 {
    _ = std.fmt.parseFloat(f64, raw) catch return null;
    return std.fmt.allocPrint(a, "{s} {s}", .{ raw, unit }) catch null;
}

/// Print a signal sequence: "00.3+(00.7)" becomes "0.3 s on, 0.7 s off".
/// Times in brackets are eclipse.
fn sequence(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    var on = std.ArrayList([]const u8).empty;
    var off = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, raw, '+');
    while (it.next()) |part| {
        const s = std.mem.trim(u8, part, " ");
        const dark = s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')';
        const num_text = if (dark) s[1 .. s.len - 1] else s;
        const n = std.fmt.parseFloat(f64, num_text) catch return null;
        const printed = std.fmt.allocPrint(a, "{d}", .{n}) catch return null;
        (if (dark) &off else &on).append(a, printed) catch return null;
    }
    if (on.items.len == 0 or off.items.len == 0) return null;
    const on_s = std.mem.join(a, " + ", on.items) catch return null;
    const off_s = std.mem.join(a, " + ", off.items) catch return null;
    return std.fmt.allocPrint(a, "{s} s on, {s} s off", .{ on_s, off_s }) catch null;
}

/// Print SCAMIN, the smallest scale the object shows at: 29999 becomes
/// "1:30,000 and larger".
fn scamin(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const v = std.fmt.parseInt(i64, raw, 10) catch return null;
    if (v <= 0) return null;
    const denom: i64 = if (@rem(v + 1, 1000) == 0) v + 1 else v;
    return std.fmt.allocPrint(a, "1:{s} and larger", .{grouped(a, denom) orelse return null}) catch null;
}

/// Group digits: 30000 becomes "30,000".
fn grouped(a: std.mem.Allocator, v: i64) ?[]const u8 {
    var buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return null;
    var out = std.ArrayList(u8).empty;
    for (digits, 0..) |c, i| {
        const remaining = digits.len - i;
        if (i != 0 and remaining % 3 == 0) out.append(a, ',') catch return null;
        out.append(a, c) catch return null;
    }
    return out.items;
}

/// Print SORIND (country, authority, type, source): "US,US,graph,Chart
/// 12283" becomes "Chart 12283 (US)". Any other shape stays unchanged.
fn sorind(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    var parts: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |p| : (n += 1) {
        if (n >= parts.len) return null;
        parts[n] = std.mem.trim(u8, p, " ");
    }
    if (n != 4 or parts[3].len == 0) return null;
    return std.fmt.allocPrint(a, "{s} ({s})", .{ parts[3], parts[0] }) catch null;
}

/// Print an S-57 date (yyyymmdd, yyyymm, or yyyy). A season date "--MMDD"
/// repeats every year and prints as one.
fn date(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const months = [_][]const u8{ "", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (std.mem.startsWith(u8, raw, "--") and raw.len >= 6) {
        const m = std.fmt.parseInt(u8, raw[2..4], 10) catch return null;
        const d = std.fmt.parseInt(u8, raw[4..6], 10) catch return null;
        if (m < 1 or m > 12 or d < 1 or d > 31) return null;
        return std.fmt.allocPrint(a, "{d} {s} each year", .{ d, months[m] }) catch null;
    }
    if (raw.len < 4) return null;
    const year = std.fmt.parseInt(u16, raw[0..4], 10) catch return null;
    var mon: []const u8 = "";
    if (raw.len >= 6) {
        const m = std.fmt.parseInt(u8, raw[4..6], 10) catch 0;
        if (m >= 1 and m <= 12) mon = months[m];
    }
    if (raw.len >= 8 and mon.len > 0) {
        const d = std.fmt.parseInt(u8, raw[6..8], 10) catch 0;
        if (d >= 1 and d <= 31)
            return std.fmt.allocPrint(a, "{d} {s} {d}", .{ d, mon, year }) catch null;
    }
    if (mon.len > 0) return std.fmt.allocPrint(a, "{s} {d}", .{ mon, year }) catch null;
    return std.fmt.allocPrint(a, "{d}", .{year}) catch null;
}

// ---- the light's signature --------------------------------------------------

/// The light's characteristic as the chart prints it: "Fl(2) G 6s 7m 5M",
/// built from the parts the object carries. Returns null when LITCHR is
/// absent or unknown.
pub fn lightSignature(a: std.mem.Allocator, attrs: *const std.json.ObjectMap) ?[]const u8 {
    const chr_raw = strAttr(attrs, "LITCHR") orelse return null;
    const chr = std.fmt.parseInt(u16, chr_raw, 10) catch return null;
    const abbr = abbrevOf(litchr_abbrev, chr) orelse return null;
    var out = std.ArrayList(u8).empty;
    out.appendSlice(a, abbr) catch return null;
    if (strAttr(attrs, "SIGGRP")) |grp| {
        if (grp.len > 0 and !std.mem.eql(u8, grp, "(1)") and !std.mem.eql(u8, grp, "()"))
            out.appendSlice(a, grp) catch return null;
    }
    if (strAttr(attrs, "COLOUR")) |col_raw| {
        if (std.fmt.parseInt(u16, col_raw, 10) catch null) |col| {
            if (abbrevOf(colour_abbrev, col)) |letter| {
                out.append(a, ' ') catch return null;
                out.appendSlice(a, letter) catch return null;
            }
        }
    }
    appendNumUnit(a, &out, attrs, "SIGPER", "s");
    appendNumUnit(a, &out, attrs, "HEIGHT", "m");
    appendNumUnit(a, &out, attrs, "VALNMR", "M");
    return out.items;
}

fn appendNumUnit(a: std.mem.Allocator, out: *std.ArrayList(u8), attrs: *const std.json.ObjectMap, acronym: []const u8, unit: []const u8) void {
    const raw = strAttr(attrs, acronym) orelse return;
    const n = std.fmt.parseFloat(f64, raw) catch return;
    const printed = std.fmt.allocPrint(a, " {d}{s}", .{ n, unit }) catch return;
    out.appendSlice(a, printed) catch {};
}

/// A top-level scalar attribute as text, whatever JSON type the cell used.
fn strAttr(attrs: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = attrs.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ---- tests ------------------------------------------------------------------

test "decodeValue reads the catalogue and the print forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1 s", decodeValue(a, "SIGPER", "1").?);
    try std.testing.expectEqualStrings("0.3 s on, 0.7 s off", decodeValue(a, "SIGSEQ", "00.3+(00.7)").?);
    try std.testing.expectEqualStrings("1:30,000 and larger", decodeValue(a, "SCAMIN", "29999").?);
    try std.testing.expectEqualStrings("Chart 12283 (US)", decodeValue(a, "SORIND", "US,US,graph,Chart 12283").?);
    try std.testing.expectEqualStrings("6 Jan 2001", decodeValue(a, "SORDAT", "20010106").?);
    try std.testing.expectEqualStrings("15 Jun each year", decodeValue(a, "PERSTA", "--0615").?);
    // Unknown codes pass through as raw (null): never invent a meaning.
    try std.testing.expect(decodeValue(a, "NOSUCH", "7") == null);
}

test "the signature is the chart's shorthand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"LITCHR\":\"4\",\"COLOUR\":\"4\",\"SIGPER\":\"1\",\"SIGGRP\":\"(1)\"}", .{});
    const sig = lightSignature(a, &parsed.value.object).?;
    try std.testing.expectEqualStrings("Q G 1s", sig);
}
