//! SYMINS02 native fallback (S-52 PresLib §13.2.18 / §10.3.3.8): portray an S-57
//! NEWOBJ from its producer SYMINS attribute (code 192) — a ';'-separated list of
//! S-52 draw ops SY()/TX()/TE()/LS()/LC()/AC()/AP() rendered verbatim, instead of
//! the S-101 V-AIS alias the FeatureCatalogue maps NEWOBJ to. This is how the S-52
//! PresLib "ECDIS Chart 1" labels / boundaries / fills are drawn.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57");
const instructions = @import("s101").instructions;
const catalogue = @import("s101").catalogue;
const style = @import("style");

pub const SYMINS_ATTR: u16 = 192;

fn syminsTrimQuotes(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, "'\"");
}

fn syminsArgAt(args: []const []const u8, i: usize) []const u8 {
    return if (i < args.len) args[i] else "";
}

/// The S-57 attribute value referenced by acronym (e.g. "OBJNAM"), trimmed, or null
/// when absent/blank. Mirrors Go lookupAttributeText over the feature's attrs.
fn syminsFeatAttr(f: s57.Feature, acr: []const u8) ?[]const u8 {
    for (f.attrs) |at| {
        const a2 = catalogue.attrAcronym(at.code) orelse continue;
        if (std.ascii.eqlIgnoreCase(a2, acr)) {
            const v = std.mem.trim(u8, at.value, " ");
            return if (v.len == 0) null else v;
        }
    }
    return null;
}

/// Split a SYMINS string on ';', honouring quotes and nested parens (so a ';' inside
/// TX('a;b',…) or between parens isn't a split). Returns slices into `s`.
fn syminsSplitInstructions(a: Allocator, s: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var depth: i32 = 0;
    var in_quote = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\'', '"' => in_quote = !in_quote,
            '(' => if (!in_quote) {
                depth += 1;
            },
            ')' => if (!in_quote) {
                depth -= 1;
            },
            ';' => if (!in_quote and depth == 0) {
                try out.append(a, s[start..i]);
                start = i + 1;
            },
            else => {},
        }
    }
    if (start < s.len) try out.append(a, s[start..]);
    return out.items;
}

/// Split "OP(params)" into the op and inner params, or null when malformed.
fn syminsSplitOp(instr0: []const u8) ?struct { op: []const u8, params: []const u8 } {
    const instr = std.mem.trim(u8, instr0, " \t");
    const open = std.mem.indexOfScalar(u8, instr, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, instr, ')') orelse return null;
    if (open == 0 or close < open) return null;
    return .{ .op = std.mem.trim(u8, instr[0..open], " \t"), .params = instr[open + 1 .. close] };
}

/// Split an instruction's params on ',', honouring quotes. Returns trimmed slices.
fn syminsSplitArgs(a: Allocator, params: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var in_quote = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const c = params[i];
        if (c == '\'' or c == '"') {
            in_quote = !in_quote;
        } else if (c == ',' and !in_quote) {
            try out.append(a, std.mem.trim(u8, params[start..i], " \t"));
            start = i + 1;
        }
    }
    try out.append(a, std.mem.trim(u8, params[start..], " \t"));
    return out.items;
}

/// printf-style format substitution for a SYMINS TE() instruction (S-52 §3.2.3.2):
/// each %-spec consumes the next attribute name and formats its value (floats honour
/// .precision; integer convs round; the '0' flag + width zero-pad). Mirrors Go
/// formatSubstitute + appendConverted + zeroPad. Returns null when an attribute is
/// missing (the whole label is then dropped, as in Go).
fn syminsZeroPad(a: Allocator, out: *std.ArrayList(u8), s: []const u8, width: usize, flags: []const u8) !void {
    const has0 = std.mem.indexOfScalar(u8, flags, '0') != null;
    const has_minus = std.mem.indexOfScalar(u8, flags, '-') != null;
    if (width <= s.len or !has0 or has_minus) {
        try out.appendSlice(a, s);
        return;
    }
    const pad = width - s.len;
    const signed = s.len > 0 and (s[0] == '-' or s[0] == '+' or s[0] == ' ');
    if (signed) try out.append(a, s[0]);
    var k: usize = 0;
    while (k < pad) : (k += 1) try out.append(a, '0');
    try out.appendSlice(a, if (signed) s[1..] else s);
}

