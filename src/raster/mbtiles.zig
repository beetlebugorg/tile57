//! MBTiles — a raster chart read where the mariner left it.
//!
//! WHY THIS EXISTS. Cruisers going somewhere the ENC barely covers carry offline
//! satellite imagery, and they carry it as MBTiles: a SQLite database of picture
//! tiles, produced by whatever tool the person who shared it happened to run.
//! This reads those files in place — no import, no conversion, no second copy of
//! a 500 MB download — which is the posture a baked `.pmtiles` archive already
//! has.
//!
//! WHY SQLITE AND NOT A HAND READER. The query surface is small enough to tempt
//! one: a scan of `metadata`, and point lookups on `tiles` that an index answers.
//! But the corpus is community output from several toolchains, and every shape a
//! hand reader failed to anticipate would be a mariner who cannot open their
//! chart. The dedup schema `mb-util` and `tippecanoe` emit — where `tiles` is a
//! VIEW over `map` and `images` — needs no special case here at all, because a
//! view answers a SELECT like a table. Reading someone else's format is the wrong
//! place to be clever.
//!
//! WHAT THE READER STILL OWNS. SQLite has no opinion about any of this:
//!
//!   - The y axis. MBTiles rows are TMS (origin bottom-left), the engine and
//!     every caller are XYZ (origin top-left). Flip on the way out. Get this
//!     wrong and the chart looks plausible until you compare it to something.
//!   - The file name. Both files measured while specifying this declare
//!     `minzoom=9, maxzoom=17` while their names claim `Z10-Z18`. The name is
//!     never evidence.
//!   - Absent metadata. Zoom range and bounds are recomputed from the tile index
//!     when the file does not state them, which several contributors' files
//!     do not.
//!   - Tile size. Nothing records it, so it is sniffed from a picture. A 512 px
//!     set drawn as 256 is off by a factor of two, everywhere.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---- the vendored SQLite C ABI ------------------------------------------
//
// Declared rather than @cImport'd: sqlite3.h is 662 KB of macro-heavy header for
// the fifteen entry points below, and the C ABI it exports has been stable for
// two decades. See build.zig's addSqlite for the compile flags.

const Db = opaque {};
const Stmt = opaque {};

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READONLY: c_int = 0x00000001;
const SQLITE_NULL: c_int = 5;
// "file is not a database". open_v2 usually does NOT report this: SQLite defers
// reading the header until the first statement, so a file of garbage opens
// happily and fails at the first prepare. That is where this is checked, and it
// is what tells a raster chart apart from a file that is not one at all —
// cheaper and more certain than a magic probe, which would need its own std.Io
// handle threaded down here to read sixteen bytes.
const SQLITE_NOTADB: c_int = 26;

extern fn sqlite3_open_v2(path: [*:0]const u8, db: *?*Db, flags: c_int, vfs: ?[*:0]const u8) callconv(.c) c_int;
extern fn sqlite3_close_v2(db: ?*Db) callconv(.c) c_int;
extern fn sqlite3_errmsg(db: ?*Db) callconv(.c) [*:0]const u8;
extern fn sqlite3_exec(db: ?*Db, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) callconv(.c) c_int;
extern fn sqlite3_prepare_v2(db: ?*Db, sql: [*]const u8, n: c_int, stmt: *?*Stmt, tail: ?*?[*:0]const u8) callconv(.c) c_int;
extern fn sqlite3_finalize(stmt: ?*Stmt) callconv(.c) c_int;
extern fn sqlite3_step(stmt: ?*Stmt) callconv(.c) c_int;
extern fn sqlite3_reset(stmt: ?*Stmt) callconv(.c) c_int;
extern fn sqlite3_bind_int(stmt: ?*Stmt, idx: c_int, v: c_int) callconv(.c) c_int;
extern fn sqlite3_column_blob(stmt: ?*Stmt, col: c_int) callconv(.c) ?*const anyopaque;
extern fn sqlite3_column_bytes(stmt: ?*Stmt, col: c_int) callconv(.c) c_int;
extern fn sqlite3_column_text(stmt: ?*Stmt, col: c_int) callconv(.c) ?[*:0]const u8;
extern fn sqlite3_column_int(stmt: ?*Stmt, col: c_int) callconv(.c) c_int;
extern fn sqlite3_column_type(stmt: ?*Stmt, col: c_int) callconv(.c) c_int;

// ---- public model --------------------------------------------------------

