//! ISO/IEC 8211 reader for S-57 ENC cells (.000/.NNN).
//! Port of pkg/iso8211. Parses the binary container into a Data Descriptive
//! Record (DDR, the schema) followed by Data Records (DR), each a set of
//! tag -> raw field bytes. S-57 semantics (subfield interpretation) live in
//! s57.zig (M6b).
//!
//! Spec: ISO 8211:1994 / IHO S-57 Part 3 Annex A.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FT: u8 = 0x1e; // field terminator
pub const UT: u8 = 0x1f; // unit terminator

pub const Leader = struct {
    record_length: usize,
    interchange_level: u8,
    leader_id: u8, // 'L' = DDR, 'D' = DR
    version: u8,
    field_control_length: usize,
    field_area_start: usize,
    size_of_field_length: u8,
    size_of_field_position: u8,
    size_of_field_tag: u8,

    fn parse(buf: []const u8) !Leader {
        if (buf.len < 24) return error.ShortLeader;
        const l: Leader = .{
            .record_length = try asciiInt(buf[0..5]),
            .interchange_level = buf[5],
            .leader_id = buf[6],
            .version = buf[8],
            .field_control_length = try asciiInt(buf[10..12]),
            .field_area_start = try asciiInt(buf[12..17]),
            .size_of_field_length = try asciiDigit(buf[20]),
            .size_of_field_position = try asciiDigit(buf[21]),
            .size_of_field_tag = try asciiDigit(buf[23]),
        };
        // validateLeader (oracle leader.go:163): reject a malformed leader rather than
        // parse garbage downstream. record_length 0 = the legal "compute from directory"
        // convention (resolved in parseRecord). The entry-map size fields must be 1..9 —
        // asciiDigit already bounds them to 0..9, so the real new constraint is non-zero
        // (a 0 would mis-size every directory entry). The leader-id check is NOT here: a
        // non-'D'/'L' id is the end-of-records padding sentinel parseRecord handles, so
        // it validates the id there (after that sentinel), not on every leader parse.
        if (l.record_length != 0 and l.record_length < 24) return error.BadLeader;
        if (l.size_of_field_length < 1 or l.size_of_field_length > 9) return error.BadLeader;
        if (l.size_of_field_position < 1 or l.size_of_field_position > 9) return error.BadLeader;
        if (l.size_of_field_tag < 1 or l.size_of_field_tag > 9) return error.BadLeader;
        return l;
    }
};

pub const DirectoryEntry = struct {
    tag: []const u8,
    length: usize,
    position: usize,
};

pub const Field = struct {
    tag: []const u8,
    data: []const u8, // field bytes, field terminator stripped
};

pub const SubfieldDef = struct {
    format_type: u8, // 'A','I','R','B',...
    width: usize, // 0 = variable
};

pub const FieldControl = struct {
    tag: []const u8,
    struct_code: u8, // 0=elementary,1=vector,2=array
    type_code: u8, // 0=char,1=implicit,5=binary
    name: []const u8,
    format_controls: []const u8,
    subfields: []SubfieldDef,
};

pub const Record = struct {
    leader: Leader,
    entries: []DirectoryEntry,
    fields: []Field,

    pub fn field(self: Record, tag: []const u8) ?[]const u8 {
        // Last match wins, matching the oracle's extractFields map (directory.go:101,
        // `fields[entry.Tag] = …` — a later directory entry with the same tag overwrites
        // the earlier one). Was first-wins; identical on valid S-57 (one field per tag
        // per record), so this only differs on a record with a duplicate tag.
        var result: ?[]const u8 = null;
        for (self.fields) |f| if (std.mem.eql(u8, f.tag, tag)) {
            result = f.data;
        };
        return result;
    }
};

pub const File = struct {
    ddr: Record,
    field_controls: []FieldControl,
    records: []Record,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *File) void {
        self.arena.deinit();
    }

    pub fn fieldControl(self: File, tag: []const u8) ?FieldControl {
        for (self.field_controls) |fc| if (std.mem.eql(u8, fc.tag, tag)) return fc;
        return null;
    }
};

fn asciiInt(buf: []const u8) !usize {
    var v: usize = 0;
    var any = false;
    for (buf) |c| {
        // A null byte in a numeric field means a corrupted or non-ISO-8211 record;
        // the oracle (parseASCIIInt, leader.go:133) errors rather than treat it as a
        // pad. Was silently skipped here. Spaces stay a pad (all-spaces -> 0), matching
        // the oracle's all-spaces case; valid NOAA numerics are zero-padded so this is a
        // no-op on reference data and only rejects corrupt input.
        if (c == 0) return error.BadAsciiInt;
        if (c == ' ') continue;
        if (c < '0' or c > '9') return error.BadAsciiInt;
        v = v * 10 + (c - '0');
        any = true;
    }
    return if (any) v else 0;
}

