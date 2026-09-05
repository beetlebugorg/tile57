//! Auxiliary files: the external resources an ENC feature points at by name
//! instead of carrying inline. TXTDSC and NTXTDS name a text file; PICREP names
//! a picture. They ship in the exchange set beside the .000 cells, and a baked
//! archive carries only the NAME, so a pick report cannot read them.
//!
//! The bake keeps the ENC_ROOT shape: one directory per chart, holding the
//! archive and the files that chart references.
//!
//!     tiles/US5MD1MC/US5MD1MC.pmtiles
//!     tiles/US5MD1MC/US348MDE.TXT
//!     tiles/US5MD1MC/index.json
//!
//! A chart directory is therefore self-contained: copy it and the report still
//! reads its caution note. The files are loose, so they work offline from any
//! static host, an SD card or a file:// URL, with no archive to unpack.
//!
//! A reference is keyed by the UPPER-CASED BASENAME. S-57 stores the value
//! upper-cased, and exchange sets differ in case across platforms, so a
//! case-sensitive lookup misses on the wrong filesystem.

const std = @import("std");

pub const index_name = "index.json";

/// Ceilings for the two reads that take their size from the chart directory.
/// A TXTDSC note and a PICREP picture are small. The manifest lists one line
/// per referenced file.
const max_index_bytes: usize = 8 << 20;
const max_file_bytes: usize = 64 << 20;
pub const version = 1;

/// The lookup key for a reference: the bare basename, upper-cased.
pub fn key(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const base = std.fs.path.basename(name);
    const out = try alloc.alloc(u8, base.len);
    for (base, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

/// The MIME type a client needs to render the stored file.
pub fn mime(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    var buf: [8]u8 = undefined;
    if (ext.len == 0 or ext.len > buf.len) return "application/octet-stream";
    const lower = std.ascii.lowerString(buf[0..ext.len], ext);
    if (std.mem.eql(u8, lower, ".txt")) return "text/plain";
    if (std.mem.eql(u8, lower, ".png")) return "image/png";
    if (std.mem.eql(u8, lower, ".jpg") or std.mem.eql(u8, lower, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, lower, ".tif") or std.mem.eql(u8, lower, ".tiff")) return "image/tiff";
    return "application/octet-stream";
}

/// True for a file that is aux CONTENT. The catalogue and the readmes are
/// exchange-set plumbing, not feature data.
pub fn isContent(name: []const u8) bool {
    const base = std.fs.path.basename(name);
    var upper: [64]u8 = undefined;
    if (base.len <= upper.len) {
        const u = std.ascii.upperString(upper[0..base.len], base);
        if (std.mem.startsWith(u8, u, "README")) return false;
        if (std.mem.startsWith(u8, u, "CATALOG")) return false;
    }
    const ext = std.fs.path.extension(base);
    var buf: [8]u8 = undefined;
    if (ext.len == 0 or ext.len > buf.len) return false;
    const lower = std.ascii.lowerString(buf[0..ext.len], ext);
    inline for (.{ ".txt", ".tif", ".tiff", ".jpg", ".jpeg", ".png" }) |e| {
        if (std.mem.eql(u8, lower, e)) return true;
    }
    return false;
}

/// One file to write.
pub const File = struct {
    owner: []const u8 = "", // the chart that references it (its ENC_ROOT directory)
    name: []const u8, // the name a feature references it by
    bytes: []const u8,
};

/// Write `files` beside the chart in `dir`, with the manifest. Returns the
/// number written; an empty list writes nothing.
///
/// A picture is stored as it arrives. The Go predecessor transcoded TIFF to PNG
/// for the browser, which cannot decode TIFF; every native client can, so the
/// engine keeps the original bytes and states the type in the manifest.
pub fn writeDir(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, files: []const File) !usize {
    if (files.len == 0) return 0;
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var manifest = std.ArrayList(u8).empty;
    defer manifest.deinit(alloc);
    try manifest.print(alloc, "{{\n  \"version\": {d},\n  \"files\": {{\n", .{version});

    var written: usize = 0;
    for (files) |f| {
        const k = try key(alloc, f.name);
        defer alloc.free(k);
        const stored = std.fs.path.basename(f.name);
        const path = try std.fs.path.join(alloc, &.{ dir, stored });
        defer alloc.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = f.bytes });
        if (written > 0) try manifest.appendSlice(alloc, ",\n");
        try manifest.print(alloc, "    \"{s}\": {{ \"stored\": \"{s}\", \"type\": \"{s}\" }}", .{ k, stored, mime(stored) });
        written += 1;
    }
    try manifest.appendSlice(alloc, "\n  }\n}\n");

    const index_path = try std.fs.path.join(alloc, &.{ dir, index_name });
    defer alloc.free(index_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = manifest.items });
    return written;
}

