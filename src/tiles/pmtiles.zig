//! PMTiles v3 reader + writer.
//! Spec: https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
//!
//! The writer produces a clustered single-root-directory archive (sufficient
//! for region-sized bakes); the reader parses root + leaf directories so it can
//! read archives produced by the Go reference (which may use leaf dirs).
//! Tiles are gzip-compressed MVT (tile_type=1, tile_compression=gzip); the
//! directories/metadata are stored uncompressed (internal_compression=none),
//! matching the Go output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gzip = @import("gzip.zig");

pub const HEADER_LEN = 127;
const MAGIC = "PMTiles";

pub const Compression = enum(u8) { unknown = 0, none = 1, gzip = 2, brotli = 3, zstd = 4 };
pub const TileType = enum(u8) { unknown = 0, mvt = 1, png = 2, jpeg = 3, webp = 4, avif = 5, mlt = 6 };

pub const Header = struct {
    root_dir_offset: u64 = 0,
    root_dir_length: u64 = 0,
    metadata_offset: u64 = 0,
    metadata_length: u64 = 0,
    leaf_dir_offset: u64 = 0,
    leaf_dir_length: u64 = 0,
    tile_data_offset: u64 = 0,
    tile_data_length: u64 = 0,
    num_addressed_tiles: u64 = 0,
    num_tile_entries: u64 = 0,
    num_tile_contents: u64 = 0,
    clustered: u8 = 1,
    internal_compression: Compression = .none,
    tile_compression: Compression = .gzip,
    tile_type: TileType = .mvt,
    min_zoom: u8 = 0,
    max_zoom: u8 = 0,
    min_lon_e7: i32 = 0,
    min_lat_e7: i32 = 0,
    max_lon_e7: i32 = 0,
    max_lat_e7: i32 = 0,
    center_zoom: u8 = 0,
    center_lon_e7: i32 = 0,
    center_lat_e7: i32 = 0,

    pub fn parse(buf: []const u8) !Header {
        if (buf.len < HEADER_LEN) return error.ShortHeader;
        if (!std.mem.eql(u8, buf[0..7], MAGIC)) return error.BadMagic;
        if (buf[7] != 3) return error.UnsupportedVersion;
        const rd = struct {
            fn u64le(b: []const u8, o: usize) u64 {
                return std.mem.readInt(u64, b[o..][0..8], .little);
            }
            fn i32le(b: []const u8, o: usize) i32 {
                return std.mem.readInt(i32, b[o..][0..4], .little);
            }
        };
        return .{
            .root_dir_offset = rd.u64le(buf, 8),
            .root_dir_length = rd.u64le(buf, 16),
            .metadata_offset = rd.u64le(buf, 24),
            .metadata_length = rd.u64le(buf, 32),
            .leaf_dir_offset = rd.u64le(buf, 40),
            .leaf_dir_length = rd.u64le(buf, 48),
            .tile_data_offset = rd.u64le(buf, 56),
            .tile_data_length = rd.u64le(buf, 64),
            .num_addressed_tiles = rd.u64le(buf, 72),
            .num_tile_entries = rd.u64le(buf, 80),
            .num_tile_contents = rd.u64le(buf, 88),
            .clustered = buf[96],
            .internal_compression = @enumFromInt(buf[97]),
            .tile_compression = @enumFromInt(buf[98]),
            .tile_type = @enumFromInt(buf[99]),
            .min_zoom = buf[100],
            .max_zoom = buf[101],
            .min_lon_e7 = rd.i32le(buf, 102),
            .min_lat_e7 = rd.i32le(buf, 106),
            .max_lon_e7 = rd.i32le(buf, 110),
            .max_lat_e7 = rd.i32le(buf, 114),
            .center_zoom = buf[118],
            .center_lon_e7 = rd.i32le(buf, 119),
            .center_lat_e7 = rd.i32le(buf, 123),
        };
    }

    pub fn serialize(h: Header, buf: *[HEADER_LEN]u8) void {
        @memset(buf, 0);
        @memcpy(buf[0..7], MAGIC);
        buf[7] = 3;
        const wr = struct {
            fn u64le(b: []u8, o: usize, v: u64) void {
                std.mem.writeInt(u64, b[o..][0..8], v, .little);
            }
            fn i32le(b: []u8, o: usize, v: i32) void {
                std.mem.writeInt(i32, b[o..][0..4], v, .little);
            }
        };
        wr.u64le(buf, 8, h.root_dir_offset);
        wr.u64le(buf, 16, h.root_dir_length);
        wr.u64le(buf, 24, h.metadata_offset);
        wr.u64le(buf, 32, h.metadata_length);
        wr.u64le(buf, 40, h.leaf_dir_offset);
        wr.u64le(buf, 48, h.leaf_dir_length);
        wr.u64le(buf, 56, h.tile_data_offset);
        wr.u64le(buf, 64, h.tile_data_length);
        wr.u64le(buf, 72, h.num_addressed_tiles);
        wr.u64le(buf, 80, h.num_tile_entries);
        wr.u64le(buf, 88, h.num_tile_contents);
        buf[96] = h.clustered;
        buf[97] = @intFromEnum(h.internal_compression);
        buf[98] = @intFromEnum(h.tile_compression);
        buf[99] = @intFromEnum(h.tile_type);
        buf[100] = h.min_zoom;
        buf[101] = h.max_zoom;
        wr.i32le(buf, 102, h.min_lon_e7);
        wr.i32le(buf, 106, h.min_lat_e7);
        wr.i32le(buf, 110, h.max_lon_e7);
        wr.i32le(buf, 114, h.max_lat_e7);
        buf[118] = h.center_zoom;
        wr.i32le(buf, 119, h.center_lon_e7);
        wr.i32le(buf, 123, h.center_lat_e7);
    }
};