fn syminsAppendConverted(a: Allocator, out: *std.ArrayList(u8), val: []const u8, conv: u8, precision: i32, width: usize, flags: []const u8) !void {
    var buf: [512]u8 = undefined;
    var s: []const u8 = val;
    switch (conv) {
        'f', 'e', 'g' => {
            if (std.fmt.parseFloat(f64, std.mem.trim(u8, val, " \t"))) |x| {
                s = std.fmt.float.render(&buf, x, .{
                    .mode = .decimal,
                    .precision = if (precision >= 0) @as(usize, @intCast(precision)) else null,
                }) catch val;
            } else |_| {}
        },
        'd', 'i', 'u', 'x' => {
            if (std.fmt.parseFloat(f64, std.mem.trim(u8, val, " \t"))) |x| {
                const r: i64 = @intFromFloat(@round(x));
                s = std.fmt.bufPrint(&buf, "{d}", .{r}) catch val;
            } else |_| {}
        },
        else => {},
    }
    try syminsZeroPad(a, out, s, width, flags);
}

fn syminsFormatSubstitute(a: Allocator, f: s57.Feature, format: []const u8, names: []const []const u8) !?[]const u8 {
    var out = std.ArrayList(u8).empty;
    var attr_idx: usize = 0;
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] != '%' or i + 1 >= format.len) {
            try out.append(a, format[i]);
            i += 1;
            continue;
        }
        if (format[i + 1] == '%') {
            try out.append(a, '%');
            i += 2;
            continue;
        }
        var j = i + 1;
        const flags_start = j;
        while (j < format.len and std.mem.indexOfScalar(u8, "-+ #0", format[j]) != null) j += 1;
        const flags = format[flags_start..j];
        var width: usize = 0;
        while (j < format.len and format[j] >= '0' and format[j] <= '9') : (j += 1) width = width * 10 + (format[j] - '0');
        var precision: i32 = -1;
        if (j < format.len and format[j] == '.') {
            j += 1;
            var p: i32 = 0;
            while (j < format.len and format[j] >= '0' and format[j] <= '9') : (j += 1) p = p * 10 + @as(i32, format[j] - '0');
            precision = p;
        }
        while (j < format.len and (format[j] == 'l' or format[j] == 'h' or format[j] == 'L')) j += 1;
        if (j >= format.len) {
            try out.appendSlice(a, format[i..]); // malformed trailing spec -> literal
            break;
        }
        const conv = format[j];
        switch (conv) {
            's', 'c', 'd', 'i', 'u', 'x', 'f', 'e', 'g' => {
                if (attr_idx >= names.len) return null;
                const acr = names[attr_idx];
                attr_idx += 1;
                const val = syminsFeatAttr(f, acr) orelse return null;
                try syminsAppendConverted(a, &out, val, conv, precision, width, flags);
            },
            else => try out.appendSlice(a, format[i .. j + 1]), // unknown conversion -> literal
        }
        i = j + 1;
    }
    return out.items;
}

