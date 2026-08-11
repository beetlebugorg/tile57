//! Charts read STRAIGHT OUT of a .zip, one entry at a time.
//!
//! A chart archive is big: NOAA's All_ENCs.zip is 788 MB of deflate holding
//! 2.0 GiB across 27,680 entries — 7,224 cells, their 4,414 updates, and
//! 15,539 .TXT the pick report resolves by name. Unzipping it first costs the
//! mariner 2.0 GiB of disk that is dead the moment the bake ends, on top of
//! the baked charts they actually keep. So nothing here unzips: the central
//! directory is walked once (2 ms for those 27,680 entries), and each file is
//! inflated on its own, when it is needed, into a buffer its own size.
//!
//! Two properties make that work, and both are load-bearing:
//!
//!   * Entries are randomly addressable — seek to the local header, inflate.
//!     A read does not disturb any other read, so `readAlloc` opens its own
//!     handle and the parallel bake keeps every core busy pulling different
//!     cells out of one archive. There is no shared cursor to lock.
//!   * Inflating is bounded — a 32 KiB window plus the read buffer, whatever
//!     the entry's size. `extractTo` therefore streams a 4 GiB .mbtiles to
//!     disk in constant memory, and needs no space for a second copy.
//!
//! Nothing here decides WHAT a chart is. The archive reports its names and
//! reads whichever ones it is asked for; the host classifies. What it does
//! know is the exchange set's SHAPE, because that is structure rather than
//! policy: a cell's .001.. updates belong to that cell (`updatesFor`), and
//! the files sitting in a cell's own directory are the ones it references
//! (`siblingsOf`) — the .TXT a TXTDSC names, the picture a PICREP names.

const std = @import("std");
const zip = std.zip;
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadLocalHeader,
    UnsupportedCompressionMethod,
    EntryTooLarge,
};

pub const Entry = struct {
    /// The name as stored, e.g. "ENC_ROOT/US5MD12M/US5MD12M.000". Arena-owned.
    name: []const u8,
    uncompressed_size: u64,
    compressed_size: u64,
    raw: zip.Iterator.Entry,
};