fn asciiDigit(c: u8) !u8 {
    if (c < '0' or c > '9') return error.BadAsciiDigit;
    return c - '0';
}

fn parseDirectory(a: Allocator, leader: Leader, rec: []const u8) ![]DirectoryEntry {
    const entry_len = leader.size_of_field_tag + leader.size_of_field_length + leader.size_of_field_position;
    var list = std.ArrayList(DirectoryEntry).empty;
    var pos: usize = 24;
    const dir_end = leader.field_area_start; // directory ends where field area begins
    // S-57 Part 3 A.2.3: the directory ends with a field terminator immediately before
    // the field area. Verify it (oracle directory.go:40 — reject a malformed directory
    // rather than parse garbage). The caller passes rec.len == field_area_start and
    // guards field_area_start >= 24, so dir_end>24 means rec[dir_end-1] is in bounds.
    if (dir_end <= 24 or rec[dir_end - 1] != FT) return error.MissingFieldTerminator;
    while (pos + entry_len <= dir_end) {
        if (rec[pos] == FT) break; // directory terminator
        const tag = rec[pos .. pos + leader.size_of_field_tag];
        var o = pos + leader.size_of_field_tag;
        const length = try asciiInt(rec[o .. o + leader.size_of_field_length]);
        o += leader.size_of_field_length;
        const position = try asciiInt(rec[o .. o + leader.size_of_field_position]);
        try list.append(a, .{ .tag = tag, .length = length, .position = position });
        pos += entry_len;
    }
    return list.items;
}

fn parseFields(a: Allocator, entries: []DirectoryEntry, field_area: []const u8) ![]Field {
    var list = std.ArrayList(Field).empty;
    for (entries) |e| {
        if (e.position + e.length > field_area.len) return error.FieldOutOfBounds;
        var data = field_area[e.position .. e.position + e.length];
        if (data.len > 0 and data[data.len - 1] == FT) data = data[0 .. data.len - 1];
        try list.append(a, .{ .tag = e.tag, .data = data });
    }
    return list.items;
}

// A record whose leader carries length 0 uses the ISO 8211 "length not stored"
// convention — recover the field-area size as the furthest directory entry's end
// (Position+Length). Some S-57 producers (e.g. USACE Inland ENCs) encode every
// data record this way; mirrors Go's fieldAreaSizeFromDirectory.
fn fieldAreaSizeFromDirectory(entries: []const DirectoryEntry) usize {
    var max: usize = 0;
    for (entries) |e| {
        const end = e.position + e.length;
        if (end > max) max = end;
    }
    return max;
}

fn parseRecord(a: Allocator, bytes: []const u8, offset: usize) !struct { rec: Record, next: usize } {
    var leader = try Leader.parse(bytes[offset..]);
    // record_length 0 on a non-'D'/'L' leader is trailing padding => end of records.
    if (leader.record_length == 0 and leader.leader_id != 'D' and leader.leader_id != 'L') return error.EndOfRecords;
    // A non-'D'/'L' id WITH a stored length is a malformed record, not padding — the
    // oracle's parseDataRecord errors on id != 'D' (parser.go:162); reject it (DDR 'L' /
    // DR 'D' both pass). Placed after the padding sentinel so zero-fill still ends cleanly.
    if (leader.leader_id != 'D' and leader.leader_id != 'L') return error.BadLeader;
    // The directory occupies [24, field_area_start) regardless of record_length, so
    // parse it first, then recover a "length not stored" (==0) record's true length.
    if (leader.field_area_start < 24 or offset + leader.field_area_start > bytes.len) return error.BadRecordLength;
    const entries = try parseDirectory(a, leader, bytes[offset .. offset + leader.field_area_start]);
    if (leader.record_length == 0) leader.record_length = leader.field_area_start + fieldAreaSizeFromDirectory(entries);
    if (leader.record_length < 24 or offset + leader.record_length > bytes.len) return error.BadRecordLength;
    const rec_bytes = bytes[offset .. offset + leader.record_length];
    const field_area = rec_bytes[leader.field_area_start..];
    const fields = try parseFields(a, entries, field_area);
    return .{ .rec = .{ .leader = leader, .entries = entries, .fields = fields }, .next = offset + leader.record_length };
}