// ---- hilbert tile id ----------------------------------------------------

/// (z,x,y) -> 64-bit hilbert tile id (PMTiles addressing).
pub fn zxyToTileId(z: u8, x_in: u32, y_in: u32) u64 {
    var acc: u64 = 0;
    var t: u6 = 0;
    while (t < z) : (t += 1) {
        acc += (@as(u64, 1) << t) * (@as(u64, 1) << t);
    }
    var x: u64 = x_in;
    var y: u64 = y_in;
    var d: u64 = 0;
    var s: u64 = @as(u64, 1) << @intCast(z);
    s /= 2;
    while (s > 0) : (s /= 2) {
        const rx: u64 = if ((x & s) > 0) 1 else 0;
        const ry: u64 = if ((y & s) > 0) 1 else 0;
        d += s * s * ((3 * rx) ^ ry);
        // rotate (wrapping subtraction matches the PMTiles Go reference, which
        // relies on uint64 wraparound when rx==1 and x >= s).
        if (ry == 0) {
            if (rx == 1) {
                x = s -% 1 -% x;
                y = s -% 1 -% y;
            }
            const tmp = x;
            x = y;
            y = tmp;
        }
    }
    return acc + d;
}

// ---- varint -------------------------------------------------------------

fn writeVarint(list: *std.ArrayList(u8), a: Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try list.append(a, @intCast((v & 0x7F) | 0x80));
    try list.append(a, @intCast(v));
}

const VarReader = struct {
    buf: []const u8,
    pos: usize = 0,
    fn read(r: *VarReader) u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = r.buf[r.pos];
            r.pos += 1;
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }
};

// ---- directory ----------------------------------------------------------

pub const Entry = struct {
    tile_id: u64,
    offset: u64,
    length: u32,
    run_length: u32,
};

pub fn serializeDir(a: Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try writeVarint(&out, a, entries.len);
    var last: u64 = 0;
    for (entries) |e| {
        try writeVarint(&out, a, e.tile_id - last);
        last = e.tile_id;
    }
    for (entries) |e| try writeVarint(&out, a, e.run_length);
    for (entries) |e| try writeVarint(&out, a, e.length);
    for (entries, 0..) |e, i| {
        if (i > 0 and e.offset == entries[i - 1].offset + entries[i - 1].length) {
            try writeVarint(&out, a, 0);
        } else {
            try writeVarint(&out, a, e.offset + 1);
        }
    }
    return out.toOwnedSlice(a);
}