/// A read handle over an aux directory: the manifest in memory, the files read
/// on demand and cached.
pub const Reader = struct {
    alloc: std.mem.Allocator,
    dir: []u8,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    cache: std.StringHashMapUnmanaged([]u8) = .empty,

    pub const Entry = struct { stored: []u8, mime: []u8 };

    /// Open a chart directory and read its manifest. Returns null when there is
    /// none, which is what a chart with no referenced files leaves behind.
    pub fn open(io: std.Io, alloc: std.mem.Allocator, dir: []const u8) !?Reader {
        const index_path = try std.fs.path.join(alloc, &.{ dir, index_name });
        defer alloc.free(index_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, index_path, alloc, .limited(max_index_bytes)) catch return null;
        defer alloc.free(bytes);

        var self = Reader{ .alloc = alloc, .dir = try alloc.dupe(u8, dir) };
        errdefer self.deinit();

        // `self` owns a copy of `dir` by now, so every return past this point
        // releases it. errdefer covers the error returns only.
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
            self.deinit();
            return null;
        };
        defer parsed.deinit();
        // A chart directory travels with the chart, so the manifest is third
        // party input. Check each tag before reading the union: parseFromSlice
        // rejects malformed JSON, and well-formed JSON of the wrong shape
        // reaches here. The keys are the reference names, so the manifest
        // cannot be a plain struct.
        if (parsed.value != .object) {
            self.deinit();
            return null;
        }
        const files = parsed.value.object.get("files") orelse return self;
        if (files != .object) return self;
        var it = files.object.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .object) continue;
            const stored = kv.value_ptr.object.get("stored") orelse continue;
            const typ = kv.value_ptr.object.get("type") orelse continue;
            if (stored != .string or typ != .string) continue;
            try self.entries.put(alloc, try alloc.dupe(u8, kv.key_ptr.*), .{
                .stored = try alloc.dupe(u8, stored.string),
                .mime = try alloc.dupe(u8, typ.string),
            });
        }
        return self;
    }

    /// The bytes and the type for a reference, or null when the directory has no
    /// such file. The bytes stay valid until deinit.
    pub fn get(self: *Reader, io: std.Io, name: []const u8) !?struct { bytes: []const u8, mime: []const u8 } {
        const k = try key(self.alloc, name);
        defer self.alloc.free(k);
        const entry = self.entries.get(k) orelse return null;
        if (self.cache.get(k)) |bytes| return .{ .bytes = bytes, .mime = entry.mime };

        // `stored` comes from the manifest. writeDir stores every file under
        // its basename, so taking the basename here keeps the read inside the
        // chart directory and still resolves what writeDir wrote.
        const path = try std.fs.path.join(self.alloc, &.{ self.dir, std.fs.path.basename(entry.stored) });
        defer self.alloc.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(max_file_bytes)) catch return null;
        try self.cache.put(self.alloc, try self.alloc.dupe(u8, k), bytes);
        return .{ .bytes = bytes, .mime = entry.mime };
    }

    pub fn deinit(self: *Reader) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            self.alloc.free(kv.value_ptr.stored);
            self.alloc.free(kv.value_ptr.mime);
        }
        self.entries.deinit(self.alloc);
        var ci = self.cache.iterator();
        while (ci.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            self.alloc.free(kv.value_ptr.*);
        }
        self.cache.deinit(self.alloc);
        self.alloc.free(self.dir);
    }
};