pub const Error = error{
    /// SQLite could not open the file: missing, or unreadable.
    OpenFailed,
    /// The bytes are not a SQLite database at all.
    NotADatabase,
    /// It is a database, but not a tileset: no `tiles` or no `metadata`.
    NotMbtiles,
    /// A tileset with no tiles in it.
    NoTiles,
    /// A VECTOR tileset (format=pbf/mvt). Valid MBTiles, not a raster chart.
    VectorTileset,
    /// A query failed against a file that opened. Corrupt, or truncated mid-copy.
    QueryFailed,
    OutOfMemory,
};

pub const Encoding = enum(u8) {
    unknown = 0,
    png = 1,
    jpeg = 2,
    webp = 3,

    pub fn mime(e: Encoding) [:0]const u8 {
        return switch (e) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .unknown => "application/octet-stream",
        };
    }
};

/// Which corner the file's `tile_row` counts from. MBTiles 1.3 specifies TMS and
/// every measured file declares it; `xyz` appears in the wild from tools that
/// wrote the rows the way the web serves them.
pub const Scheme = enum(u8) { tms = 0, xyz = 1 };

/// What the file says about itself, after the reader has repaired what it omits.
/// `name` and `description` are what the FILE claims — neither is a capture date,
/// and no MBTiles carries one.
pub const Meta = struct {
    min_zoom: u8 = 0,
    max_zoom: u8 = 0,
    encoding: Encoding = .unknown,
    scheme: Scheme = .tms,
    tile_size: u32 = 256,
    west: f64 = -180.0,
    south: f64 = -85.05112878,
    east: f64 = 180.0,
    north: f64 = 85.05112878,
    /// True when the field above came from the file rather than from the tile
    /// index. A host that reports provenance needs to know which it is reading.
    zooms_declared: bool = false,
    bounds_declared: bool = false,
    // NUL-terminated: the C ABI hands these straight to a host as C strings,
    // and a terminator added at the source beats a copy at every call.
    name: [:0]const u8 = "",
    description: [:0]const u8 = "",
    attribution: [:0]const u8 = "",
};

/// A caller-owned buffer for the message SQLite produced on a failed open. No
/// allocation, and no global — two threads may open two charts at once.
pub const ErrMsg = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const ErrMsg) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *ErrMsg, text: []const u8) void {
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }
};

