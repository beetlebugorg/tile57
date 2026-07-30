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
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, index_path, alloc, .unlimited) catch return null;
        defer alloc.free(bytes);

        var self = Reader{ .alloc = alloc, .dir = try alloc.dupe(u8, dir) };
        errdefer self.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
        defer parsed.deinit();
        const files = parsed.value.object.get("files") orelse return self;
        var it = files.object.iterator();
        while (it.next()) |kv| {
            const stored = kv.value_ptr.object.get("stored") orelse continue;
            const typ = kv.value_ptr.object.get("type") orelse continue;
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

        const path = try std.fs.path.join(self.alloc, &.{ self.dir, entry.stored });
        defer self.alloc.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .unlimited) catch return null;
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