/// Parse a SYMINS TX()/TE() instruction into a Text. The Text model carries the
/// label string, colour and viewing group; the S-52 justification / offset / font /
/// halo fields are dropped (tracked OpText findings), matching the current text path.
fn syminsText(a: Allocator, f: s57.Feature, op: []const u8, params: []const u8) !?instructions.Text {
    const args = try syminsSplitArgs(a, params);
    var text: []const u8 = "";
    var color_idx: usize = undefined;
    var display_idx: usize = undefined;
    if (std.mem.eql(u8, op, "TE")) {
        if (args.len < 10) return null;
        var names = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, syminsTrimQuotes(args[1]), ',');
        while (it.next()) |nm| {
            const t = std.mem.trim(u8, nm, " \t");
            if (t.len > 0) try names.append(a, t);
        }
        text = (try syminsFormatSubstitute(a, f, syminsTrimQuotes(args[0]), names.items)) orelse return null;
        color_idx = 8;
        display_idx = 9;
    } else { // TX
        if (args.len < 9) return null;
        const raw = args[0];
        if (raw.len > 0 and (raw[0] == '\'' or raw[0] == '"')) {
            text = syminsTrimQuotes(raw); // literal
        } else {
            text = syminsFeatAttr(f, std.mem.trim(u8, raw, " \t")) orelse return null;
        }
        color_idx = 7;
        display_idx = 8;
    }
    if (text.len == 0) return null;
    var color = std.mem.trim(u8, syminsArgAt(args, color_idx), " \t");
    if (color.len == 0) color = "CHBLK";
    const group = std.fmt.parseInt(i64, std.mem.trim(u8, syminsArgAt(args, display_idx), " \t"), 10) catch 0;
    return instructions.Text{ .text = text, .color = color, .group = group };
}

/// Build an S-101 Portrayal from a NEWOBJ's SYMINS attribute, or null when there is
/// no usable SYMINS (caller then falls back to the default new-object symbology).
/// Geometry/anchoring/clipping is handled by processFeatureParsed exactly like a rule stream.
pub fn buildSyminsPortrayal(a: Allocator, f: s57.Feature) !?instructions.Portrayal {
    const raw0 = f.attr(SYMINS_ATTR) orelse return null;
    const raw = std.mem.trim(u8, raw0, " ");
    if (raw.len == 0) return null;

    var points = std.ArrayList(instructions.Point).empty;
    var texts = std.ArrayList(instructions.Text).empty;
    var lines = std.ArrayList(instructions.Line).empty;
    var patterns = std.ArrayList([]const u8).empty;
    var fill_token: ?[]const u8 = null;

    for (try syminsSplitInstructions(a, raw)) |instr| {
        const opp = syminsSplitOp(instr) orelse continue;
        if (std.mem.eql(u8, opp.op, "SY")) { // SY(NAME[,rot])
            const args = try syminsSplitArgs(a, opp.params);
            const name = std.mem.trim(u8, syminsArgAt(args, 0), " \t");
            if (name.len == 0) continue;
            const rot: f64 = if (args.len > 1) (std.fmt.parseFloat(f64, std.mem.trim(u8, args[1], " \t")) catch 0) else 0;
            try points.append(a, .{ .symbol = name, .rotation = rot, .offset_x = 0, .offset_y = 0 });
        } else if (std.mem.eql(u8, opp.op, "TX") or std.mem.eql(u8, opp.op, "TE")) {
            if (try syminsText(a, f, opp.op, opp.params)) |t| try texts.append(a, t);
        } else if (std.mem.eql(u8, opp.op, "LS")) { // LS(style,width,colour)
            const args = try syminsSplitArgs(a, opp.params);
            if (args.len < 3) continue;
            var w = std.fmt.parseInt(i64, std.mem.trim(u8, args[1], " \t"), 10) catch 0;
            if (w <= 0) w = 1;
            const st = std.mem.trim(u8, args[0], " \t");
            const dashed = std.ascii.eqlIgnoreCase(st, "DASH") or std.ascii.eqlIgnoreCase(st, "DOTT");
            try lines.append(a, .{
                .style = if (dashed) "dash" else "solid",
                .width = @floatFromInt(w),
                .color = std.mem.trim(u8, args[2], " \t"),
            });
        } else if (std.mem.eql(u8, opp.op, "LC")) { // LC(LINESTYLE) — approximated as dashed
            const name = std.mem.trim(u8, syminsArgAt(try syminsSplitArgs(a, opp.params), 0), " \t");
            if (name.len == 0) continue;
            try lines.append(a, .{ .style = name, .width = 1, .color = "CHBLK" });
        } else if (std.mem.eql(u8, opp.op, "AC")) { // AC(COLOUR[,transp])
            const color = std.mem.trim(u8, syminsArgAt(try syminsSplitArgs(a, opp.params), 0), " \t");
            if (color.len > 0) fill_token = color;
        } else if (std.mem.eql(u8, opp.op, "AP")) { // AP(PATTERN)
            const name = std.mem.trim(u8, syminsArgAt(try syminsSplitArgs(a, opp.params), 0), " \t");
            if (name.len > 0) try patterns.append(a, name);
        }
    }
    if (points.items.len == 0 and texts.items.len == 0 and lines.items.len == 0 and
        patterns.items.len == 0 and fill_token == null) return null;
    return instructions.Portrayal{
        .fill_token = fill_token,
        .patterns = patterns.items,
        .lines = lines.items,
        .points = points.items,
        .texts = texts.items,
    };
}