// A reader fetches the root directory from the archive's first ~16 KiB (pmtiles.js
// reads bytes [0, 16384) up front), so the serialized root must share that window
// with the 127-byte header. Larger archives push the bulk of entries into leaf
// directories and keep only one pointer per leaf in the root.
pub const MAX_ROOT_BYTES: usize = 16384 - HEADER_LEN;

pub const Directories = struct { root: []u8, leaves: []u8 };

/// Serialize `entries` (sorted, run-merged) into a root directory + leaf directories,
/// keeping the root within MAX_ROOT_BYTES. When everything fits, `leaves` is empty
/// and the root holds every entry; otherwise the entries are split into fixed-size
/// leaves and the root holds one leaf pointer each (run_length=0, offset relative to
/// the leaf section). Grows the leaf size until the root fits. Caller owns both slices.
pub fn buildDirectories(a: Allocator, entries: []const Entry) !Directories {
    const flat = try serializeDir(a, entries);
    if (entries.len == 0 or flat.len <= MAX_ROOT_BYTES) return .{ .root = flat, .leaves = &.{} };
    a.free(flat);

    var leaf_size: usize = 4096;
    while (true) : (leaf_size *= 2) {
        var leaves = std.ArrayList(u8).empty;
        var roots = std.ArrayList(Entry).empty;
        defer roots.deinit(a);
        var i: usize = 0;
        while (i < entries.len) : (i += leaf_size) {
            const end = @min(i + leaf_size, entries.len);
            const leaf = try serializeDir(a, entries[i..end]);
            defer a.free(leaf);
            try roots.append(a, .{
                .tile_id = entries[i].tile_id,
                .offset = leaves.items.len, // relative to the leaf-directory section
                .length = @intCast(leaf.len),
                .run_length = 0, // 0 => this root entry points at a leaf directory
            });
            try leaves.appendSlice(a, leaf);
        }
        const root = try serializeDir(a, roots.items);
        if (root.len <= MAX_ROOT_BYTES) return .{ .root = root, .leaves = try leaves.toOwnedSlice(a) };
        a.free(root);
        leaves.deinit(a);
    }
}

pub fn deserializeDir(a: Allocator, buf: []const u8) ![]Entry {
    var r = VarReader{ .buf = buf };
    const n: usize = @intCast(r.read());
    const entries = try a.alloc(Entry, n);
    var last: u64 = 0;
    for (entries) |*e| {
        last += r.read();
        e.tile_id = last;
    }
    for (entries) |*e| e.run_length = @intCast(r.read());
    for (entries) |*e| e.length = @intCast(r.read());
    for (entries, 0..) |*e, i| {
        const v = r.read();
        if (v == 0 and i > 0) {
            e.offset = entries[i - 1].offset + entries[i - 1].length;
        } else {
            e.offset = v - 1;
        }
    }
    return entries;
}

// ---- reader -------------------------------------------------------------