pub const Reader = struct {
    db: *Db,
    /// The point lookup, prepared once and held for the life of the reader. A
    /// pan across a chart asks for tiles by the hundred; re-preparing per tile
    /// would re-plan the same query every time.
    get: *Stmt,
    meta: Meta,
    /// Owns the strings in `meta`.
    arena: std.heap.ArenaAllocator,

    /// Open `path` read-only. `msg` (null to ignore) receives SQLite's own text
    /// when the open fails, which is the only place it says anything a caller
    /// could act on. Close with `close`.
    pub fn open(gpa: Allocator, path: [*:0]const u8, msg: ?*ErrMsg) Error!Reader {
        var db: ?*Db = null;
        // open_v2 hands back a handle even on most failures, and errmsg only
        // speaks through that handle — so close it on the way out, not before.
        const rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, null);
        errdefer _ = sqlite3_close_v2(db);
        if (rc != SQLITE_OK) {
            if (msg) |m| if (db != null) m.set(std.mem.span(sqlite3_errmsg(db)));
            return Error.OpenFailed;
        }
        const handle = db orelse return Error.OpenFailed;

        // Page the database in through the kernel rather than through read(2).
        // This is what keeps a 500 MB chart from becoming resident, and it is
        // worth most on Android, where the file sits on FUSE-backed storage and
        // every avoided syscall is a trip through a userspace daemon. Best
        // effort: a VFS without mmap support declines and reads normally.
        _ = sqlite3_exec(handle, "PRAGMA mmap_size=1073741824", null, null, null);

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        var meta = try readMeta(handle, arena.allocator());
        if (meta.encoding == .unknown and isVectorFormat(handle, arena.allocator()))
            return Error.VectorTileset;

        try repairZooms(handle, &meta);
        if (!meta.bounds_declared) repairBounds(handle, &meta);

        var get: ?*Stmt = null;
        const sql = "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?";
        if (sqlite3_prepare_v2(handle, sql, sql.len, &get, null) != SQLITE_OK)
            return Error.NotMbtiles; // no `tiles` relation at all
        errdefer _ = sqlite3_finalize(get);

        var r: Reader = .{ .db = handle, .get = get.?, .meta = meta, .arena = arena };
        r.meta.tile_size = r.sniffTileSize() orelse 256;
        if (r.meta.encoding == .unknown) r.meta.encoding = r.sniffEncoding();
        return r;
    }

    pub fn close(r: *Reader) void {
        _ = sqlite3_finalize(r.get);
        _ = sqlite3_close_v2(r.db);
        r.arena.deinit();
    }

    /// The encoded picture for (z,x,y) in XYZ addressing, or null when the chart
    /// has no tile there — the ORDINARY case, since these pyramids are clipped to
    /// coastline and run about 38% dense inside their own bounds. Caller owns the
    /// bytes.
    ///
    /// Not internally synchronized: it steps one prepared statement. A host
    /// streaming from a worker serializes its own access, as it does for a chart.
    pub fn tile(r: *Reader, gpa: Allocator, z: u8, x: u32, y: u32) Error!?[]u8 {
        // A view asks for tiles well outside the chart on every frame; answering
        // those without touching SQLite is most of the calls.
        if (z < r.meta.min_zoom or z > r.meta.max_zoom or z > 30) return null;
        const span: u32 = @as(u32, 1) << @intCast(z);
        if (x >= span or y >= span) return null;
        const row: u32 = switch (r.meta.scheme) {
            .tms => span - 1 - y,
            .xyz => y,
        };

        defer _ = sqlite3_reset(r.get);
        _ = sqlite3_bind_int(r.get, 1, @intCast(z));
        _ = sqlite3_bind_int(r.get, 2, @intCast(x));
        _ = sqlite3_bind_int(r.get, 3, @intCast(row));

        return switch (sqlite3_step(r.get)) {
            SQLITE_ROW => blk: {
                const n = sqlite3_column_bytes(r.get, 0);
                if (n <= 0) break :blk null;
                const p = sqlite3_column_blob(r.get, 0) orelse break :blk null;
                const src: [*]const u8 = @ptrCast(p);
                break :blk try gpa.dupe(u8, src[0..@intCast(n)]);
            },
            SQLITE_DONE => null,
            else => Error.QueryFailed,
        };
    }

    /// How many tiles the chart holds. A DIAGNOSTIC: this scans an index, so it
    /// is for `tile57 raster info` and not for anything a view calls.
    pub fn tileCount(r: *Reader) Error!u64 {
        var st: ?*Stmt = null;
        const sql = "SELECT count(*) FROM tiles";
        if (sqlite3_prepare_v2(r.db, sql, sql.len, &st, null) != SQLITE_OK) return Error.QueryFailed;
        defer _ = sqlite3_finalize(st);
        if (sqlite3_step(st) != SQLITE_ROW) return Error.QueryFailed;
        const n = sqlite3_column_int(st, 0);
        return if (n < 0) 0 else @intCast(n);
    }

    /// One tile's dimensions, read from its own picture header. Null when the
    /// chart is empty or the encoding carries no size we can read.
    fn sniffTileSize(r: *Reader) ?u32 {
        var st: ?*Stmt = null;
        const sql = "SELECT tile_data FROM tiles LIMIT 1";
        if (sqlite3_prepare_v2(r.db, sql, sql.len, &st, null) != SQLITE_OK) return null;
        defer _ = sqlite3_finalize(st);
        if (sqlite3_step(st) != SQLITE_ROW) return null;
        const n = sqlite3_column_bytes(st, 0);
        if (n <= 0) return null;
        const p = sqlite3_column_blob(st, 0) orelse return null;
        const src: [*]const u8 = @ptrCast(p);
        const dims = pictureSize(src[0..@intCast(n)]) orelse return null;
        return dims.w;
    }

    fn sniffEncoding(r: *Reader) Encoding {
        var st: ?*Stmt = null;
        const sql = "SELECT tile_data FROM tiles LIMIT 1";
        if (sqlite3_prepare_v2(r.db, sql, sql.len, &st, null) != SQLITE_OK) return .unknown;
        defer _ = sqlite3_finalize(st);
        if (sqlite3_step(st) != SQLITE_ROW) return .unknown;
        const n = sqlite3_column_bytes(st, 0);
        if (n <= 0) return .unknown;
        const p = sqlite3_column_blob(st, 0) orelse return .unknown;
        const src: [*]const u8 = @ptrCast(p);
        return pictureEncoding(src[0..@intCast(n)]);
    }
};

// ---- metadata ------------------------------------------------------------