/// Parse the DDR's data descriptive fields. In ISO 8211 each data field is
/// described by its OWN DDR entry (keyed by the real tag, e.g. "DSID","FRID").
/// A descriptive field's content is:
///   <field-control-length controls> <name> UT <array-descriptor> UT <format-controls>
/// where the array descriptor carries the '!'-joined subfield labels.
fn parseFieldControls(a: Allocator, ddr: Record, field_control_length: usize) ![]FieldControl {
    var list = std.ArrayList(FieldControl).empty;
    for (ddr.fields) |f| {
        if (std.mem.eql(u8, f.tag, "0000")) continue; // field control field
        if (f.data.len < 2) continue;
        const struct_code: u8 = if (f.data[0] >= '0' and f.data[0] <= '9') f.data[0] - '0' else 0;
        const type_code: u8 = if (f.data[1] >= '0' and f.data[1] <= '9') f.data[1] - '0' else 0;
        // Skip the fixed field-control bytes, then split name / array-desc / format.
        const rest = if (f.data.len > field_control_length) f.data[field_control_length..] else f.data[0..0];
        var it = std.mem.splitScalar(u8, rest, UT);
        const name = it.next() orelse "";
        _ = it.next(); // array descriptor (subfield labels) — unused; s57.zig uses the fixed schema
        const fmt = it.next() orelse "";
        try list.append(a, .{
            .tag = f.tag,
            .struct_code = struct_code,
            .type_code = type_code,
            .name = name,
            .format_controls = fmt,
            .subfields = try parseSubfields(a, fmt),
        });
    }
    return list.items;
}

/// Parse format controls like "(A,I(4),B(40))" into subfield defs.
pub fn parseSubfields(a: Allocator, fmt_in: []const u8) ![]SubfieldDef {
    var list = std.ArrayList(SubfieldDef).empty;
    var fmt = std.mem.trim(u8, fmt_in, " ");
    if (fmt.len == 0) return list.items;
    if (fmt[0] == '(') fmt = fmt[1..];
    if (fmt.len > 0 and fmt[fmt.len - 1] == ')') fmt = fmt[0 .. fmt.len - 1];

    var i: usize = 0;
    while (i < fmt.len) {
        // optional leading repeat count, e.g. "2A(3)" or "3I"
        var repeat: usize = 1;
        const rstart = i;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        if (i > rstart) repeat = try asciiInt(fmt[rstart..i]);
        if (i >= fmt.len) break;
        const ftype = fmt[i];
        i += 1;
        var width: usize = 0;
        if (i < fmt.len and fmt[i] == '(') {
            i += 1;
            const wstart = i;
            while (i < fmt.len and fmt[i] != ')') i += 1;
            width = try asciiInt(fmt[wstart..i]);
            if (i < fmt.len) i += 1; // skip ')'
        }
        var k: usize = 0;
        while (k < repeat) : (k += 1) try list.append(a, .{ .format_type = ftype, .width = width });
        if (i < fmt.len and fmt[i] == ',') i += 1;
    }
    return list.items;
}

/// Parse a whole ISO 8211 file from in-memory bytes (borrowed; keep alive).
pub fn parse(gpa: Allocator, bytes: []const u8) !File {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const first = try parseRecord(a, bytes, 0);
    if (first.rec.leader.leader_id != 'L') return error.NotADDR;
    const field_controls = try parseFieldControls(a, first.rec, first.rec.leader.field_control_length);

    var records = std.ArrayList(Record).empty;
    var off = first.next;
    while (off + 24 <= bytes.len) {
        // Oracle Parse loop (parser.go:88-97): a data-record parse error fails the WHOLE
        // file (`return nil, err`); only a clean end-of-records breaks. `catch break`
        // swallowed every error and kept the partial result — a malformed record left a
        // truncated-but-accepted cell instead of being dropped. Match: break on the
        // EndOfRecords padding sentinel (== Go io.EOF), propagate any genuine error so the
        // chart.zig catch-return drops the whole cell, like the oracle's per-cell skip.
        const r = parseRecord(a, bytes, off) catch |e| {
            if (e == error.EndOfRecords) break;
            return e;
        };
        try records.append(a, r.rec);
        off = r.next;
    }
    return .{ .ddr = first.rec, .field_controls = field_controls, .records = records.items, .arena = arena };
}

// ---- tests --------------------------------------------------------------

test "record_length==0 (length not stored) recovers size from the directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 24-byte leader with record length "00000" (not stored), field_area_start 34,
    // tag/len/pos sizes 4/3/2; one directory entry (tag TEST, len 5, pos 0) + FT;
    // then the 5-byte field area "DATA"+FT. True length must resolve to 39.
    const rec = "00000" ++ "3D 1 " ++ "00" ++ "00034" ++ "   " ++ "32 4" ++
        "TEST00500" ++ "\x1e" ++ "DATA\x1e";
    try std.testing.expectEqual(@as(usize, 39), rec.len);
    const r = try parseRecord(a, rec, 0);
    try std.testing.expectEqual(@as(usize, 39), r.rec.leader.record_length); // recovered, not 0
    try std.testing.expectEqual(@as(usize, 39), r.next);
    try std.testing.expectEqualSlices(u8, "DATA", r.rec.field("TEST").?);
    // A length-0 leader that parses but is NOT a 'D'/'L' record is trailing
    // padding -> end of records (mirrors Go's buf[6]!='D'&&!='L' io.EOF).
    const pad = "00000" ++ "     " ++ "00" ++ "00024" ++ "   " ++ "11 1"; // id byte (pos 6) = ' '
    try std.testing.expectEqual(@as(usize, 24), pad.len);
    try std.testing.expectError(error.EndOfRecords, parseRecord(a, pad, 0));
}