pub const Reader = struct {
    bytes: []const u8,
    header: Header,
    root: []Entry,
    arena: std.heap.ArenaAllocator,
    // Deserialized leaf directories by leaf offset. A compositor probes a reader once
    // per (tile, pass); re-deserializing the same leaf into the arena on EVERY probe
    // grew it without bound on directory-heavy archives, so each leaf is decoded once
    // and reused. Arena-backed (freed wholesale by deinit).
    leaves: std.AutoHashMapUnmanaged(u64, []Entry) = .empty,

    pub fn init(gpa: Allocator, bytes: []const u8) !Reader {
        const header = try Header.parse(bytes);
        var arena = std.heap.ArenaAllocator.init(gpa);
        const a = arena.allocator();
        const root_raw = try maybeDecompress(a, bytes[@intCast(header.root_dir_offset)..][0..@intCast(header.root_dir_length)], header.internal_compression);
        const root = try deserializeDir(a, root_raw);
        return .{ .bytes = bytes, .header = header, .root = root, .arena = arena };
    }

    pub fn deinit(r: *Reader) void {
        r.arena.deinit();
    }

    fn maybeDecompress(a: Allocator, data: []const u8, comp: Compression) ![]const u8 {
        return switch (comp) {
            .none => data,
            .gzip => try gzip.decompress(a, data),
            else => error.UnsupportedCompression,
        };
    }

    /// Return the raw (still tile-compressed) bytes for a tile, or null if absent.
    pub fn getCompressed(r: *Reader, z: u8, x: u32, y: u32) !?[]const u8 {
        const tid = zxyToTileId(z, x, y);
        var dir = r.root;
        var depth: u8 = 0;
        while (depth < 4) : (depth += 1) {
            const idx = findEntry(dir, tid) orelse return null;
            const e = dir[idx];
            if (e.run_length == 0) {
                // leaf directory pointer — decoded once per distinct leaf, then cached
                const a = r.arena.allocator();
                const gop = try r.leaves.getOrPut(a, e.offset);
                if (!gop.found_existing) {
                    errdefer _ = r.leaves.remove(e.offset);
                    const raw = try maybeDecompress(a, r.bytes[@intCast(r.header.leaf_dir_offset + e.offset)..][0..e.length], r.header.internal_compression);
                    gop.value_ptr.* = try deserializeDir(a, raw);
                }
                dir = gop.value_ptr.*;
                continue;
            }
            if (tid < e.tile_id + e.run_length) {
                const start: usize = @intCast(r.header.tile_data_offset + e.offset);
                return r.bytes[start .. start + e.length];
            }
            return null;
        }
        return null;
    }

    /// Return the decompressed tile bytes (gunzipped MVT). Caller owns it.
    pub fn getTile(r: *Reader, gpa: Allocator, z: u8, x: u32, y: u32) !?[]u8 {
        const comp = (try r.getCompressed(z, x, y)) orelse return null;
        return switch (r.header.tile_compression) {
            .none => try gpa.dupe(u8, comp),
            .gzip => try gzip.decompress(gpa, comp),
            else => error.UnsupportedCompression,
        };
    }
};

/// Largest entry whose tile_id <= tid (binary search; dir is sorted).
fn findEntry(dir: []const Entry, tid: u64) ?usize {
    var lo: usize = 0;
    var hi: usize = dir.len;
    var result: ?usize = null;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (dir[mid].tile_id <= tid) {
            result = mid;
            lo = mid + 1;
        } else hi = mid;
    }
    return result;
}

// ---- writer -------------------------------------------------------------

// A whole-tile input for the batch `write` below (test-only; the live path is StreamWriter).
const InputTile = struct { z: u8, x: u32, y: u32, mvt: []const u8 };

pub const WriteOptions = struct {
    metadata_json: []const u8 = "{}",
    min_lon_e7: i32 = -1800000000,
    min_lat_e7: i32 = -850000000,
    max_lon_e7: i32 = 1800000000,
    max_lat_e7: i32 = 850000000,
    tile_type: TileType = .mvt, // .mlt for MapLibre Tile output
    center_zoom: ?u8 = null, // header center zoom; defaults to the archive's min zoom
};