test "key upper-cases the basename" {
    const a = std.testing.allocator;
    const k = try key(a, "ENC_ROOT/US5MD1MC/us348mde.txt");
    defer a.free(k);
    try std.testing.expectEqualStrings("US348MDE.TXT", k);
}

test "isContent takes text and pictures, not the catalogue" {
    try std.testing.expect(isContent("US348MDE.TXT"));
    try std.testing.expect(isContent("pic.TIF"));
    try std.testing.expect(isContent("a/b/photo.jpeg"));
    try std.testing.expect(!isContent("CATALOG.031"));
    try std.testing.expect(!isContent("README.TXT"));
    try std.testing.expect(!isContent("US5MD1MC.000"));
}

test "mime states what a client must decode" {
    try std.testing.expectEqualStrings("text/plain", mime("A.TXT"));
    try std.testing.expectEqualStrings("image/tiff", mime("A.tif"));
    try std.testing.expectEqualStrings("image/jpeg", mime("A.JPG"));
    try std.testing.expectEqualStrings("application/octet-stream", mime("A.bin"));
}

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

/// Write `index.json` with the given body into a fresh directory and open it.
fn openWithIndex(alloc: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir, body: []const u8) !struct { dir: []u8, reader: ?Reader } {
    const dir = try tmpPath(alloc, tmp);
    const p = try std.fs.path.join(alloc, &.{ dir, index_name });
    defer alloc.free(p);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = body });
    return .{ .dir = dir, .reader = try Reader.open(io, alloc, dir) };
}

test "a manifest of the wrong shape yields no entries" {
    const a = std.testing.allocator;
    const io = testIo();
    // Each of these parses as JSON and then fails a shape the reader assumed.
    // Reading the union without checking its tag is undefined behaviour in a
    // ReleaseFast build, the shipped default.
    const bodies = [_][]const u8{
        "{\"files\":[1,2,3]}",
        "{\"files\":{\"A.TXT\":{\"stored\":1,\"type\":2}}}",
        "{\"files\":{\"A.TXT\":\"nope\"}}",
        "{\"files\":42}",
        "[1,2,3]",
        "\"a string\"",
    };
    for (bodies) |body| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var got = try openWithIndex(a, io, &tmp, body);
        defer a.free(got.dir);
        if (got.reader) |*r| {
            defer r.deinit();
            try std.testing.expectEqual(@as(usize, 0), r.entries.count());
        }
    }
}

test "a stored name cannot read outside the chart directory" {
    const a = std.testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file one level above the chart directory, named by a traversing
    // `stored`. writeDir only ever stores basenames, so resolving the basename
    // finds what writeDir wrote and misses this.
    const root = try tmpPath(a, &tmp);
    defer a.free(root);
    const secret = try std.fs.path.join(a, &.{ root, "secret.txt" });
    defer a.free(secret);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = secret, .data = "private" });

    const chart_dir = try std.fs.path.join(a, &.{ root, "chart" });
    defer a.free(chart_dir);
    try std.Io.Dir.cwd().createDirPath(io, chart_dir);
    const idx = try std.fs.path.join(a, &.{ chart_dir, index_name });
    defer a.free(idx);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = idx,
        .data = "{\"files\":{\"A.TXT\":{\"stored\":\"../secret.txt\",\"type\":\"text/plain\"}}}",
    });

    var r = (try Reader.open(io, a, chart_dir)).?;
    defer r.deinit();
    try std.testing.expect((try r.get(io, "A.TXT")) == null);

    // The same manifest resolves a file that is actually in the directory.
    const inside = try std.fs.path.join(a, &.{ chart_dir, "secret.txt" });
    defer a.free(inside);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = inside, .data = "chart note" });
    var r2 = (try Reader.open(io, a, chart_dir)).?;
    defer r2.deinit();
    const hit = (try r2.get(io, "A.TXT")).?;
    try std.testing.expectEqualStrings("chart note", hit.bytes);
}
