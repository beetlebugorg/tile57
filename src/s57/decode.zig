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
/// The chart's shorthand for a light character. S-57 Appendix A ch.2 2.146
/// gives each code's meaning and its INT 1 reference, and leaves the
/// abbreviation to INT 1 itself, so the codes below are the ones this table has
/// always held. `litchrText` names the rest from the catalogue rather than
/// dropping the whole characteristic.
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

/// The light character for a report: the chart's abbreviation where this table
/// holds one, else the catalogue's own wording. Thirteen of the 29 LITCHR codes
/// have no abbreviation here, and returning null for those dropped the
/// character, the period and the range from the report of an alternating light.
fn litchrText(code: u16) ?[]const u8 {
    if (abbrevOf(litchr_abbrev, code)) |abbr| return abbr;
    return enumValue("LITCHR", code);
}

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
    // Parse into i32. The value comes from the cell, and `v + 1` below
    // overflows on i64 max, which traps in a safety-checked build when the
    // mariner picks the feature. No scale denominator reaches i32 max.
    const v = std.fmt.parseInt(i32, raw, 10) catch return null;
    if (v <= 0) return null;
    const denom: i64 = if (@rem(@as(i64, v) + 1, 1000) == 0) @as(i64, v) + 1 else v;
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
    const abbr = litchrText(chr) orelse return null;
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
    // A SCAMIN past the i32 range reads as raw. The old i64 parse overflowed
    // on `v + 1` while formatting the pick report.
    try std.testing.expect(decodeValue(a, "SCAMIN", "9223372036854775807") == null);
    try std.testing.expect(decodeValue(a, "SCAMIN", "2147483648") == null);
    try std.testing.expect(decodeValue(a, "SCAMIN", "-1") == null);
    try std.testing.expectEqualStrings("1:2,147,483,647 and larger", decodeValue(a, "SCAMIN", "2147483647").?);
}

test "the signature is the chart's shorthand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"LITCHR\":\"4\",\"COLOUR\":\"4\",\"SIGPER\":\"1\",\"SIGGRP\":\"(1)\"}", .{});
    const sig = lightSignature(a, &parsed.value.object).?;
    try std.testing.expectEqualStrings("Q G 1s", sig);
}

// ---- the report -------------------------------------------------------------

/// Classes the generated table cannot name: the S-57 meta and collection
/// objects that S-101 does not contain, and the classes whose S-57 alias
/// is claimed by more than one S-101 feature.
const class_leftovers = [_]catalog.AttrName{
    .{ .acronym = "ADMARE", .name = "Administration area" },
    .{ .acronym = "BRIDGE", .name = "Bridge" },
    .{ .acronym = "CTNARE", .name = "Caution area" },
    .{ .acronym = "LIGHTS", .name = "Light" },
    .{ .acronym = "RESARE", .name = "Restricted area" },
    .{ .acronym = "M_NPUB", .name = "Nautical publication note" },
    .{ .acronym = "M_COVR", .name = "Chart coverage" },
    .{ .acronym = "M_QUAL", .name = "Data quality" },
    .{ .acronym = "M_NSYS", .name = "Buoyage system" },
    .{ .acronym = "M_ACCY", .name = "Data accuracy" },
    .{ .acronym = "M_SREL", .name = "Survey reliability" },
    .{ .acronym = "M_CSCL", .name = "Compilation scale" },
    .{ .acronym = "C_AGGR", .name = "Aggregation" },
    .{ .acronym = "C_ASSO", .name = "Association" },
};

/// The chart's name for an object class, or the class itself.
pub fn className(cls: []const u8) []const u8 {
    for (class_leftovers) |e| if (std.mem.eql(u8, e.acronym, cls)) return e.name;
    for (catalog_s101.class_names) |e| if (std.mem.eql(u8, e.acronym, cls)) return e.name;
    return cls;
}

/// One attribute of the payload, flattened. A complex attribute becomes a
/// heading with its parts indented under it.
const Row = struct { name: []const u8, value: []const u8, depth: u8 };