/// Streaming archive writer: feed tiles one at a time (each gzipped + content-
/// deduped, the raw MVT is NOT retained), then emit the archive. Lets a baker
/// stream tiles instead of holding them all. The `prefix` (header + directory +
/// metadata) is small; the data section is either kept in a growing buffer
/// (`init`, for callers that want the whole archive as bytes) or streamed
/// straight to a file (`initFile`) so it never lives on the heap at all — the
/// latter keeps a full-catalogue bake's peak memory to the directory + dedup
/// map, not the multi-GB compressed data section. Pure: any file I/O is done via
/// the caller-supplied `std.Io`.
pub const StreamWriter = struct {
    gpa: Allocator,
    data: std.ArrayList(u8) = .empty, // in-memory data section (sink == null)
    sink: ?Sink = null, // else: gzipped tiles streamed straight to this file
    data_len: u64 = 0, // bytes written to the data section so far (== next offset)
    entries: std.ArrayList(Entry) = .empty, // one per addressed tile (pre-sort)
    hash_to_off: std.AutoHashMap(u64, Off),
    num_addressed: u64 = 0,
    num_contents: u64 = 0,
    min_z: u8 = 255,
    max_z: u8 = 0,

    const Off = struct { off: u64, len: u32 };

    // A file the data section is appended to. The writer never reads it back; the
    // caller concatenates `prefix` ++ this file into the final archive and owns
    // the file's lifetime (close/delete).
    const Sink = struct { io: std.Io, file: std.Io.File };

    pub fn init(gpa: Allocator) StreamWriter {
        return .{ .gpa = gpa, .hash_to_off = std.AutoHashMap(u64, Off).init(gpa) };
    }

    /// Like `init`, but the (gzipped, deduped) data section is appended to `file`
    /// as tiles arrive rather than buffered in memory. `file` must be empty and
    /// positioned at 0; the writer appends sequentially via `io`.
    pub fn initFile(gpa: Allocator, io: std.Io, file: std.Io.File) StreamWriter {
        return .{ .gpa = gpa, .hash_to_off = std.AutoHashMap(u64, Off).init(gpa), .sink = .{ .io = io, .file = file } };
    }

    pub fn deinit(self: *StreamWriter) void {
        self.data.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.hash_to_off.deinit();
    }

    /// Gzip one tile's MVT for `addCompressed` — lets a caller compress in parallel
    /// (the expensive step) and keep `addCompressed` (dedup + write) a cheap serial tail.
    pub fn gzipTile(gpa: Allocator, mvt: []const u8) ![]u8 {
        return gzip.compress(gpa, mvt);
    }

    /// Add one tile (gzipped + deduped). Tiles may arrive in any order.
    pub fn add(self: *StreamWriter, z: u8, x: u32, y: u32, mvt: []const u8) !void {
        const comp = try gzip.compress(self.gpa, mvt);
        defer self.gpa.free(comp);
        try self.addCompressed(z, x, y, comp);
    }

    /// Like `add`, but `comp` is already gzipped (e.g. by gzipTile in a worker).
    /// Dedups by content + records the directory entry; the only stateful step, so
    /// this is the serial tail of an otherwise-parallel bake. NOT thread-safe.
    pub fn addCompressed(self: *StreamWriter, z: u8, x: u32, y: u32, comp: []const u8) !void {
        self.min_z = @min(self.min_z, z);
        self.max_z = @max(self.max_z, z);
        const h = std.hash.Wyhash.hash(0, comp);
        const slot = try self.hash_to_off.getOrPut(h);
        var off: u64 = undefined;
        var len: u32 = undefined;
        if (slot.found_existing) {
            off = slot.value_ptr.off;
            len = slot.value_ptr.len;
        } else {
            off = self.data_len;
            len = @intCast(comp.len);
            if (self.sink) |s| try s.file.writeStreamingAll(s.io, comp) else try self.data.appendSlice(self.gpa, comp);
            self.data_len += len;
            slot.value_ptr.* = .{ .off = off, .len = len };
            self.num_contents += 1;
        }
        try self.entries.append(self.gpa, .{ .tile_id = zxyToTileId(z, x, y), .offset = off, .length = len, .run_length = 1 });
        self.num_addressed += 1;
    }

    /// The archive prefix (header + root directory + metadata), allocator-owned.
    /// The full archive is this prefix followed by `data.items` (the data buffer
    /// is written/copied separately, in arrival order — header.clustered=0).
    pub fn prefix(self: *StreamWriter, a: Allocator, opts: WriteOptions) ![]u8 {
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lt(_: void, p: Entry, q: Entry) bool {
                return p.tile_id < q.tile_id;
            }
        }.lt);
        var merged = std.ArrayList(Entry).empty;
        for (self.entries.items) |e| {
            if (merged.items.len > 0) {
                const prev = &merged.items[merged.items.len - 1];
                if (prev.offset == e.offset and prev.tile_id + prev.run_length == e.tile_id) {
                    prev.run_length += 1;
                    continue;
                }
            }
            try merged.append(a, e);
        }
        defer merged.deinit(a);
        const dirs = try buildDirectories(a, merged.items);
        // `dirs` + `merged` are copied into `out` below, so free them once the archive prefix
        // is assembled (they are heap-owned by `a`; `leaves` may be the empty sentinel).
        defer a.free(dirs.root);
        defer if (dirs.leaves.len > 0) a.free(dirs.leaves);
        const metadata = opts.metadata_json;
        const root_off: u64 = HEADER_LEN;
        const meta_off: u64 = root_off + dirs.root.len;
        const leaf_off: u64 = meta_off + metadata.len;
        const data_off: u64 = leaf_off + dirs.leaves.len;
        const min_z: u8 = if (self.num_addressed == 0) 0 else self.min_z;
        const header = Header{
            .root_dir_offset = root_off,
            .root_dir_length = dirs.root.len,
            .metadata_offset = meta_off,
            .metadata_length = metadata.len,
            .leaf_dir_offset = leaf_off,
            .leaf_dir_length = dirs.leaves.len,
            .tile_data_offset = data_off,
            .tile_data_length = self.data_len,
            .num_addressed_tiles = self.num_addressed,
            .num_tile_entries = merged.items.len,
            .num_tile_contents = self.num_contents,
            .clustered = 0, // data in arrival order, not tile-id order
            .internal_compression = .none,
            .tile_compression = .gzip,
            .tile_type = opts.tile_type,
            .min_zoom = min_z,
            .max_zoom = self.max_z,
            .min_lon_e7 = opts.min_lon_e7,
            .min_lat_e7 = opts.min_lat_e7,
            .max_lon_e7 = opts.max_lon_e7,
            .max_lat_e7 = opts.max_lat_e7,
            .center_zoom = opts.center_zoom orelse min_z,
            .center_lon_e7 = @divTrunc(opts.min_lon_e7 + opts.max_lon_e7, 2),
            .center_lat_e7 = @divTrunc(opts.min_lat_e7 + opts.max_lat_e7, 2),
        };
        var hbuf: [HEADER_LEN]u8 = undefined;
        header.serialize(&hbuf);
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, &hbuf);
        try out.appendSlice(a, dirs.root);
        try out.appendSlice(a, metadata);
        try out.appendSlice(a, dirs.leaves);
        return out.toOwnedSlice(a);
    }

    /// The whole archive as one buffer (prefix ++ data). For consumers that need
    /// bytes (the C ABI); requires the in-memory data section (`init`, not
    /// `initFile`). The streaming CLI concatenates prefix + the data file instead.
    pub fn finishBytes(self: *StreamWriter, opts: WriteOptions) ![]u8 {
        std.debug.assert(self.sink == null); // a file-backed writer has no in-memory data
        if (self.num_addressed == 0) return self.gpa.alloc(u8, 0);
        const pre = try self.prefix(self.gpa, opts);
        defer self.gpa.free(pre);
        const out = try self.gpa.alloc(u8, pre.len + self.data.items.len);
        @memcpy(out[0..pre.len], pre);
        @memcpy(out[pre.len..], self.data.items);
        return out;
    }
};

