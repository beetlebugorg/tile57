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

/// Parse format controls like "(A,I(4),B(40))" into subfield defs. ISO 8211 allows
/// nested parenthesized groups with an optional leading repeat count — e.g. UKHO's
/// "(b11,b14,7A,A(8),3A,(b11))" and "(b11,(3b24))" — where the group's formats repeat
/// `repeat` times. (These defs are informational: s57/s101 decode records by their
/// fixed schema, so the value here is that a legal DDR parses; a group must NOT be
/// mistaken for a `(width)` and fed to the integer parser — SHOM cells lack nesting,
/// UKHO cells have it.)
pub fn parseSubfields(a: Allocator, fmt_in: []const u8) ![]SubfieldDef {
    var list = std.ArrayList(SubfieldDef).empty;
    var fmt = std.mem.trim(u8, fmt_in, " ");
    if (fmt.len == 0) return list.items;
    if (fmt[0] == '(') fmt = fmt[1..];
    if (fmt.len > 0 and fmt[fmt.len - 1] == ')') fmt = fmt[0 .. fmt.len - 1];
    try parseFmtList(a, &list, fmt);
    return list.items;
}

/// Parse one comma-separated format list into `list`, recursing into parenthesized
/// groups. Each recursion consumes a shorter (parens-stripped) slice, so it terminates.
fn parseFmtList(a: Allocator, list: *std.ArrayList(SubfieldDef), fmt: []const u8) !void {
    var i: usize = 0;
    while (i < fmt.len) {
        // optional leading repeat count, e.g. "2A(3)", "3I", "2(A,I)"
        var repeat: usize = 1;
        const rstart = i;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        if (i > rstart) repeat = asciiInt(fmt[rstart..i]) catch 1;
        if (i >= fmt.len) break;

        if (fmt[i] == '(') {
            // A nested group: find its balanced ')' and expand its contents `repeat` times.
            const gstart = i + 1;
            var depth: usize = 1;
            var j = gstart;
            while (j < fmt.len and depth > 0) : (j += 1) {
                if (fmt[j] == '(') depth += 1 else if (fmt[j] == ')') depth -= 1;
            }
            const inner = fmt[gstart .. j - @intFromBool(depth == 0)]; // drop the closing ')'
            var k: usize = 0;
            while (k < repeat) : (k += 1) try parseFmtList(a, list, inner);
            i = j;
        } else {
            const ftype = fmt[i];
            i += 1;
            var width: usize = 0;
            if (i < fmt.len and fmt[i] == '(') {
                i += 1;
                const wstart = i;
                while (i < fmt.len and fmt[i] != ')') i += 1;
                // Tolerant: a width is informational and unused; a mis-aligned scan
                // over binary notation ("b24") must not abort the whole DDR parse.
                width = asciiInt(fmt[wstart..i]) catch 0;
                if (i < fmt.len) i += 1; // skip ')'
            }
            var k: usize = 0;
            while (k < repeat) : (k += 1) try list.append(a, .{ .format_type = ftype, .width = width });
        }
        if (i < fmt.len and fmt[i] == ',') i += 1;
    }
}

// ---- allocation-free lazy reader ---------------------------------------
// A streaming view over the same records `parse` builds, but WITHOUT an arena:
// nothing is allocated, and each field is resolved on demand straight out of
// the input bytes. Use it for the peek / ENC_ROOT-index path, where only a
// field or two per cell is read and a full parse (+ its arena) is pure waste.
// Semantics match the eager path: the same leader validation, the same
// "length not stored" (record_length==0) recovery, FT-stripped field data, and
// last-match-wins on a duplicate tag. It is tolerant of a malformed directory
// entry (returns what it has) rather than failing the whole record -- which is
// exactly what a best-effort peek wants. Portable Zig: no target-specific code,
// so it runs the same on native and wasm.

/// Directory extent (max position+length) of a record, allocation-free -- the
/// raw-bytes twin of `fieldAreaSizeFromDirectory`, for the length==0 recovery.
fn directoryExtent(rec: []const u8, leader: Leader) usize {
    const entry_len = @as(usize, leader.size_of_field_tag) + leader.size_of_field_length + leader.size_of_field_position;
    const dir_end = leader.field_area_start;
    var pos: usize = 24;
    var extent: usize = 0;
    while (pos + entry_len <= dir_end) : (pos += entry_len) {
        if (rec[pos] == FT) break;
        var o = pos + leader.size_of_field_tag;
        const length = asciiInt(rec[o .. o + leader.size_of_field_length]) catch break;
        o += leader.size_of_field_length;
        const position = asciiInt(rec[o .. o + leader.size_of_field_position]) catch break;
        if (position + length > extent) extent = position + length;
    }
    return extent;
}