fn readMeta(db: *Db, a: Allocator) Error!Meta {
    var m: Meta = .{};
    var st: ?*Stmt = null;
    const sql = "SELECT name, value FROM metadata";
    // The first statement is where SQLite finally reads the header, so this is
    // where "not a database" separates from "a database that is not a tileset".
    switch (sqlite3_prepare_v2(db, sql, sql.len, &st, null)) {
        SQLITE_OK => {},
        SQLITE_NOTADB => return Error.NotADatabase,
        else => return Error.NotMbtiles,
    }
    defer _ = sqlite3_finalize(st);

    while (sqlite3_step(st) == SQLITE_ROW) {
        const key_z = sqlite3_column_text(st, 0) orelse continue;
        const val_z = sqlite3_column_text(st, 1) orelse continue;
        const key = std.mem.span(key_z);
        const val = std.mem.span(val_z);

        if (eqIgnoreCase(key, "name")) {
            m.name = try a.dupeZ(u8, val);
        } else if (eqIgnoreCase(key, "description")) {
            m.description = try a.dupeZ(u8, val);
        } else if (eqIgnoreCase(key, "attribution")) {
            m.attribution = try a.dupeZ(u8, val);
        } else if (eqIgnoreCase(key, "format")) {
            m.encoding = encodingOf(val);
        } else if (eqIgnoreCase(key, "scheme")) {
            m.scheme = if (eqIgnoreCase(val, "xyz")) .xyz else .tms;
        } else if (eqIgnoreCase(key, "minzoom")) {
            if (parseZoom(val)) |z| {
                m.min_zoom = z;
                m.zooms_declared = true;
            }
        } else if (eqIgnoreCase(key, "maxzoom")) {
            if (parseZoom(val)) |z| {
                m.max_zoom = z;
                m.zooms_declared = true;
            }
        } else if (eqIgnoreCase(key, "bounds")) {
            if (parseBounds(val)) |b| {
                m.west, m.south, m.east, m.north = b;
                m.bounds_declared = true;
            }
        }
    }
    return m;
}

/// A vector tileset is valid MBTiles and is not a raster chart. Detected only
/// when `format` says so — sniffing gzipped protobuf against a picture is not
/// worth the ambiguity, and an unreadable encoding fails later anyway.
fn isVectorFormat(db: *Db, a: Allocator) bool {
    _ = a;
    var st: ?*Stmt = null;
    const sql = "SELECT value FROM metadata WHERE lower(name)='format'";
    if (sqlite3_prepare_v2(db, sql, sql.len, &st, null) != SQLITE_OK) return false;
    defer _ = sqlite3_finalize(st);
    if (sqlite3_step(st) != SQLITE_ROW) return false;
    const v = sqlite3_column_text(st, 0) orelse return false;
    const s = std.mem.span(v);
    return eqIgnoreCase(s, "pbf") or eqIgnoreCase(s, "mvt") or eqIgnoreCase(s, "mlt");
}

/// Fill in a zoom range the file did not state, and correct one it stated
/// wrongly. Several contributors' files omit both keys; SAS.Planet writes them
/// but its *file names* disagree, so the index is the only authority. Indexed
/// aggregate — this is two B-tree probes, not a scan.
fn repairZooms(db: *Db, m: *Meta) Error!void {
    var st: ?*Stmt = null;
    const sql = "SELECT min(zoom_level), max(zoom_level) FROM tiles";
    if (sqlite3_prepare_v2(db, sql, sql.len, &st, null) != SQLITE_OK) return Error.NotMbtiles;
    defer _ = sqlite3_finalize(st);
    if (sqlite3_step(st) != SQLITE_ROW) return Error.NoTiles;
    if (sqlite3_column_type(st, 0) == SQLITE_NULL) return Error.NoTiles;

    const lo: u8 = @intCast(@max(0, @min(30, sqlite3_column_int(st, 0))));
    const hi: u8 = @intCast(@max(0, @min(30, sqlite3_column_int(st, 1))));
    if (!m.zooms_declared or m.min_zoom < lo or m.max_zoom > hi or m.min_zoom > m.max_zoom) {
        m.min_zoom = lo;
        m.max_zoom = hi;
        m.zooms_declared = false;
    }
}