// Build a PMTiles archive from a whole set of MVT tiles in one call (gzipped +
// deduped). The live baker streams via StreamWriter instead; this stays as a
// self-contained round-trip fixture for the reader tests below.
fn write(gpa: Allocator, tiles: []const InputTile, opts: WriteOptions) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Sort by hilbert tile id.
    const Item = struct { tid: u64, mvt: []const u8 };
    var items = try a.alloc(Item, tiles.len);
    for (tiles, 0..) |t, i| items[i] = .{ .tid = zxyToTileId(t.z, t.x, t.y), .mvt = t.mvt };
    std.mem.sort(Item, items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return x.tid < y.tid;
        }
    }.lt);

    // Dedup by gzipped content; concatenate unique blobs into the data section.
    var data = std.ArrayList(u8).empty;
    var hash_to_off = std.AutoHashMap(u64, struct { off: u64, len: u32 }).init(a);
    var entries = std.ArrayList(Entry).empty;
    var min_z: u8 = 255;
    var max_z: u8 = 0;
    var num_contents: u64 = 0;

    for (items) |it| {
        min_z = @min(min_z, zoomOf(it.tid));
        const z = zoomOf(it.tid);
        _ = z;
        const comp = try gzip.compress(a, it.mvt);
        const h = std.hash.Wyhash.hash(0, comp);
        const slot = try hash_to_off.getOrPut(h);
        var off: u64 = undefined;
        var len: u32 = undefined;
        if (slot.found_existing) {
            off = slot.value_ptr.off;
            len = slot.value_ptr.len;
        } else {
            off = data.items.len;
            len = @intCast(comp.len);
            try data.appendSlice(a, comp);
            slot.value_ptr.* = .{ .off = off, .len = len };
            num_contents += 1;
        }
        // RLE merge with previous entry if contiguous and same content.
        if (entries.items.len > 0) {
            const prev = &entries.items[entries.items.len - 1];
            if (prev.offset == off and prev.tile_id + prev.run_length == it.tid) {
                prev.run_length += 1;
                continue;
            }
        }
        try entries.append(a, .{ .tile_id = it.tid, .offset = off, .length = len, .run_length = 1 });
    }
    // zoom range from tiles
    for (tiles) |t| {
        min_z = @min(min_z, t.z);
        max_z = @max(max_z, t.z);
    }
    if (tiles.len == 0) min_z = 0;

    const dirs = try buildDirectories(a, entries.items);
    const metadata = opts.metadata_json;

    // Assemble: header | root | metadata | leaf dirs | data.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    var hbuf: [HEADER_LEN]u8 = undefined;

    const root_off: u64 = HEADER_LEN;
    const meta_off: u64 = root_off + dirs.root.len;
    const leaf_off: u64 = meta_off + metadata.len;
    const data_off: u64 = leaf_off + dirs.leaves.len;

    const header = Header{
        .root_dir_offset = root_off,
        .root_dir_length = dirs.root.len,
        .metadata_offset = meta_off,
        .metadata_length = metadata.len,
        .leaf_dir_offset = leaf_off,
        .leaf_dir_length = dirs.leaves.len,
        .tile_data_offset = data_off,
        .tile_data_length = data.items.len,
        .num_addressed_tiles = tiles.len,
        .num_tile_entries = entries.items.len,
        .num_tile_contents = num_contents,
        .clustered = 1,
        .internal_compression = .none,
        .tile_compression = .gzip,
        .tile_type = opts.tile_type,
        .min_zoom = min_z,
        .max_zoom = max_z,
        .min_lon_e7 = opts.min_lon_e7,
        .min_lat_e7 = opts.min_lat_e7,
        .max_lon_e7 = opts.max_lon_e7,
        .max_lat_e7 = opts.max_lat_e7,
        .center_zoom = opts.center_zoom orelse min_z,
        .center_lon_e7 = @divTrunc(opts.min_lon_e7 + opts.max_lon_e7, 2),
        .center_lat_e7 = @divTrunc(opts.min_lat_e7 + opts.max_lat_e7, 2),
    };
    header.serialize(&hbuf);

    try out.appendSlice(gpa, &hbuf);
    try out.appendSlice(gpa, dirs.root);
    try out.appendSlice(gpa, metadata);
    try out.appendSlice(gpa, dirs.leaves);
    try out.appendSlice(gpa, data.items);
    return out.toOwnedSlice(gpa);
}