/// One record, viewed in place. `field` walks the directory each call; that is
/// cheaper than allocating an entries+fields model when only a few tags are read.
pub const RecordView = struct {
    base: []const u8, // the record's bytes, base[0..record_length]
    leader: Leader,

    /// The first directory entry's tag — the record discriminator (e.g. "FRID"
    /// vs "VRID") — or null for an empty directory. The lazy, allocation-free
    /// twin of the eager `rec.fields[0].tag`.
    pub fn firstTag(self: RecordView) ?[]const u8 {
        const L = self.leader;
        const entry_len = @as(usize, L.size_of_field_tag) + L.size_of_field_length + L.size_of_field_position;
        if (24 + entry_len > L.field_area_start or self.base[24] == FT) return null;
        return self.base[24 .. 24 + L.size_of_field_tag];
    }

    /// Walk the record's fields in directory order, allocation-free — the lazy
    /// twin of the eager `rec.fields` slice (same FT-stripped data). Tolerant
    /// like `field`: a malformed directory entry ends the walk, an
    /// out-of-bounds one is skipped.
    pub const FieldIterator = struct {
        view: RecordView,
        pos: usize = 24,

        pub fn next(self: *FieldIterator) ?Field {
            const L = self.view.leader;
            const base = self.view.base;
            const entry_len = @as(usize, L.size_of_field_tag) + L.size_of_field_length + L.size_of_field_position;
            const dir_end = L.field_area_start;
            if (dir_end <= 24 or dir_end > base.len) return null;
            const field_area = base[dir_end..];
            while (self.pos + entry_len <= dir_end) {
                const pos = self.pos;
                self.pos += entry_len;
                if (base[pos] == FT) return null; // directory terminator
                const tag = base[pos .. pos + L.size_of_field_tag];
                var o = pos + L.size_of_field_tag;
                const length = asciiInt(base[o .. o + L.size_of_field_length]) catch return null;
                o += L.size_of_field_length;
                const position = asciiInt(base[o .. o + L.size_of_field_position]) catch return null;
                if (position + length > field_area.len) continue;
                var data = field_area[position .. position + length];
                if (data.len > 0 and data[data.len - 1] == FT) data = data[0 .. data.len - 1];
                return .{ .tag = tag, .data = data };
            }
            return null;
        }
    };

    pub fn fields(self: RecordView) FieldIterator {
        return .{ .view = self };
    }

    pub fn field(self: RecordView, tag: []const u8) ?[]const u8 {
        const L = self.leader;
        if (tag.len != L.size_of_field_tag) return null;
        const entry_len = @as(usize, L.size_of_field_tag) + L.size_of_field_length + L.size_of_field_position;
        const dir_end = L.field_area_start;
        if (dir_end <= 24 or dir_end > self.base.len) return null;
        const field_area = self.base[L.field_area_start..];
        var result: ?[]const u8 = null;
        var pos: usize = 24;
        while (pos + entry_len <= dir_end) : (pos += entry_len) {
            if (self.base[pos] == FT) break; // directory terminator
            const etag = self.base[pos .. pos + L.size_of_field_tag];
            var o = pos + L.size_of_field_tag;
            const length = asciiInt(self.base[o .. o + L.size_of_field_length]) catch return result;
            o += L.size_of_field_length;
            const position = asciiInt(self.base[o .. o + L.size_of_field_position]) catch return result;
            if (std.mem.eql(u8, etag, tag) and position + length <= field_area.len) {
                var data = field_area[position .. position + length];
                if (data.len > 0 and data[data.len - 1] == FT) data = data[0 .. data.len - 1];
                result = data; // last match wins
            }
        }
        return result;
    }
};