/// Derive coverage from the tile index when the file states none. Best effort:
/// a failure leaves the world bounds, which cost a host nothing but a coverage
/// outline drawn too generously.
fn repairBounds(db: *Db, m: *Meta) void {
    var st: ?*Stmt = null;
    const sql =
        "SELECT min(tile_column), max(tile_column), min(tile_row), max(tile_row) " ++
        "FROM tiles WHERE zoom_level=?";
    if (sqlite3_prepare_v2(db, sql, sql.len, &st, null) != SQLITE_OK) return;
    defer _ = sqlite3_finalize(st);
    _ = sqlite3_bind_int(st, 1, @intCast(m.max_zoom));
    if (sqlite3_step(st) != SQLITE_ROW) return;
    if (sqlite3_column_type(st, 0) == SQLITE_NULL) return;

    const z = m.max_zoom;
    const span: i64 = @as(i64, 1) << @intCast(z);
    const x0: i64 = sqlite3_column_int(st, 0);
    const x1: i64 = sqlite3_column_int(st, 1);
    var r0: i64 = sqlite3_column_int(st, 2);
    var r1: i64 = sqlite3_column_int(st, 3);
    if (m.scheme == .tms) {
        // TMS counts up from the south; XYZ counts down from the north.
        const t0 = span - 1 - r1;
        const t1 = span - 1 - r0;
        r0 = t0;
        r1 = t1;
    }
    m.west = tileToLon(x0, z);
    m.east = tileToLon(x1 + 1, z);
    m.north = tileToLat(r0, z);
    m.south = tileToLat(r1 + 1, z);
}

fn tileToLon(x: i64, z: u8) f64 {
    const n: f64 = @floatFromInt(@as(i64, 1) << @intCast(z));
    return @as(f64, @floatFromInt(x)) / n * 360.0 - 180.0;
}

fn tileToLat(y: i64, z: u8) f64 {
    const n: f64 = @floatFromInt(@as(i64, 1) << @intCast(z));
    const t = std.math.pi * (1.0 - 2.0 * @as(f64, @floatFromInt(y)) / n);
    return std.math.radiansToDegrees(std.math.atan(std.math.sinh(t)));
}

// ---- small parsers -------------------------------------------------------

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn encodingOf(s: []const u8) Encoding {
    if (eqIgnoreCase(s, "jpg") or eqIgnoreCase(s, "jpeg")) return .jpeg;
    if (eqIgnoreCase(s, "png")) return .png;
    if (eqIgnoreCase(s, "webp")) return .webp;
    return .unknown;
}

fn parseZoom(s: []const u8) ?u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const v = std.fmt.parseInt(i32, t, 10) catch return null;
    if (v < 0 or v > 30) return null;
    return @intCast(v);
}

fn parseBounds(s: []const u8) ?struct { f64, f64, f64, f64 } {
    var out: [4]f64 = undefined;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (i == 4) return null;
        const t = std.mem.trim(u8, part, " \t\r\n");
        out[i] = std.fmt.parseFloat(f64, t) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    if (out[0] > out[2] or out[1] > out[3]) return null;
    return .{ out[0], out[1], out[2], out[3] };
}