/// A zip opened for reading charts. Read-only once opened, so any number of
/// threads may `readAlloc`/`extractTo` from one `Archive` at the same time.
pub const Archive = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    /// Our own copy of the archive's path: each read opens the file again
    /// rather than sharing a cursor.
    path: []const u8,
    entries: []Entry,
    by_name: std.StringHashMapUnmanaged(usize),
    /// Directory prefix (no trailing '/') -> the entries directly in it. Built
    /// once, because the alternative is rescanning 27,680 names per cell.
    by_dir: std.StringHashMapUnmanaged([]usize),

    /// Walk the central directory. Directory entries (trailing '/') are left
    /// out — they are never charts. Encrypted and multi-disk archives are
    /// rejected here, by `zip.Iterator`, rather than at the first read.
    pub fn open(gpa: Allocator, io: std.Io, path: []const u8) !Archive {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        var rbuf: [64 * 1024]u8 = undefined;
        var fr = f.reader(io, &rbuf);

        var it = try zip.Iterator.init(&fr);
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(gpa);
        try entries.ensureTotalCapacity(gpa, @intCast(@min(it.cd_record_count, 1 << 20)));

        var name_buf: [4096]u8 = undefined;
        while (try it.next()) |e| {
            if (e.filename_len == 0 or e.filename_len > name_buf.len) continue;
            const name = name_buf[0..e.filename_len];
            try fr.seekTo(e.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
            try fr.interface.readSliceAll(name);
            if (name[name.len - 1] == '/') continue; // a directory, not a chart
            try entries.append(gpa, .{
                .name = try a.dupe(u8, name),
                .uncompressed_size = e.uncompressed_size,
                .compressed_size = e.compressed_size,
                .raw = e,
            });
        }

        const owned = try entries.toOwnedSlice(gpa);
        errdefer gpa.free(owned);
        var by_name: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer by_name.deinit(gpa);
        try by_name.ensureTotalCapacity(gpa, @intCast(owned.len));
        for (owned, 0..) |e, i| by_name.putAssumeCapacity(e.name, i);

        // Group by directory in one pass, into the arena, so `siblingsOf` is a
        // lookup rather than a scan.
        var grow: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
        defer {
            var it2 = grow.valueIterator();
            while (it2.next()) |v| v.deinit(gpa);
            grow.deinit(gpa);
        }
        for (owned, 0..) |e, i| {
            const d = dirNameOf(e.name);
            const slot = try grow.getOrPut(gpa, d);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(gpa, i);
        }
        var by_dir: std.StringHashMapUnmanaged([]usize) = .empty;
        errdefer by_dir.deinit(gpa);
        try by_dir.ensureTotalCapacity(gpa, grow.count());
        var git = grow.iterator();
        while (git.next()) |kv| {
            by_dir.putAssumeCapacity(kv.key_ptr.*, try a.dupe(usize, kv.value_ptr.items));
        }

        // Every arena allocation must happen BEFORE the literal below copies
        // the arena: the copy freezes the buffer list, so anything allocated
        // while building the literal lands in a node the copy cannot free.
        const path_copy = try a.dupe(u8, path);
        return .{
            .gpa = gpa,
            .arena = arena,
            .path = path_copy,
            .entries = owned,
            .by_name = by_name,
            .by_dir = by_dir,
        };
    }

    pub fn deinit(self: *Archive) void {
        self.by_name.deinit(self.gpa);
        self.by_dir.deinit(self.gpa);
        self.gpa.free(self.entries);
        self.arena.deinit();
    }

    pub fn find(self: *const Archive, name: []const u8) ?usize {
        return self.by_name.get(name);
    }

    /// Inflate entry `i` into a fresh buffer (caller frees). `max` bounds what
    /// the archive is allowed to claim an entry expands to — an ENC cell is a
    /// few MiB, so a header promising gigabytes is a reason to stop, not to
    /// allocate. Opens its own file handle: safe to call from many threads.
    pub fn readAlloc(self: *const Archive, gpa: Allocator, io: std.Io, i: usize, max: u64) ![]u8 {
        const e = self.entries[i];
        if (e.uncompressed_size > max) return Error.EntryTooLarge;
        const buf = try gpa.alloc(u8, @intCast(e.uncompressed_size));
        errdefer gpa.free(buf);

        var w: std.Io.Writer = .fixed(buf);
        try self.streamEntry(io, i, &w);
        if (w.end != buf.len) return error.EndOfStream;
        return buf;
    }

    /// Inflate entry `i` straight to `out_path`, in constant memory however
    /// large it is — the one way a 4 GiB .mbtiles lands on disk without a
    /// second copy of it existing anywhere. `out_path` is the CALLER's name
    /// for the file, never the archive's, so a hostile entry name cannot
    /// choose where this writes.
    pub fn extractTo(self: *const Archive, io: std.Io, i: usize, out_path: []const u8) !void {
        const out = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
        defer out.close(io);
        var wbuf: [256 * 1024]u8 = undefined;
        var fw = out.writer(io, &wbuf);
        try self.streamEntry(io, i, &fw.interface);
        try fw.interface.flush();
    }

    /// The `.001..` update chain belonging to the `.000` cell at `i`, in order,
    /// stopping at the first gap — the same rule the on-disk reader applies to
    /// a cell's directory, applied to the archive's names instead. Empty when
    /// `i` is not a base cell. Caller frees.
    pub fn updatesFor(self: *const Archive, gpa: Allocator, i: usize) ![]usize {
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(gpa);
        const name = self.entries[i].name;
        if (name.len < 4 or !std.mem.eql(u8, name[name.len - 4 ..], ".000")) {
            return out.toOwnedSlice(gpa);
        }
        const stem = name[0 .. name.len - 4];
        var buf: [4096]u8 = undefined;
        var u: u32 = 1;
        while (u <= 999) : (u += 1) {
            const up = std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ stem, u }) catch break;
            const idx = self.find(up) orelse break;
            try out.append(gpa, idx);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every entry in the same directory as `i`, `i` included. The exchange
    /// set puts a cell's referenced text and pictures in the cell's own
    /// directory, so this is the candidate list an aux-file pass filters —
    /// the archive does not decide which of them are content, which is why it
    /// does not drop the cell either. Borrowed; valid until deinit.
    pub fn siblingsOf(self: *const Archive, i: usize) []const usize {
        return self.by_dir.get(dirNameOf(self.entries[i].name)) orelse &.{};
    }

    /// Every entry as JSON: [{"name":..,"size":..,"packed":..}, ..]. The host
    /// classifies from this; the archive takes no view on which are charts.
    /// NUL-terminated so it can cross the C ABI as a plain string.
    pub fn toJson(self: *const Archive, gpa: Allocator) ![:0]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.append(gpa, '[');
        for (self.entries, 0..) |e, i| {
            if (i != 0) try buf.append(gpa, ',');
            try buf.appendSlice(gpa, "{\"name\":");
            try appendJsonString(gpa, &buf, e.name);
            try buf.print(gpa, ",\"size\":{d},\"packed\":{d}}}", .{ e.uncompressed_size, e.compressed_size });
        }
        try buf.append(gpa, ']');
        return buf.toOwnedSliceSentinel(gpa, 0);
    }

    /// Where entry `i`'s compressed bytes start: past its LOCAL header, whose
    /// name and extra fields may be sized differently from the central
    /// directory's copy.
    fn dataOffset(e: zip.Iterator.Entry, fr: *std.Io.File.Reader) !u64 {
        try fr.seekTo(e.file_offset);
        const lh = try fr.interface.takeStruct(zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &lh.signature, &zip.local_file_header_sig)) return Error.BadLocalHeader;
        return e.file_offset + @sizeOf(zip.LocalFileHeader) + lh.filename_len + lh.extra_len;
    }

    /// Inflate one entry into `w`. Bounded: a 32 KiB window and the read
    /// buffer, whatever the entry weighs.
    fn streamEntry(self: *const Archive, io: std.Io, i: usize, w: *std.Io.Writer) !void {
        const e = self.entries[i].raw;
        const f = try std.Io.Dir.cwd().openFile(io, self.path, .{});
        defer f.close(io);
        var rbuf: [64 * 1024]u8 = undefined;
        var fr = f.reader(io, &rbuf);
        try fr.seekTo(try dataOffset(e, &fr));
        switch (e.compression_method) {
            .store => try fr.interface.streamExact64(w, e.uncompressed_size),
            .deflate => {
                var window: [flate.max_window_len]u8 = undefined;
                var d: flate.Decompress = .init(&fr.interface, .raw, &window);
                try d.reader.streamExact64(w, e.uncompressed_size);
            },
            else => return Error.UnsupportedCompressionMethod,
        }
    }
};