/// Iterate the records of an ISO 8211 file with no allocation. `next` returns
/// null at the trailing zero-fill padding (clean end of records) or on the first
/// malformed leader.
pub const RecordIterator = struct {
    bytes: []const u8,
    off: usize = 0,

    pub fn next(self: *RecordIterator) ?RecordView {
        if (self.off + 24 > self.bytes.len) return null;
        const rest = self.bytes[self.off..];
        var leader = Leader.parse(rest) catch return null;
        if (leader.leader_id != 'D' and leader.leader_id != 'L') return null; // padding / malformed
        if (leader.field_area_start < 24 or self.off + leader.field_area_start > self.bytes.len) return null;
        if (leader.record_length == 0)
            leader.record_length = leader.field_area_start + directoryExtent(rest, leader);
        if (leader.record_length < 24 or self.off + leader.record_length > self.bytes.len) return null;
        const base = rest[0..leader.record_length];
        self.off += leader.record_length;
        return .{ .base = base, .leader = leader };
    }
};

/// Start an allocation-free record iteration over an ISO 8211 file's bytes.
pub fn iterate(bytes: []const u8) RecordIterator {
    return .{ .bytes = bytes };
}

/// Validate + view one record, allocation-free — the raw-bytes twin of
/// `parseRecord`, with its exact error surface: the same leader checks, the
/// EndOfRecords padding sentinel, a terminated directory with numeric entries
/// (`parseDirectory`), the length==0 recovery, and every entry's field-area
/// bounds (`parseFields` checks position+length per entry; the max entry end
/// covers them all). One added guard: a stored record_length shorter than the
/// directory is rejected here (the eager path would trip a bounds panic).
fn validateRecord(bytes: []const u8, offset: usize) !struct { view: RecordView, next: usize } {
    var leader = try Leader.parse(bytes[offset..]);
    // record_length 0 on a non-'D'/'L' leader is trailing padding => end of records.
    if (leader.record_length == 0 and leader.leader_id != 'D' and leader.leader_id != 'L') return error.EndOfRecords;
    if (leader.leader_id != 'D' and leader.leader_id != 'L') return error.BadLeader;
    if (leader.field_area_start < 24 or offset + leader.field_area_start > bytes.len) return error.BadRecordLength;
    const dir = bytes[offset .. offset + leader.field_area_start];
    const entry_len = @as(usize, leader.size_of_field_tag) + leader.size_of_field_length + leader.size_of_field_position;
    const dir_end = leader.field_area_start;
    if (dir_end <= 24 or dir[dir_end - 1] != FT) return error.MissingFieldTerminator;
    var extent: usize = 0;
    var pos: usize = 24;
    while (pos + entry_len <= dir_end) : (pos += entry_len) {
        if (dir[pos] == FT) break; // directory terminator
        var o = pos + leader.size_of_field_tag;
        const length = try asciiInt(dir[o .. o + leader.size_of_field_length]);
        o += leader.size_of_field_length;
        const position = try asciiInt(dir[o .. o + leader.size_of_field_position]);
        if (position + length > extent) extent = position + length;
    }
    if (leader.record_length == 0) leader.record_length = leader.field_area_start + extent;
    if (leader.record_length < leader.field_area_start or offset + leader.record_length > bytes.len) return error.BadRecordLength;
    if (extent > leader.record_length - leader.field_area_start) return error.FieldOutOfBounds;
    return .{ .view = .{ .base = bytes[offset..][0..leader.record_length], .leader = leader }, .next = offset + leader.record_length };
}

/// Strict record walk: the same allocation-free `RecordView`s as `iterate`, but
/// with the EAGER `parse` error surface — `next` returns null only at a clean
/// end of records (the padding sentinel, or fewer than 24 bytes left), and
/// errors on any input `parse` would reject, so an eager call site can go lazy
/// without changing which files are accepted. Callers replicate `parse`'s DDR
/// check themselves (first record must exist and be leader id 'L' => NotADDR),
/// or use `validate` for the whole file at once.
pub const StrictIterator = struct {
    bytes: []const u8,
    off: usize = 0,

    pub fn next(self: *StrictIterator) !?RecordView {
        // `parse` reads offset 0 unconditionally (a short or padding-only file
        // errors there, not a clean end); after that, <24 remaining bytes or
        // the padding sentinel end the walk.
        if (self.off != 0 and self.off + 24 > self.bytes.len) return null;
        const r = validateRecord(self.bytes, self.off) catch |e| {
            if (e == error.EndOfRecords and self.off != 0) return null;
            return e;
        };
        self.off = r.next;
        return r.view;
    }
};

/// Start a strict (eager-error-surface) allocation-free record iteration.
pub fn iterateStrict(bytes: []const u8) StrictIterator {
    return .{ .bytes = bytes };
}