/// Inverse-ish: recover the zoom of a hilbert tile id (for zoom-range stats).
fn zoomOf(tid: u64) u8 {
    var z: u8 = 0;
    var acc: u64 = 0;
    while (z < 32) : (z += 1) {
        const tiles_at_z = (@as(u64, 1) << @intCast(z)) * (@as(u64, 1) << @intCast(z));
        if (tid < acc + tiles_at_z) return z;
        acc += tiles_at_z;
    }
    return 0;
}

// ---- tests --------------------------------------------------------------

const fixture = @embedFile("mvt_fixture");

test "hilbert tile id matches PMTiles reference values" {
    // From the spec's zxy<->tileid table.
    try std.testing.expectEqual(@as(u64, 0), zxyToTileId(0, 0, 0));
    try std.testing.expectEqual(@as(u64, 1), zxyToTileId(1, 0, 0));
    try std.testing.expectEqual(@as(u64, 2), zxyToTileId(1, 0, 1));
    try std.testing.expectEqual(@as(u64, 3), zxyToTileId(1, 1, 1));
    try std.testing.expectEqual(@as(u64, 4), zxyToTileId(1, 1, 0));
    try std.testing.expectEqual(@as(u64, 5), zxyToTileId(2, 0, 0));
}

test "write then read round-trips a real tile (writer+reader+gzip+mvt)" {
    const gpa = std.testing.allocator;
    const mvt = @import("mvt.zig");

    const tiles = [_]InputTile{.{ .z = 14, .x = 4711, .y = 6262, .mvt = fixture }};
    const archive = try write(gpa, &tiles, .{});
    defer gpa.free(archive);

    var r = try Reader.init(gpa, archive);
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 14), r.header.min_zoom);
    try std.testing.expectEqual(@as(u8, 14), r.header.max_zoom);

    // Present tile round-trips byte-identically after gunzip.
    const got = (try r.getTile(gpa, 14, 4711, 6262)).?;
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, fixture, got);

    // And it decodes to the oracle's structure.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const layers = try mvt.decode(arena.allocator(), got);
    try std.testing.expectEqual(@as(usize, 11), layers.len);

    // Absent tile -> null.
    try std.testing.expect((try r.getTile(gpa, 14, 0, 0)) == null);
}