/// The directory part of a zip entry name ("" at the top level). Zip names are
/// always '/'-separated, whatever the platform, so this is not path logic.
fn dirNameOf(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return "";
    return name[0..slash];
}

fn appendJsonString(gpa: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try buf.appendSlice(gpa, "\\\""),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '\n' => try buf.appendSlice(gpa, "\\n"),
        '\r' => try buf.appendSlice(gpa, "\\r"),
        '\t' => try buf.appendSlice(gpa, "\\t"),
        else => if (ch < 0x20) {
            try buf.print(gpa, "\\u{x:0>4}", .{ch});
        } else try buf.append(gpa, ch),
    };
    try buf.append(gpa, '"');
}

// ---------------------------------------------------------------------------
// Tests. The fixtures are real zips, written here rather than committed: the
// reader's whole job is tolerating what a writer actually produces (a local
// header sized differently from the central one, a stored entry beside a
// deflated one), and a committed blob would freeze one writer's habits.
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestFile = struct { name: []const u8, data: []const u8, deflate: bool };

/// Write a minimal but valid zip: local header + data per file, then the
/// central directory, then the end record.
fn writeTestZip(gpa: Allocator, io: std.Io, path: []const u8, files: []const TestFile) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var offsets = try gpa.alloc(u32, files.len);
    defer gpa.free(offsets);
    var packed_lens = try gpa.alloc(u32, files.len);
    defer gpa.free(packed_lens);
    var crcs = try gpa.alloc(u32, files.len);
    defer gpa.free(crcs);

    for (files, 0..) |f, i| {
        offsets[i] = @intCast(out.items.len);
        crcs[i] = std.hash.Crc32.hash(f.data);

        var body: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer body.deinit();
        if (f.deflate) {
            var window: [flate.max_window_len]u8 = undefined;
            var c = try flate.Compress.init(&body.writer, &window, .raw, .default);
            try c.writer.writeAll(f.data);
            try c.finish();
        } else {
            try body.writer.writeAll(f.data);
        }
        const body_bytes = body.written();
        packed_lens[i] = @intCast(body_bytes.len);

        const lh: zip.LocalFileHeader = .{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = if (f.deflate) .deflate else .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = crcs[i],
            .compressed_size = packed_lens[i],
            .uncompressed_size = @intCast(f.data.len),
            .filename_len = @intCast(f.name.len),
            .extra_len = 0,
        };
        try out.appendSlice(gpa, std.mem.asBytes(&lh));
        try out.appendSlice(gpa, f.name);
        try out.appendSlice(gpa, body_bytes);
    }

    const cd_start: u32 = @intCast(out.items.len);
    for (files, 0..) |f, i| {
        const ch: zip.CentralDirectoryFileHeader = .{
            .signature = zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = if (f.deflate) .deflate else .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = crcs[i],
            .compressed_size = packed_lens[i],
            .uncompressed_size = @intCast(f.data.len),
            .filename_len = @intCast(f.name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = offsets[i],
        };
        try out.appendSlice(gpa, std.mem.asBytes(&ch));
        try out.appendSlice(gpa, f.name);
    }
    const cd_size: u32 = @intCast(out.items.len - cd_start);

    const end: zip.EndRecord = .{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(files.len),
        .record_count_total = @intCast(files.len),
        .central_directory_size = cd_size,
        .central_directory_offset = cd_start,
        .comment_len = 0,
    };
    try out.appendSlice(gpa, std.mem.asBytes(&end));

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// tmpDir lives under the build root's .zig-cache; the reader takes paths
/// through cwd(), so the tests need its path rather than its handle.
fn tmpPath(gpa: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "reads a stored and a deflated entry byte for byte" {
    const gpa = testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const zpath = try std.fs.path.join(gpa, &.{ dir, "t.zip" });
    defer gpa.free(zpath);

    // Long and repetitive, so deflate actually has something to do.
    const big = "US5MD12M soundings " ** 400;
    try writeTestZip(gpa, io, zpath, &.{
        .{ .name = "ENC_ROOT/", .data = "", .deflate = false },
        .{ .name = "ENC_ROOT/A/A.000", .data = "stored cell bytes", .deflate = false },
        .{ .name = "ENC_ROOT/B/B.000", .data = big, .deflate = true },
    });

    var arc = try Archive.open(gpa, io, zpath);
    defer arc.deinit();

    // The directory entry is not a chart and is not listed.
    try testing.expectEqual(@as(usize, 2), arc.entries.len);
    try testing.expectEqualStrings("ENC_ROOT/A/A.000", arc.entries[0].name);

    const a = try arc.readAlloc(gpa, io, 0, 1 << 20);
    defer gpa.free(a);
    try testing.expectEqualStrings("stored cell bytes", a);

    const b = try arc.readAlloc(gpa, io, arc.find("ENC_ROOT/B/B.000").?, 1 << 20);
    defer gpa.free(b);
    try testing.expectEqualStrings(big, b);
    // Deflate really was exercised, not silently stored.
    try testing.expect(arc.entries[1].compressed_size < arc.entries[1].uncompressed_size);
}

test "an entry that claims more than the cap is refused before allocating" {
    const gpa = testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const zpath = try std.fs.path.join(gpa, &.{ dir, "t.zip" });
    defer gpa.free(zpath);

    try writeTestZip(gpa, io, zpath, &.{
        .{ .name = "big.000", .data = "0123456789", .deflate = false },
    });
    var arc = try Archive.open(gpa, io, zpath);
    defer arc.deinit();
    try testing.expectError(Error.EntryTooLarge, arc.readAlloc(gpa, io, 0, 4));
}

test "the update chain follows the cell and stops at the first gap" {
    const gpa = testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const zpath = try std.fs.path.join(gpa, &.{ dir, "t.zip" });
    defer gpa.free(zpath);

    // .003 is missing, so .004 is not part of the chain even though it is in
    // the archive. A cell in another directory with the same stem must not be
    // mistaken for an update of this one.
    try writeTestZip(gpa, io, zpath, &.{
        .{ .name = "ENC_ROOT/US5MD12M/US5MD12M.000", .data = "base", .deflate = false },
        .{ .name = "ENC_ROOT/US5MD12M/US5MD12M.001", .data = "u1", .deflate = false },
        .{ .name = "ENC_ROOT/US5MD12M/US5MD12M.002", .data = "u2", .deflate = false },
        .{ .name = "ENC_ROOT/US5MD12M/US5MD12M.004", .data = "u4", .deflate = false },
        .{ .name = "OTHER/US5MD12M/US5MD12M.003", .data = "elsewhere", .deflate = false },
        .{ .name = "ENC_ROOT/US5MD12M/US5MD12M.TXT", .data = "notes", .deflate = false },
    });

    var arc = try Archive.open(gpa, io, zpath);
    defer arc.deinit();

    const base = arc.find("ENC_ROOT/US5MD12M/US5MD12M.000").?;
    const ups = try arc.updatesFor(gpa, base);
    defer gpa.free(ups);
    try testing.expectEqual(@as(usize, 2), ups.len);
    try testing.expectEqualStrings("ENC_ROOT/US5MD12M/US5MD12M.001", arc.entries[ups[0]].name);
    try testing.expectEqualStrings("ENC_ROOT/US5MD12M/US5MD12M.002", arc.entries[ups[1]].name);

    // A .TXT is not a base cell, so it has no chain.
    const txt = arc.find("ENC_ROOT/US5MD12M/US5MD12M.TXT").?;
    const none = try arc.updatesFor(gpa, txt);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "a cell's directory names the files it references" {
    const gpa = testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const zpath = try std.fs.path.join(gpa, &.{ dir, "t.zip" });
    defer gpa.free(zpath);

    try writeTestZip(gpa, io, zpath, &.{
        .{ .name = "ENC_ROOT/US5MD12M/US5MD12M.000", .data = "base", .deflate = false },
        .{ .name = "ENC_ROOT/US5MD12M/US348MDE.TXT", .data = "caution", .deflate = false },
        .{ .name = "ENC_ROOT/US5MD12M/PIC1.TIF", .data = "pic", .deflate = false },
        .{ .name = "ENC_ROOT/US4MD11M/US4MD11M.000", .data = "other", .deflate = false },
        .{ .name = "ENC_ROOT/US4MD11M/OTHER.TXT", .data = "not mine", .deflate = false },
        .{ .name = "CATALOG.031", .data = "catalogue", .deflate = false },
    });

    var arc = try Archive.open(gpa, io, zpath);
    defer arc.deinit();

    // The cell's own directory, and nothing from the cell next door.
    const base = arc.find("ENC_ROOT/US5MD12M/US5MD12M.000").?;
    const sibs = arc.siblingsOf(base);
    try testing.expectEqual(@as(usize, 3), sibs.len);
    for (sibs) |si| {
        try testing.expect(std.mem.startsWith(u8, arc.entries[si].name, "ENC_ROOT/US5MD12M/"));
    }

    // An entry at the top level has no directory to share.
    const cat = arc.find("CATALOG.031").?;
    try testing.expectEqual(@as(usize, 1), arc.siblingsOf(cat).len);
}

test "extractTo writes the entry under the caller's name" {
    const gpa = testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const zpath = try std.fs.path.join(gpa, &.{ dir, "t.zip" });
    defer gpa.free(zpath);

    const body = "tiles and more tiles " ** 500;
    try writeTestZip(gpa, io, zpath, &.{
        .{ .name = "../evil/USA.mbtiles", .data = body, .deflate = true },
    });
    var arc = try Archive.open(gpa, io, zpath);
    defer arc.deinit();

    // The archive's own name is ignored: the destination is ours.
    const out = try std.fs.path.join(gpa, &.{ dir, "safe.mbtiles" });
    defer gpa.free(out);
    try arc.extractTo(io, 0, out);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, out, gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(body, got);
}

test "the listing is JSON and NUL-terminated" {
    const gpa = testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const zpath = try std.fs.path.join(gpa, &.{ dir, "t.zip" });
    defer gpa.free(zpath);

    try writeTestZip(gpa, io, zpath, &.{
        .{ .name = "a\"quote\".000", .data = "xy", .deflate = false },
    });
    var arc = try Archive.open(gpa, io, zpath);
    defer arc.deinit();

    const json = try arc.toJson(gpa);
    defer gpa.free(json);
    // The host reads this as a C string; without the terminator it reads on.
    try testing.expectEqual(@as(u8, 0), json[json.len]);
    try testing.expectEqualStrings("[{\"name\":\"a\\\"quote\\\".000\",\"size\":2,\"packed\":2}]", json);
}

test "a file that is not a zip is refused at open" {
    const gpa = testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const zpath = try std.fs.path.join(gpa, &.{ dir, "not.zip" });
    defer gpa.free(zpath);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = zpath, .data = "0001 this is an S-57 cell, not an archive" });
    try testing.expectError(error.ZipNoEndRecord, Archive.open(gpa, io, zpath));
}