fn flatten(a: std.mem.Allocator, rows: *std.ArrayList(Row), v: std.json.Value, name: ?[]const u8, depth: u8) !void {
    switch (v) {
        .object => |obj| {
            if (name) |n| try rows.append(a, .{ .name = n, .value = "", .depth = depth });
            // Alphabetical order first; the reading order sorts the top
            // level after.
            var keys = std.ArrayList([]const u8).empty;
            var it = obj.iterator();
            while (it.next()) |e| try keys.append(a, e.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            for (keys.items) |k| {
                try flatten(a, rows, obj.get(k).?, k, if (name == null) depth else depth + 1);
            }
        },
        .array => |arr| {
            if (name) |n| try rows.append(a, .{ .name = n, .value = "", .depth = depth });
            for (arr.items) |item| try flatten(a, rows, item, null, depth + 1);
        },
        .string => |s| try rows.append(a, .{ .name = name orelse "", .value = s, .depth = depth }),
        .integer => |i| try rows.append(a, .{ .name = name orelse "", .value = try std.fmt.allocPrint(a, "{d}", .{i}), .depth = depth }),
        .float => |f| try rows.append(a, .{ .name = name orelse "", .value = try std.fmt.allocPrint(a, "{d}", .{f}), .depth = depth }),
        .bool => |b| try rows.append(a, .{ .name = name orelse "", .value = if (b) "true" else "false", .depth = depth }),
        else => {},
    }
}

/// The reading order of the top-level rows: the name first, then the
/// signal, then the shape, then the depths, then the rest in cell order.
const reading_order = [_][]const u8{
    "OBJNAM", "NOBJNM",
    "LITCHR", "COLOUR",
    "SIGPER", "SIGSEQ",
    "SIGGRP", "EXCLIT",
    "SECTR1", "SECTR2",
    "HEIGHT", "VALNMR",
    "CATLAM", "CATCAM",
    "CATLIT", "CATWRK",
    "CATOBS", "BOYSHP",
    "BCNSHP", "TOPSHP",
    "COLPAT", "VALSOU",
    "DRVAL1", "DRVAL2",
    "WATLEV", "NATSUR",
};

fn readingRank(name: []const u8) usize {
    for (reading_order, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return reading_order.len;
}

const RowGroup = enum { note, source, detail };

fn groupOf(name: []const u8) RowGroup {
    const notes = [_][]const u8{ "INFORM", "NINFOM" };
    const source = [_][]const u8{ "SCAMIN", "SORDAT", "SORIND", "RECDAT", "RECIND" };
    for (notes) |n| if (std.mem.eql(u8, n, name)) return .note;
    for (source) |n| if (std.mem.eql(u8, n, name)) return .source;
    return .detail;
}

fn isFileRef(name: []const u8, value: []const u8) bool {
    if (value.len == 0) return false;
    const refs = [_][]const u8{ "TXTDSC", "NTXTDS", "PICREP", "fileReference" };
    for (refs) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn isPicture(value: []const u8) bool {
    const exts = [_][]const u8{ ".tif", ".tiff", ".jpg", ".jpeg", ".png", ".TIF", ".TIFF", ".JPG", ".JPEG", ".PNG" };
    for (exts) |e| if (std.mem.endsWith(u8, value, e)) return true;
    return false;
}

/// A top-level scalar's text from the flattened rows.
fn rowValue(rows: []const Row, name: []const u8) ?[]const u8 {
    for (rows) |r| {
        if (r.depth == 0 and r.value.len > 0 and std.mem.eql(u8, r.name, name)) return r.value;
    }
    return null;
}

fn decodedOrNull(a: std.mem.Allocator, rows: []const Row, name: []const u8) ?[]const u8 {
    const raw = rowValue(rows, name) orelse return null;
    return decodeValue(a, name, raw);
}

const Header = struct { title: []const u8, subtitle: ?[]const u8 };

/// The title and subtitle for a feature. A class with a rule leads with
/// its key fact: a light's characteristic, a wreck's least depth, a depth
/// area's range. Other classes lead with the name or the class.
fn header(a: std.mem.Allocator, cls: []const u8, rows: []const Row) Header {
    const name = className(cls);
    if (std.mem.eql(u8, cls, "LIGHTS")) {
        if (lightSignatureRows(a, rows)) |sig| {
            var phrase: []const u8 = name;
            if (decodedOrNull(a, rows, "LITCHR")) |chr| {
                if (decodedOrNull(a, rows, "COLOUR")) |col| {
                    phrase = std.fmt.allocPrint(a, "{s} — {s} {s}", .{ name, lowered(a, chr), lowered(a, col) }) catch name;
                }
            }
            return .{ .title = sig, .subtitle = phrase };
        }
    }
    if (std.mem.eql(u8, cls, "WRECKS")) {
        if (rowValue(rows, "VALSOU")) |sou| {
            const v = decodeValue(a, "VALSOU", sou) orelse sou;
            return .{
                .title = std.fmt.allocPrint(a, "Wreck, {s}", .{v}) catch name,
                .subtitle = if (decodedOrNull(a, rows, "CATWRK")) |c|
                    std.fmt.allocPrint(a, "Wreck — {s}", .{c}) catch name
                else
                    name,
            };
        }
    }
    if (std.mem.eql(u8, cls, "DEPARE") or std.mem.eql(u8, cls, "DRGARE")) {
        if (rowValue(rows, "DRVAL1")) |d1| if (rowValue(rows, "DRVAL2")) |d2| {
            return .{ .title = std.fmt.allocPrint(a, "{s}–{s}", .{ d1, d2 }) catch name, .subtitle = name };
        };
    }
    const phrase = markPhrase(a, cls, rows) orelse areaPhrase(a, rows);
    if (rowValue(rows, "OBJNAM")) |objnam| {
        return .{ .title = objnam, .subtitle = phrase orelse name };
    }
    return .{ .title = name, .subtitle = phrase };
}

/// A mark's subtitle from shape, colour and category: "Buoy, lateral —
/// green can · port hand".
fn markPhrase(a: std.mem.Allocator, cls: []const u8, rows: []const Row) ?[]const u8 {
    const marky = std.mem.startsWith(u8, cls, "BOY") or std.mem.startsWith(u8, cls, "BCN") or
        std.mem.eql(u8, cls, "TOPMAR") or std.mem.eql(u8, cls, "DAYMAR");
    if (!marky) return null;
    const name = className(cls);
    const col = decodedOrNull(a, rows, "COLOUR");
    const shp = decodedOrNull(a, rows, "BOYSHP") orelse decodedOrNull(a, rows, "BCNSHP") orelse decodedOrNull(a, rows, "TOPSHP");
    const cat = decodedOrNull(a, rows, "CATLAM") orelse decodedOrNull(a, rows, "CATCAM");
    var lead: ?[]const u8 = null;
    if (col != null and shp != null) {
        lead = std.fmt.allocPrint(a, "{s} {s}", .{ lowered(a, col.?), shp.? }) catch null;
    } else if (col) |c| {
        lead = lowered(a, c);
    } else if (shp) |sh| {
        lead = sh;
    }
    if (lead != null and cat != null)
        return std.fmt.allocPrint(a, "{s} — {s} · {s}", .{ name, lead.?, cat.? }) catch null;
    if (lead) |l| return std.fmt.allocPrint(a, "{s} — {s}", .{ name, l }) catch null;
    if (cat) |c| return std.fmt.allocPrint(a, "{s} — {s}", .{ name, c }) catch null;
    return null;
}

/// An area's subtitle: its category, or its restriction.
fn areaPhrase(a: std.mem.Allocator, rows: []const Row) ?[]const u8 {
    return decodedOrNull(a, rows, "CATREA") orelse decodedOrNull(a, rows, "RESTRN");
}

fn lowered(a: std.mem.Allocator, s: []const u8) []const u8 {
    const out = a.dupe(u8, s) catch return s;
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// The light's characteristic from flattened rows. The ObjectMap variant
/// serves callers that hold parsed JSON.
fn lightSignatureRows(a: std.mem.Allocator, rows: []const Row) ?[]const u8 {
    const chr_raw = rowValue(rows, "LITCHR") orelse return null;
    const chr = std.fmt.parseInt(u16, chr_raw, 10) catch return null;
    const abbr = litchrText(chr) orelse return null;
    var out = std.ArrayList(u8).empty;
    out.appendSlice(a, abbr) catch return null;
    if (rowValue(rows, "SIGGRP")) |grp| {
        if (!std.mem.eql(u8, grp, "(1)") and !std.mem.eql(u8, grp, "()"))
            out.appendSlice(a, grp) catch return null;
    }
    if (rowValue(rows, "COLOUR")) |col_raw| {
        if (std.fmt.parseInt(u16, col_raw, 10) catch null) |col| {
            if (abbrevOf(colour_abbrev, col)) |letter| {
                out.append(a, ' ') catch return null;
                out.appendSlice(a, letter) catch return null;
            }
        }
    }
    appendNumUnitRows(a, &out, rows, "SIGPER", "s");
    appendNumUnitRows(a, &out, rows, "HEIGHT", "m");
    appendNumUnitRows(a, &out, rows, "VALNMR", "M");
    return out.items;
}

fn appendNumUnitRows(a: std.mem.Allocator, out: *std.ArrayList(u8), rows: []const Row, name: []const u8, unit: []const u8) void {
    const raw = rowValue(rows, name) orelse return;
    const n = std.fmt.parseFloat(f64, raw) catch return;
    const printed = std.fmt.allocPrint(a, " {d}{s}", .{ n, unit }) catch return;
    out.appendSlice(a, printed) catch {};
}

/// The chip: the short name for a list row.
fn chipTitle(a: std.mem.Allocator, cls: []const u8, rows: []const Row) []const u8 {
    if (std.mem.eql(u8, cls, "LIGHTS")) {
        if (lightSignatureRows(a, rows)) |sig| return sig;
    }
    if (std.mem.eql(u8, cls, "M_NPUB")) return "Chart notes";
    return className(cls);
}

/// The report a shell renders for one picked feature, as JSON:
/// {"title","subtitle","chip","notes":[…],"rows":[{"label","value","depth",
/// "file","picture"}…],"footnote","empty":"none"|"source"|"unreadable"}. The
/// "empty" field appears only when there is no text to read: "none" for a
/// feature with no attributes, "source" when it has some the report does not
/// show, and "unreadable" when its attribute blob did not parse. The caller
/// frees the bytes.
pub fn report(alloc: std.mem.Allocator, cls: []const u8, cell: []const u8, s57_json: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var rows = std.ArrayList(Row).empty;
    // A feature whose attribute blob does not parse read as one with no
    // attributes, so a wreck whose bytes were corrupted showed the same report
    // as a land area that has none. The third `empty` value tells them apart.
    var unreadable = false;
    if (s57_json.len > 0) {
        if (std.json.parseFromSlice(std.json.Value, a, s57_json, .{})) |parsed| {
            try flatten(a, &rows, parsed.value, null, 0);
        } else |_| {
            unreadable = true;
        }
    }

    // Sort the top-level blocks into reading order. Sub-rows stay under
    // their parents. The sort is stable for rows the order does not name.
    var blocks = std.ArrayList([]const Row).empty;
    {
        var i: usize = 0;
        while (i < rows.items.len) {
            var j = i + 1;
            while (j < rows.items.len and rows.items[j].depth > 0) : (j += 1) {}
            try blocks.append(a, rows.items[i..j]);
            i = j;
        }
        std.mem.sort([]const Row, blocks.items, {}, struct {
            fn lt(_: void, x: []const Row, y: []const Row) bool {
                return readingRank(x[0].name) < readingRank(y[0].name);
            }
        }.lt);
    }

    const hdr = header(a, cls, rows.items);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    const js = &stringify;

    try js.beginObject();
    try js.objectField("title");
    try js.write(hdr.title);
    if (hdr.subtitle) |sub| {
        try js.objectField("subtitle");
        try js.write(sub);
    }
    try js.objectField("chip");
    try js.write(chipTitle(a, cls, rows.items));

    try js.objectField("notes");
    try js.beginArray();
    for (rows.items) |r| {
        if (r.depth == 0 and groupOf(r.name) == .note and r.value.len > 0) try js.write(r.value);
    }
    try js.endArray();

    var n_detail: usize = 0;
    try js.objectField("rows");
    try js.beginArray();
    for (blocks.items) |block| {
        if (groupOf(block[0].name) != .detail) continue;
        for (block) |r| {
            n_detail += 1;
            try js.beginObject();
            try js.objectField("label");
            try js.write(attrName(r.name));
            try js.objectField("value");
            try js.write(decodeValue(a, r.name, r.value) orelse r.value);
            if (r.depth > 0) {
                try js.objectField("depth");
                try js.write(r.depth);
            }
            if (isFileRef(r.name, r.value)) {
                try js.objectField("file");
                try js.write(true);
                if (isPicture(r.value)) {
                    try js.objectField("picture");
                    try js.write(true);
                }
            }
            try js.endObject();
        }
    }
    try js.endArray();

    // The provenance as one line: the cell, the source, the source date,
    // and the charted scale range.
    var foot = std.ArrayList(u8).empty;
    try foot.appendSlice(a, cell);
    const source_attrs = [_][]const u8{ "SORIND", "SORDAT", "SCAMIN" };
    for (source_attrs) |sn| {
        if (rowValue(rows.items, sn)) |raw| {
            try foot.appendSlice(a, "  ·  ");
            try foot.appendSlice(a, decodeValue(a, sn, raw) orelse raw);
        }
    }
    try js.objectField("footnote");
    try js.write(foot.items);

    var n_notes: usize = 0;
    for (rows.items) |r| {
        if (r.depth == 0 and groupOf(r.name) == .note and r.value.len > 0) n_notes += 1;
    }
    if (n_detail == 0 and n_notes == 0) {
        try js.objectField("empty");
        try js.write(if (unreadable) "unreadable" else if (rows.items.len == 0) "none" else "source");
    }
    try js.endObject();

    return aw.toOwnedSlice();
}

test "report composes the page" {
    const a = std.testing.allocator;
    const json =
        \\{"COLOUR":"4","LITCHR":"4","SIGPER":"1","SIGGRP":"(1)","SIGSEQ":"00.3+(00.7)",
        \\"EXCLIT":"4","SCAMIN":"29999","SORDAT":"20010106","SORIND":"US,US,graph,Chart 12283",
        \\"INFORM":"Seasonal aid"}
    ;
    const out = try report(a, "LIGHTS", "US5MD1MC", json);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Q G 1s\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Seasonal aid") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Quick-flashing") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1:30,000 and larger") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Chart 12283 (US)") != null);
}

test "report marks an empty body" {
    const a = std.testing.allocator;
    const out = try report(a, "SLCONS", "C", "{\"SORDAT\":\"20010106\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"empty\":\"source\"") != null);
    const none = try report(a, "LNDARE", "C", "{}");
    defer a.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "\"empty\":\"none\"") != null);
}