test "buildSyminsPortrayal parses SY/TX/LS/LC/AC/AP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const attrs = [_]s57.Attr{.{
        .code = SYMINS_ATTR,
        .value = "SY(BOYSPP01,45);TX('Hello',1,2,0,'15110',0,0,CHRED,28);" ++
            "LS(DASH,3,CHGRD);LS(SOLD,2,CHBLK);LC(NAVARE51);AC(DEPVS);AP(DIAMOND1)",
    }};
    const f = s57.Feature{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 163, .attrs = &attrs };

    const p = (try buildSyminsPortrayal(a, f)) orelse return error.NoPortrayal;

    try std.testing.expectEqual(@as(usize, 1), p.points.len);
    try std.testing.expectEqualStrings("BOYSPP01", p.points[0].symbol);
    try std.testing.expectEqual(@as(f64, 45), p.points[0].rotation);

    try std.testing.expectEqual(@as(usize, 1), p.texts.len);
    try std.testing.expectEqualStrings("Hello", p.texts[0].text);
    try std.testing.expectEqualStrings("CHRED", p.texts[0].color);
    try std.testing.expectEqual(@as(i64, 28), p.texts[0].group);

    try std.testing.expectEqual(@as(usize, 3), p.lines.len); // 2x LS + 1x LC
    try std.testing.expectEqualStrings("dash", p.lines[0].style); // DASH -> dashed
    try std.testing.expectEqual(@as(f64, 3), p.lines[0].width);
    try std.testing.expectEqualStrings("CHGRD", p.lines[0].color);
    try std.testing.expectEqualStrings("solid", p.lines[1].style); // SOLD -> solid
    try std.testing.expectEqualStrings("NAVARE51", p.lines[2].style); // LC name verbatim

    try std.testing.expectEqualStrings("DEPVS", p.fill_token.?);
    try std.testing.expectEqual(@as(usize, 1), p.patterns.len);
    try std.testing.expectEqualStrings("DIAMOND1", p.patterns[0]);

    // A blank / absent SYMINS yields no portrayal.
    const f_empty = s57.Feature{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 163, .attrs = &[_]s57.Attr{.{ .code = SYMINS_ATTR, .value = "   " }} };
    try std.testing.expect((try buildSyminsPortrayal(a, f_empty)) == null);

    // Instruction-splitting honours a ';' inside a quoted TX string.
    const f_semi = s57.Feature{ .rcnm = 100, .rcid = 3, .prim = 1, .objl = 163, .attrs = &[_]s57.Attr{.{ .code = SYMINS_ATTR, .value = "TX('a;b',1,2,0,'15110',0,0,CHBLK,28)" }} };
    const ps = (try buildSyminsPortrayal(a, f_semi)) orelse return error.NoPortrayal;
    try std.testing.expectEqual(@as(usize, 1), ps.texts.len);
    try std.testing.expectEqualStrings("a;b", ps.texts[0].text);
}