fn pictureEncoding(b: []const u8) Encoding {
    if (b.len >= 8 and std.mem.eql(u8, b[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' })) return .png;
    if (b.len >= 3 and b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF) return .jpeg;
    if (b.len >= 12 and std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WEBP")) return .webp;
    return .unknown;
}

/// Width and height from a picture's own header. PNG states them in IHDR; JPEG
/// states them in whichever start-of-frame marker it uses, so the markers have
/// to be walked. Nothing else is decoded.
fn pictureSize(b: []const u8) ?struct { w: u32, h: u32 } {
    switch (pictureEncoding(b)) {
        .png => {
            if (b.len < 24) return null;
            return .{
                .w = std.mem.readInt(u32, b[16..20], .big),
                .h = std.mem.readInt(u32, b[20..24], .big),
            };
        },
        .jpeg => {
            var i: usize = 2;
            while (i + 9 < b.len) {
                if (b[i] != 0xFF) {
                    i += 1;
                    continue;
                }
                const marker = b[i + 1];
                // SOF0-3, SOF5-7, SOF9-11, SOF13-15 carry the frame size; C4, C8
                // and CC are Huffman/arithmetic/extension tables that do not.
                const is_sof = (marker >= 0xC0 and marker <= 0xCF) and
                    marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
                if (is_sof) {
                    return .{
                        .h = std.mem.readInt(u16, b[i + 5 ..][0..2], .big),
                        .w = std.mem.readInt(u16, b[i + 7 ..][0..2], .big),
                    };
                }
                if (marker == 0xD8 or (marker >= 0xD0 and marker <= 0xD9)) {
                    i += 2;
                    continue;
                }
                const seg = std.mem.readInt(u16, b[i + 2 ..][0..2], .big);
                if (seg < 2) return null;
                i += 2 + seg;
            }
            return null;
        },
        else => return null,
    }
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "bounds parse" {
    const b = parseBounds("13.35937500,45.08903556,14.06250000,46.07323063").?;
    try testing.expectApproxEqAbs(@as(f64, 13.359375), b[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 46.07323063), b[3], 1e-9);
    try testing.expect(parseBounds("1,2,3") == null);
    try testing.expect(parseBounds("1,2,3,4,5") == null);
    try testing.expect(parseBounds("10,0,-10,5") == null); // west east of east
}

test "zoom parse rejects nonsense" {
    try testing.expectEqual(@as(?u8, 17), parseZoom(" 17 "));
    try testing.expect(parseZoom("") == null);
    try testing.expect(parseZoom("99") == null);
    try testing.expect(parseZoom("-1") == null);
}

test "format string to encoding" {
    try testing.expectEqual(Encoding.jpeg, encodingOf("jpg"));
    try testing.expectEqual(Encoding.jpeg, encodingOf("JPEG"));
    try testing.expectEqual(Encoding.png, encodingOf("png"));
    try testing.expectEqual(Encoding.unknown, encodingOf("pbf"));
}

test "picture size from a synthetic PNG header" {
    var buf: [24]u8 = undefined;
    @memcpy(buf[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, buf[8..12], 13, .big);
    @memcpy(buf[12..16], "IHDR");
    std.mem.writeInt(u32, buf[16..20], 512, .big);
    std.mem.writeInt(u32, buf[20..24], 512, .big);
    const d = pictureSize(&buf).?;
    try testing.expectEqual(@as(u32, 512), d.w);
    try testing.expectEqual(@as(u32, 512), d.h);
}

test "picture size from a synthetic JPEG SOF0" {
    // SOI, an APP0 segment to skip, then SOF0 stating 256x256.
    const b = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0, length 4
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x01, 0x00, 0x03, // SOF0 256x256
        0x00, 0x00, 0x00, 0x00,
    };
    const d = pictureSize(&b).?;
    try testing.expectEqual(@as(u32, 256), d.w);
    try testing.expectEqual(@as(u32, 256), d.h);
}

// The real-file tests. Community MBTiles are hundreds of megabytes and cannot
// live in the repo, so the path comes from the environment: point
// TILE57_MBTILES at one and `zig build test` exercises it.
test "open a real chart and read a tile" {
    const a = testing.allocator;
    const path = std.c.getenv("TILE57_MBTILES") orelse return error.SkipZigTest;

    var msg: ErrMsg = .{};
    var r = Reader.open(a, path, &msg) catch |e| {
        std.debug.print("open failed: {s}: {s}\n", .{ @errorName(e), msg.slice() });
        return e;
    };
    defer r.close();

    try testing.expect(r.meta.max_zoom >= r.meta.min_zoom);
    try testing.expect(r.meta.tile_size == 256 or r.meta.tile_size == 512);
    try testing.expect(r.meta.encoding != .unknown);

    // The centre of the declared coverage, at the deepest zoom, must hold a
    // tile in a chart clipped to a coastline — and must round-trip the y flip.
    const z = r.meta.max_zoom;
    const span: f64 = @floatFromInt(@as(u32, 1) << @intCast(z));
    const lon = (r.meta.west + r.meta.east) / 2.0;
    const lat = (r.meta.south + r.meta.north) / 2.0;
    const x: u32 = @intFromFloat(@floor((lon + 180.0) / 360.0 * span));
    const rad = std.math.degreesToRadians(lat);
    const yf = (1.0 - std.math.log(f64, std.math.e, std.math.tan(rad) + 1.0 / std.math.cos(rad)) / std.math.pi) / 2.0 * span;
    const y: u32 = @intFromFloat(@floor(yf));

    if (try r.tile(a, z, x, y)) |bytes| {
        defer a.free(bytes);
        try testing.expect(bytes.len > 0);
        try testing.expectEqual(r.meta.encoding, pictureEncoding(bytes));
    }

    // Out of range on every axis answers null rather than erroring.
    try testing.expect((try r.tile(a, z, span_u32(z), 0)) == null);
    try testing.expect((try r.tile(a, 31, 0, 0)) == null);
    if (r.meta.min_zoom > 0)
        try testing.expect((try r.tile(a, r.meta.min_zoom - 1, 0, 0)) == null);
}

fn span_u32(z: u8) u32 {
    return @as(u32, 1) << @intCast(z);
}