/// Accept or reject a whole file by the eager parser's rules — the same leader,
/// directory, and field-extent checks as `parse`, including first-record-is-DDR
/// — without allocating. A file that validates iterates cleanly through
/// `StrictIterator` (and `iterate`), so a caller can pre-validate once and then
/// decode with the tolerant walk.
pub fn validate(bytes: []const u8) !void {
    var it = iterateStrict(bytes);
    const first = (try it.next()) orelse return error.NotADDR;
    if (first.leader.leader_id != 'L') return error.NotADDR;
    while (try it.next()) |_| {}
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

test "lazy iterate/RecordView.field matches the eager parse (allocation-free)" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try writeRecord(a, &buf, 'L', &.{.{ .tag = "0000", .data = "0000;&   " }});
    try writeRecord(a, &buf, 'D', &.{ .{ .tag = "FOO1", .data = "AAA" }, .{ .tag = "BAR2", .data = "HELLO" } });
    try writeRecord(a, &buf, 'D', &.{.{ .tag = "BAR2", .data = "WORLD" }});

    // Lazy view: no allocator; walk records and fields straight out of the bytes.
    var it = iterate(buf.items);
    const ddr = it.next().?;
    try std.testing.expectEqual(@as(u8, 'L'), ddr.leader.leader_id);
    const dr0 = it.next().?;
    try std.testing.expectEqual(@as(u8, 'D'), dr0.leader.leader_id);
    try std.testing.expectEqualStrings("AAA", dr0.field("FOO1").?);
    try std.testing.expectEqualStrings("HELLO", dr0.field("BAR2").?);
    try std.testing.expect(dr0.field("NOPE") == null);
    const dr1 = it.next().?;
    try std.testing.expectEqualStrings("WORLD", dr1.field("BAR2").?);
    try std.testing.expect(it.next() == null); // clean end of records

    // Same fields as the eager path, field-for-field.
    var file = try parse(a, buf.items);
    defer file.deinit();
    try std.testing.expectEqualStrings(file.records[0].field("BAR2").?, dr0.field("BAR2").?);
    try std.testing.expectEqualStrings(file.records[1].field("BAR2").?, dr1.field("BAR2").?);
}

test "strict iterate matches the eager parse's accept/reject behaviour" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try writeRecord(a, &buf, 'L', &.{.{ .tag = "0000", .data = "0000;&   " }});
    try writeRecord(a, &buf, 'D', &.{ .{ .tag = "FOO1", .data = "AAA" }, .{ .tag = "BAR2", .data = "HELLO" } });
    try writeRecord(a, &buf, 'D', &.{.{ .tag = "BAR2", .data = "WORLD" }});

    // Clean file: same records + fields as the tolerant walk, plus firstTag.
    try validate(buf.items);
    var it = iterateStrict(buf.items);
    const ddr = (try it.next()).?;
    try std.testing.expectEqual(@as(u8, 'L'), ddr.leader.leader_id);
    const dr0 = (try it.next()).?;
    try std.testing.expectEqualStrings("FOO1", dr0.firstTag().?);
    try std.testing.expectEqualStrings("HELLO", dr0.field("BAR2").?);
    const dr1 = (try it.next()).?;
    try std.testing.expectEqualStrings("BAR2", dr1.firstTag().?);
    try std.testing.expect((try it.next()) == null); // clean end of records

    // A corrupted directory entry (non-numeric length) mid-file: the eager parse
    // rejects the whole file; the strict walk must error on that record too.
    var bad = try a.dupe(u8, buf.items);
    defer a.free(bad);
    const last_off = @intFromPtr(dr1.base.ptr) - @intFromPtr(buf.items.ptr);
    bad[last_off + 24 + 4] = 'X'; // clobber its first directory entry's length
    try std.testing.expectError(error.BadAsciiInt, parse(a, bad));
    try std.testing.expectError(error.BadAsciiInt, validate(bad));
    var itb = iterateStrict(bad);
    _ = try itb.next();
    _ = try itb.next();
    try std.testing.expectError(error.BadAsciiInt, itb.next());

    // Padding-only / non-DDR-first input: validate mirrors parse's errors.
    try std.testing.expectError(error.EndOfRecords, validate("00000" ++ "     " ++ "00" ++ "00024" ++ "   " ++ "11 1"));
    try std.testing.expectError(error.NotADDR, validate(buf.items[ddr.base.len..])); // starts at a 'D' record
}