test "subfield format control parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = try parseSubfields(a, "(A,I(4),B(40))");
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(u8, 'A'), s[0].format_type);
    try std.testing.expectEqual(@as(usize, 0), s[0].width);
    try std.testing.expectEqual(@as(u8, 'I'), s[1].format_type);
    try std.testing.expectEqual(@as(usize, 4), s[1].width);
    try std.testing.expectEqual(@as(usize, 40), s[2].width);

    // repeat count expands.
    const r = try parseSubfields(a, "(2A(2),I)");
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqual(@as(u8, 'A'), r[0].format_type);
    try std.testing.expectEqual(@as(u8, 'A'), r[1].format_type);
    try std.testing.expectEqual(@as(u8, 'I'), r[2].format_type);
}

test "parse a synthesized minimal ISO 8211 file" {
    const a = std.testing.allocator;

    // Build a tiny DDR + one DR by hand. The DDR describes field "TEST" via its
    // OWN entry (S-57 convention): 9 field-control bytes, then
    // name UT array-descriptor UT format-controls.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);

    const fc_data = "0000;&   "; // field control field (0000) content, 9 bytes
    // "00" struct/type codes + 7 pad = 9 control bytes, then name/desc/format.
    const test_def = "000000000Test field" ++ [_]u8{UT} ++ "" ++ [_]u8{UT} ++ "(A)";

    try writeRecord(a, &buf, 'L', &.{
        .{ .tag = "0000", .data = fc_data },
        .{ .tag = "TEST", .data = test_def },
    });
    try writeRecord(a, &buf, 'D', &.{
        .{ .tag = "TEST", .data = "HELLO" },
    });

    var file = try parse(a, buf.items);
    defer file.deinit();

    try std.testing.expectEqual(@as(u8, 'L'), file.ddr.leader.leader_id);
    try std.testing.expectEqual(@as(usize, 1), file.records.len);
    try std.testing.expectEqualStrings("HELLO", file.records[0].field("TEST").?);

    const fc = file.fieldControl("TEST").?;
    try std.testing.expectEqualStrings("Test field", fc.name);
    try std.testing.expectEqual(@as(usize, 1), fc.subfields.len);
    try std.testing.expectEqual(@as(u8, 'A'), fc.subfields[0].format_type);
}

// Test helper: write a record (leader+directory+field area) with tag size 4,
// length size 3, position size 4 (matching real S-57 entry maps closely enough).
// pub so s57.zig's update-merge tests can synthesize base/update files too.
pub fn writeRecord(a: Allocator, out: *std.ArrayList(u8), leader_id: u8, fields: []const Field) !void {
    const TAGN = 4;
    const LENN = 3;
    const POSN = 4;
    var area = std.ArrayList(u8).empty;
    defer area.deinit(a);
    var dir = std.ArrayList(u8).empty;
    defer dir.deinit(a);
    for (fields) |f| {
        const pos = area.items.len;
        try area.appendSlice(a, f.data);
        try area.append(a, FT);
        const flen = f.data.len + 1;
        var ebuf: [TAGN + LENN + POSN]u8 = undefined;
        @memcpy(ebuf[0..TAGN], f.tag);
        _ = std.fmt.bufPrint(ebuf[TAGN .. TAGN + LENN], "{d:0>3}", .{flen}) catch unreachable;
        _ = std.fmt.bufPrint(ebuf[TAGN + LENN ..], "{d:0>4}", .{pos}) catch unreachable;
        try dir.appendSlice(a, &ebuf);
    }
    try dir.append(a, FT); // directory terminator
    const field_area_start = 24 + dir.items.len;
    const record_length = field_area_start + area.items.len;

    var leader: [24]u8 = undefined;
    @memset(&leader, ' ');
    _ = std.fmt.bufPrint(leader[0..5], "{d:0>5}", .{record_length}) catch unreachable;
    leader[5] = '3';
    leader[6] = leader_id;
    leader[8] = '1';
    leader[10] = '0';
    leader[11] = '9';
    _ = std.fmt.bufPrint(leader[12..17], "{d:0>5}", .{field_area_start}) catch unreachable;
    leader[20] = '0' + LENN;
    leader[21] = '0' + POSN;
    leader[22] = '0';
    leader[23] = '0' + TAGN;

    try out.appendSlice(a, &leader);
    try out.appendSlice(a, dir.items);
    try out.appendSlice(a, area.items);
}