test "large archive shards the root into leaf directories and still round-trips" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Enough distinct tiles (unique content -> no dedup/run-merge) that the flat
    // directory would blow past MAX_ROOT_BYTES, forcing leaf directories.
    const N: u32 = 20000;
    const tiles = try a.alloc(InputTile, N);
    for (0..N) |i| {
        const payload = try std.fmt.allocPrint(a, "tile-{d}-payload", .{i});
        tiles[i] = .{ .z = 15, .x = @intCast(i), .y = 0, .mvt = payload };
    }
    const archive = try write(gpa, tiles, .{});
    defer gpa.free(archive);

    var r = try Reader.init(gpa, archive);
    defer r.deinit();
    // Root stays within a reader's initial window; the bulk lives in leaf dirs.
    try std.testing.expect(r.header.root_dir_length <= MAX_ROOT_BYTES);
    try std.testing.expect(r.header.leaf_dir_length > 0);

    // Every tile is reachable through the root -> leaf lookup, content intact.
    for ([_]u32{ 0, 1, 4095, 4096, 12345, N / 2, N - 1 }) |i| {
        const got = (try r.getTile(gpa, 15, i, 0)) orelse return error.MissingTile;
        defer gpa.free(got);
        const want = try std.fmt.allocPrint(a, "tile-{d}-payload", .{i});
        try std.testing.expectEqualSlices(u8, want, got);
    }
    // An absent tile in the sharded archive still resolves to null.
    try std.testing.expect((try r.getTile(gpa, 15, 1, 1)) == null);

    // Repeated probes reuse the cached leaf decodes — the arena must not grow once
    // every touched leaf is resident. (A compositor probes a reader once per
    // (tile, pass); re-deserializing a leaf per probe was unbounded growth.)
    const probes = [_]u32{ 0, 4095, 4096, 12345, N - 1 };
    for (probes) |i| _ = try r.getCompressed(15, i, 0);
    const cap_before = r.arena.queryCapacity();
    for (0..100) |_| {
        for (probes) |i| _ = try r.getCompressed(15, i, 0);
        _ = try r.getCompressed(15, 1, 1); // absent probes walk the directory too
    }
    try std.testing.expectEqual(cap_before, r.arena.queryCapacity());
}

test "header serialize/parse round-trip" {
    const h = Header{
        .root_dir_offset = 127,
        .root_dir_length = 50,
        .tile_data_offset = 300,
        .min_zoom = 9,
        .max_zoom = 16,
        .num_addressed_tiles = 765,
        .tile_compression = .gzip,
        .internal_compression = .none,
        .tile_type = .mvt,
    };
    var buf: [HEADER_LEN]u8 = undefined;
    h.serialize(&buf);
    const back = try Header.parse(&buf);
    try std.testing.expectEqual(h.root_dir_offset, back.root_dir_offset);
    try std.testing.expectEqual(h.num_addressed_tiles, back.num_addressed_tiles);
    try std.testing.expectEqual(h.max_zoom, back.max_zoom);
    try std.testing.expectEqual(Compression.gzip, back.tile_compression);
}