test "a light character without an abbreviation still reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Sixteen of the 29 LITCHR codes have a chart abbreviation here. The other
    // thirteen dropped the character, the period and the range from the report.
    try std.testing.expectEqualStrings("Fl", litchrText(2).?);
    try std.testing.expectEqualStrings("Q+LFl", litchrText(25).?);
    try std.testing.expectEqualStrings("Occulting alternating", litchrText(17).?);
    try std.testing.expectEqualStrings("Group alternating", litchrText(20).?);
    try std.testing.expectEqualStrings("Ultra quick-flash plus long-flash", litchrText(27).?);
    try std.testing.expect(litchrText(99) == null);

    // The whole signature reads for an alternating light.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"LITCHR\":\"17\",\"COLOUR\":\"1\",\"SIGPER\":\"6\"}", .{});
    const sig = lightSignature(a, &parsed.value.object).?;
    try std.testing.expect(std.mem.indexOf(u8, sig, "Occulting alternating") != null);
    try std.testing.expect(std.mem.indexOf(u8, sig, "6s") != null);
}

test "a report says when the attributes did not read" {
    const a = std.testing.allocator;

    // A feature with no attributes and one whose blob is corrupt looked the
    // same, so a mariner read "this wreck records no depth" for one that could
    // not be read.
    const none = try report(a, "LNDARE", "US5MD1MC", "{}");
    defer a.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "\"empty\":\"none\"") != null);

    const bad = try report(a, "WRECKS", "US5MD1MC", "{\"VALSOU\":");
    defer a.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "\"empty\":\"unreadable\"") != null);
}
