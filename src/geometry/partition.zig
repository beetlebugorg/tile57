//! The per-band ownership partition — a stack of planar maps, one per distinct
//! band floor, each assigning every point to the cell that renders it at that
//! band. Built from a set of `plane.Cell` via `plane.ownedAtTierIndexed`: a finer
//! cell's face is its coverage minus the finer coverage, and two abutting same-band
//! cells split at their shared border by the DSID tie-break (so the internal border
//! dissolves). This is the artifact the compositor queries to clip each cell's tiles
//! to the ground it owns, and the debug view renders directly.
//!
//! A cell appears in the map of its native band with its full coverage, and in
//! coarser bands only where no coarser cell covers (a gap-filler); it is absent
//! from finer bands. So a "gap" in one band's map is not a bug — the ground is
//! owned by a coarser band, reached by querying that band's map. Pure geometry: no
//! S-57, no streaming, no allocator policy beyond a passed-in `gpa`.

const std = @import("std");
const plane = @import("plane.zig");
const boolean = @import("boolean.zig");

/// Whether (date da, name na) orders strictly before (db, nb) in the equal-scale
/// clip order: newer DSID issue/update date first (YYYYMMDD compares lexically; a
/// dated cell orders before an undated one), then cell name ascending — total and
/// deterministic for distinct cells, so bake output is byte-stable. The baker and
/// this partition use the same tie-break so they pick the same ownership winner.
pub fn ordersBeforeKeys(da: []const u8, na: []const u8, db: []const u8, nb: []const u8) bool {
    if (!std.mem.eql(u8, da, db)) return std.mem.lessThan(u8, db, da); // newer first
    return std.mem.lessThan(u8, na, nb);
}

pub const BandMap = struct {
    /// The band floor (lowest zoom) this map is computed at.
    tier: u8,
    /// One face per cell owning ground at this band; `face.index` indexes
    /// `Partition.cells`. `gpa`-owned.
    faces: []plane.OwnedCell,
    /// `n_cells`-long: global cell index → its slot in `faces`, or -1 if the cell
    /// owns nothing at this band. Lets the compositor fetch a cell's face in O(1).
    pos: []i32,
    /// Parallel to `faces`: each face's lon/lat bbox `{min_lon, min_lat, max_lon,
    /// max_lat}`, computed ONCE here. The compositor culls candidate faces by this
    /// box on every tile of every build, and deriving it walks every point of every
    /// ring — at 35 tiles per build against every face of every coarser map that
    /// re-walk was 3% of all native time on device. The rings never change, so it
    /// is a property of the map, not of the tile being served.
    bbox: [][4]f64,
};

/// `{min_lon, min_lat, max_lon, max_lat}` over every point of every ring.
fn faceLonLatBBox(face: plane.OwnedCell) [4]f64 {
    var b = [4]f64{ 1e9, 1e9, -1e9, -1e9 };
    for (face.owned) |ring| for (ring) |p| {
        const lon = @as(f64, @floatFromInt(p.x)) / 1e7;
        const lat = @as(f64, @floatFromInt(p.y)) / 1e7;
        b[0] = @min(b[0], lon);
        b[1] = @min(b[1], lat);
        b[2] = @max(b[2], lon);
        b[3] = @max(b[3], lat);
    };
    return b;
}

pub const Partition = struct {
    gpa: std.mem.Allocator,
    /// Borrowed — the caller keeps the cells (and their coverage) alive.
    cells: []const plane.Cell,
    /// Distinct band floors, DESCENDING: `maps[0]` is the finest band (highest
    /// floor), `maps[len-1]` the coarsest.
    tiers: []u8,
    maps: []BandMap,

    pub fn deinit(self: *Partition) void {
        for (self.maps) |m| {
            plane.freeOwned(self.gpa, m.faces);
            self.gpa.free(m.pos);
            self.gpa.free(m.bbox);
        }
        self.gpa.free(self.maps);
        self.gpa.free(self.tiers);
    }

    /// The map that governs zoom `z`: the finest band whose floor is ≤ z (i.e. the
    /// largest tier ≤ z). A zoom below every floor resolves to the coarsest map, so
    /// zooming out never falls off the bottom. null only if the partition is empty.
    pub fn mapForZoom(self: *const Partition, z: u8) ?*const BandMap {
        for (self.maps) |*m| {
            if (m.tier <= z) return m; // tiers descending → first hit is finest applicable
        }
        if (self.maps.len > 0) return &self.maps[self.maps.len - 1];
        return null;
    }

    /// The cell index that owns (x,y) at zoom `z`, or null — a true gap in this
    /// band's map (the ground is owned by a coarser band). Coordinates are integers
    /// (degrees × 10⁷). On-border results are even-odd-ambiguous; sample off edges.
    pub fn ownerAt(self: *const Partition, z: u8, x: i64, y: i64) ?usize {
        const m = self.mapForZoom(z) orelse return null;
        for (m.faces) |f| {
            if (boolean.pointInEvenOdd(f.owned, x, y)) return f.index;
        }
        return null;
    }

    /// Cell `ci`'s owned face at the band governing zoom `z` — the rings (integer
    /// lon/lat, degrees × 10⁷) of the ground it renders there, or null if it owns
    /// nothing at that band. This is the region the compositor clips cell `ci`'s
    /// features to before merging.
    pub fn ownedFace(self: *const Partition, ci: usize, z: u8) ?[]const []const plane.Pt {
        const m = self.mapForZoom(z) orelse return null;
        if (ci >= m.pos.len) return null;
        const slot = m.pos[ci];
        if (slot < 0) return null;
        return m.faces[@intCast(slot)].owned;
    }
};

/// Build the per-band ownership stack over `cells` (borrowed). One indexed partition
/// per distinct band floor. All face geometry is freshly allocated in `gpa`; free
/// with `Partition.deinit`.
pub fn build(gpa: std.mem.Allocator, cells: []const plane.Cell) !Partition {
    return buildWith(gpa, cells, null);
}

fn buildWith(gpa: std.mem.Allocator, cells: []const plane.Cell, adopt: ?*plane.AdoptCtx) !Partition {
    // Distinct band floors.
    var seen = std.AutoHashMap(u8, void).init(gpa);
    defer seen.deinit();
    for (cells) |c| try seen.put(c.band_floor, {});

    const tiers = try gpa.alloc(u8, seen.count());
    errdefer gpa.free(tiers);
    {
        var it = seen.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) tiers[i] = k.*;
    }
    std.mem.sort(u8, tiers, {}, comptime std.sort.desc(u8)); // finest (highest floor) first

    const maps = try gpa.alloc(BandMap, tiers.len);
    errdefer gpa.free(maps);

    // One coverage index for every tier: coverage is tier-invariant, and it is
    // also what makes a face a pure function of its subtrahend index list —
    // the invariant ownedTiers' cross-tier reuse rides on.
    var cov_idx = try plane.buildCoverageIndex(gpa, cells);
    defer cov_idx.deinit(gpa);

    const tier_faces = try plane.ownedTiersAdopt(gpa, cells, tiers, &cov_idx, adopt);
    defer gpa.free(tier_faces);
    var built: usize = 0;
    errdefer {
        for (maps[0..built]) |m| {
            plane.freeOwned(gpa, m.faces);
            gpa.free(m.pos);
            gpa.free(m.bbox);
        }
        for (tier_faces[built..]) |faces| plane.freeOwned(gpa, faces);
    }
    for (tiers, 0..) |t, i| {
        const pos = try gpa.alloc(i32, cells.len);
        @memset(pos, -1);
        for (tier_faces[i], 0..) |f, slot| pos[f.index] = @intCast(slot);
        const bbox = try gpa.alloc([4]f64, tier_faces[i].len);
        for (tier_faces[i], 0..) |f, slot| bbox[slot] = faceLonLatBBox(f);
        maps[i] = .{ .tier = t, .faces = tier_faces[i], .pos = pos, .bbox = bbox };
        built = i + 1;
    }

    return .{ .gpa = gpa, .cells = cells, .tiers = tiers, .maps = maps };
}

// ===========================================================================
// Serialization — a precomputed partition as a self-contained sidecar (v4).
// ===========================================================================
//
// v4 makes staleness PER-FACE instead of all-or-nothing. Every face is stamped
// with a digest of everything its diff chain read: the owning cell's content
// and every subtrahend's, in application order (plane.faceInputDigest over
// contentDigest values). A loader recomputes current digests from the cells it
// holds and ADOPTS every stored face whose stamp still matches — that geometry
// is exactly what the sweep would recompute — sweeping only the rest. Adding,
// removing or updating cells therefore recomputes only the changed
// neighborhood, and a sidecar built over one cell set seeds a build over a
// larger one (the chart-pack merge case).
//
// Cells are identified by (name, date), never by index or rank: the `order`
// rank shifts when cells come and go, while the strings it derives from do
// not. Multiple editions of one name coexist (distinct dates); the digest
// disambiguates the rest.
//
// Format (little-endian, length-prefixed):
//   magic "T57P" | version u32 | n_ids u32 | n_maps u32
//   per id:   name_len u16 | name | date_len u16 | date | digest u64
//   per map:  tier u8 | n_faces u32 | n_empty u32
//     per face:  id_ref u32 | fdig u64 | n_rings u32
//       per ring:  n_pts u32 | pts (x i64, y i64)…
//     per empty: id_ref u32 | fdig u64
//   (an "empty" is a dropped gap-filler face — recorded so a clean reload
//    adopts the emptiness instead of re-running the diff chain that proved it)

pub const MAGIC = [4]u8{ 'T', '5', '7', 'P' };
// The version is the ALGORITHM generation, not just the byte layout: a sidecar
// carries the bake-time partition VERBATIM, and the digests validate only the
// input cells — never the faces. Faces computed by an older, buggier build
// otherwise outlive every fix (a field device rendered a Great Lakes cell
// owning Gulf-of-Mexico ground from exactly such a sidecar). Bump on ANY
// change to the owned-face computation.
pub const FORMAT_VERSION: u32 = 4; // 4: per-face input digests + (name,date) identity — incremental adoption

pub const LoadError = error{
    BadMagic,
    UnsupportedVersion, // v3 and earlier: no per-face digests; rebuild fresh
    Truncated,
    OutOfMemory,
};

/// The identity a face reference survives cell-set changes through. Borrowed;
/// the compositor's shims own the strings.
pub const CellId = struct { name: []const u8, date: []const u8 };

fn hashPolyPoints(h: *std.hash.Wyhash, poly: plane.Poly) void {
    for (poly) |ring| {
        const n: u32 = @intCast(ring.len);
        h.update(std.mem.asBytes(&n));
        h.update(std.mem.sliceAsBytes(ring)); // ring is []const Pt — real coordinate bytes
    }
}

/// Identity-stable content digest of one cell: everything a face computation
/// reads from it EXCEPT the order rank — the rank shifts when cells are added
/// or removed, while (date, name), which it encodes, does not. Coverage points
/// are hashed as raw bytes; both shipped targets are little-endian, and a
/// false mismatch only forces a (safe) recompute of that neighborhood.
pub fn contentDigest(cell: plane.Cell, id: CellId) u64 {
    var h = std.hash.Wyhash.init(0x5457_3537_4644_3454); // "TW57FD4T"
    h.update(std.mem.asBytes(&cell.cscl));
    h.update(std.mem.asBytes(&cell.band_floor));
    h.update(std.mem.asBytes(&cell.reach));
    h.update(id.name);
    h.update(&[_]u8{0});
    h.update(id.date);
    h.update(&[_]u8{0});
    for (cell.cov1) |poly| hashPolyPoints(&h, poly);
    h.update(&[_]u8{0xff}); // cov1/cov2 boundary marker
    for (cell.cov2) |poly| hashPolyPoints(&h, poly);
    return h.final();
}

fn contentDigests(a: std.mem.Allocator, cells: []const plane.Cell, ids: []const CellId) ![]u64 {
    std.debug.assert(ids.len == cells.len);
    const out = try a.alloc(u64, cells.len);
    for (cells, ids, out) |c, id, *d| d.* = contentDigest(c, id);
    return out;
}

fn putInt(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &tmp, v, .little);
    try buf.appendSlice(gpa, &tmp);
}

/// Encode `part` to a fresh `gpa`-owned byte slice (free with `gpa.free`).
/// `ids[i]` identifies `part.cells[i]`. Face digests are re-derived through the
/// same tier walk the build used, so a loader holding the same cells computes
/// the same stamps.
pub fn serialize(gpa: std.mem.Allocator, part: *const Partition, ids: []const CellId) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const sa = arena.allocator();

    const digests = try contentDigests(sa, part.cells, ids);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, &MAGIC);
    try putInt(gpa, &buf, u32, FORMAT_VERSION);
    try putInt(gpa, &buf, u32, @intCast(part.cells.len));
    try putInt(gpa, &buf, u32, @intCast(part.maps.len));
    for (ids, digests) |id, d| {
        try putInt(gpa, &buf, u16, @intCast(id.name.len));
        try buf.appendSlice(gpa, id.name);
        try putInt(gpa, &buf, u16, @intCast(id.date.len));
        try buf.appendSlice(gpa, id.date);
        try putInt(gpa, &buf, u64, d);
    }

    var idx = try plane.buildCoverageIndex(sa, part.cells);
    defer idx.deinit(sa);

    for (part.maps) |m| {
        const walk = try plane.tierWalk(sa, part.cells, m.tier);
        const bbs = try sa.alloc([4]i64, walk.order.len);
        for (walk.order, 0..) |ci, k| bbs[k] = idx.bbs[ci];
        const lists = try plane.subtrahendLists(sa, bbs);
        const fdig = try sa.alloc(u64, walk.order.len);
        var gl = std.ArrayList(u32).empty;
        for (walk.order, 0..) |ci, k| {
            gl.clearRetainingCapacity();
            for (lists[k]) |j| try gl.append(sa, @intCast(walk.order[j]));
            fdig[k] = plane.faceInputDigest(digests, ci, gl.items);
        }

        try putInt(gpa, &buf, u8, m.tier);
        try putInt(gpa, &buf, u32, @intCast(m.faces.len));
        try putInt(gpa, &buf, u32, @intCast(walk.order.len - m.faces.len));
        // Faces land in walk order (assembly appends walking it), so emitting
        // by walk keeps face order identical to the resident partition's.
        for (walk.order, 0..) |ci, k| {
            const slot = m.pos[ci];
            if (slot < 0) continue;
            const f = m.faces[@intCast(slot)];
            try putInt(gpa, &buf, u32, @intCast(ci));
            try putInt(gpa, &buf, u64, fdig[k]);
            try putInt(gpa, &buf, u32, @intCast(f.owned.len));
            for (f.owned) |ring| {
                try putInt(gpa, &buf, u32, @intCast(ring.len));
                for (ring) |p| {
                    try putInt(gpa, &buf, i64, p.x);
                    try putInt(gpa, &buf, i64, p.y);
                }
            }
        }
        for (walk.order, 0..) |ci, k| {
            if (m.pos[ci] >= 0) continue;
            try putInt(gpa, &buf, u32, @intCast(ci));
            try putInt(gpa, &buf, u64, fdig[k]);
        }
    }
    return buf.toOwnedSlice(gpa);
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn getInt(self: *Cursor, comptime T: type) !T {
        const n = @sizeOf(T);
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const v = std.mem.readInt(T, self.bytes[self.pos..][0..n], .little);
        self.pos += n;
        return v;
    }
    fn getBytes(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }
};

/// Parse a v4 sidecar into an adoption pool: every stored face whose cell
/// resolves by (name, date, digest) lands under (current index, face digest).
/// Unresolvable faces are skipped — their ground's owner changed, so the build
/// recomputes them. Geometry is decoded into `pa` (an arena the caller frees
/// after the build; adopted faces are duped out on assembly).
fn fillAdoptPool(
    pa: std.mem.Allocator,
    bytes: []const u8,
    ids: []const CellId,
    digests: []const u64,
    pool: *std.AutoHashMap(plane.AdoptCtx.PoolKey, plane.Poly),
) LoadError!void {
    if (bytes.len < MAGIC.len or !std.mem.eql(u8, bytes[0..MAGIC.len], &MAGIC)) return error.BadMagic;
    var cur = Cursor{ .bytes = bytes, .pos = MAGIC.len };
    if (try cur.getInt(u32) != FORMAT_VERSION) return error.UnsupportedVersion;
    const n_ids = try cur.getInt(u32);
    const n_maps = try cur.getInt(u32);

    // (name ++ 0 ++ date) → current indices; digest picks among duplicates.
    var by_key = std.StringHashMap(std.ArrayList(u32)).init(pa);
    for (ids, 0..) |id, i| {
        const key = try std.mem.concat(pa, u8, &.{ id.name, "\x00", id.date });
        const gop = try by_key.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
        try gop.value_ptr.append(pa, @intCast(i));
    }
    const resolve = try pa.alloc(?u32, n_ids);
    for (resolve) |*r| {
        const name = try cur.getBytes(try cur.getInt(u16));
        const date = try cur.getBytes(try cur.getInt(u16));
        const dig = try cur.getInt(u64);
        r.* = null;
        const key = try std.mem.concat(pa, u8, &.{ name, "\x00", date });
        if (by_key.get(key)) |list| for (list.items) |ci| {
            if (digests[ci] == dig) {
                r.* = ci;
                break;
            }
        };
    }

    for (0..n_maps) |_| {
        _ = try cur.getInt(u8); // tier — adoption is digest-keyed, tier-agnostic
        const n_faces = try cur.getInt(u32);
        const n_empty = try cur.getInt(u32);
        for (0..n_faces) |_| {
            const id_ref = try cur.getInt(u32);
            if (id_ref >= n_ids) return error.Truncated;
            const fdig = try cur.getInt(u64);
            const n_rings = try cur.getInt(u32);
            const rings = try pa.alloc([]const plane.Pt, n_rings);
            for (rings) |*ring| {
                const n_pts = try cur.getInt(u32);
                const pts = try pa.alloc(plane.Pt, n_pts);
                for (pts) |*p| p.* = .{ .x = try cur.getInt(i64), .y = try cur.getInt(i64) };
                ring.* = pts;
            }
            if (resolve[id_ref]) |ci| try pool.put(.{ .ci = ci, .fdig = fdig }, rings);
        }
        for (0..n_empty) |_| {
            const id_ref = try cur.getInt(u32);
            if (id_ref >= n_ids) return error.Truncated;
            const fdig = try cur.getInt(u64);
            if (resolve[id_ref]) |ci| try pool.put(.{ .ci = ci, .fdig = fdig }, &.{});
        }
    }
}

pub const IncrementalResult = struct {
    part: Partition,
    /// Face slots adopted verbatim from the sidecar (including empty markers).
    adopted: u64,
    /// Face slots that ran a diff chain. Zero ⇒ the sidecar already IS this
    /// partition (slots neither adopted nor swept were tier-reuse dupes).
    swept: u64,
};

/// Build over `cells`, adopting from a v4 sidecar every face whose input
/// digest still matches — same result bytes as `build`, only the changed
/// neighborhood is recomputed. `sidecar == null` builds fresh. A malformed or
/// pre-v4 sidecar errors; the caller falls back to `buildIncremental(.., null)`.
pub fn buildIncremental(
    gpa: std.mem.Allocator,
    cells: []const plane.Cell,
    ids: []const CellId,
    sidecar: ?[]const u8,
) !IncrementalResult {
    var pool_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer pool_arena.deinit();
    const pa = pool_arena.allocator();

    var adopt = plane.AdoptCtx{
        .digests = try contentDigests(pa, cells, ids),
        .pool = std.AutoHashMap(plane.AdoptCtx.PoolKey, plane.Poly).init(pa),
    };
    if (sidecar) |bytes| try fillAdoptPool(pa, bytes, ids, adopt.digests, &adopt.pool);

    const part = try buildWith(gpa, cells, &adopt);
    return .{ .part = part, .adopted = adopt.adopted, .swept = adopt.swept };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn boxPoly(a: std.mem.Allocator, x0: i64, y0: i64, x1: i64, y1: i64) !plane.Poly {
    const ring = try a.alloc(plane.Pt, 4);
    ring[0] = .{ .x = x0, .y = y0 };
    ring[1] = .{ .x = x1, .y = y0 };
    ring[2] = .{ .x = x1, .y = y1 };
    ring[3] = .{ .x = x0, .y = y1 };
    const rings = try a.alloc([]const plane.Pt, 1);
    rings[0] = ring;
    return rings;
}

test "partition band-stack: tiers descending, mapForZoom + ownerAt resolve per band" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Coarse [0,100]² at band floor 9 (coastal); harbor [40,60]² at floor 13 nested
    // inside it.
    const coarse = try boxPoly(a, 0, 0, 100, 100);
    const harbor = try boxPoly(a, 40, 40, 60, 60);
    const cells = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 0, .cov1 = &.{harbor} },
    };

    var part = try build(testing.allocator, &cells);
    defer part.deinit();

    // Two tiers, finest (highest floor) first.
    try testing.expectEqual(@as(usize, 2), part.tiers.len);
    try testing.expectEqual(@as(u8, 13), part.tiers[0]);
    try testing.expectEqual(@as(u8, 9), part.tiers[1]);

    // z14 → harbor band: harbor owns its box, coarse owns the surrounding ground.
    try testing.expectEqual(@as(?usize, 1), part.ownerAt(14, 50, 50));
    try testing.expectEqual(@as(?usize, 0), part.ownerAt(14, 10, 10));
    // z10 → harbor is below its floor, so the coarse cell owns the whole basin.
    try testing.expectEqual(@as(?usize, 0), part.ownerAt(10, 50, 50));
    // z3 → below every floor: resolves to the coarsest map, coarse still owns.
    try testing.expectEqual(@as(?usize, 0), part.ownerAt(3, 50, 50));
    // Outside all coverage: a true gap.
    try testing.expectEqual(@as(?usize, null), part.ownerAt(14, 200, 200));

    // ownedFace hands the compositor a cell's owned geometry to clip against.
    const hf = part.ownedFace(1, 14) orelse return error.TestUnexpectedResult;
    try testing.expect(boolean.pointInEvenOdd(hf, 50, 50)); // harbor owns its box
    const cf = part.ownedFace(0, 14) orelse return error.TestUnexpectedResult;
    try testing.expect(boolean.pointInEvenOdd(cf, 10, 10)); // coarse owns the surround
    try testing.expect(!boolean.pointInEvenOdd(cf, 50, 50)); // ...but NOT the harbor hole
    try testing.expect(part.ownedFace(1, 10) == null); // harbor below its floor: owns nothing
    try testing.expect(part.ownedFace(99, 14) == null); // out of range
}

test "fill-up: finer cells own coarse-tier ground only where nothing coarser covers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A coastal cell [0,100]² (floor 9) and two finer cells: a harbor [40,60]²
    // (floor 13) inside the coastal coverage, and a harbor [200,220]² (floor 13)
    // over ground NOTHING coarser covers.
    const coastal = try boxPoly(a, 0, 0, 100, 100);
    const harbor_in = try boxPoly(a, 40, 40, 60, 60);
    const harbor_out = try boxPoly(a, 200, 200, 220, 220);
    const cells = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coastal} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 0, .cov1 = &.{harbor_in} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 1, .cov1 = &.{harbor_out} },
    };

    var part = try build(testing.allocator, &cells);
    defer part.deinit();

    // z4 → the coarsest map (tier 9). The coastal cell keeps every point it
    // covers — the nested harbor is a gap-filler and takes NOTHING from it —
    // while the uncovered harbor owns its own ground instead of a blank.
    try testing.expectEqual(@as(?usize, 0), part.ownerAt(4, 50, 50));
    try testing.expectEqual(@as(?usize, 0), part.ownerAt(4, 10, 10));
    try testing.expectEqual(@as(?usize, 2), part.ownerAt(4, 210, 210));
    try testing.expectEqual(@as(?usize, null), part.ownerAt(4, 400, 400));

    // At the harbor band the nested harbor owns its box as before.
    try testing.expectEqual(@as(?usize, 1), part.ownerAt(14, 50, 50));
}

test "v4 sidecar: clean reload adopts every face slot and round-trips bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const coarse = try boxPoly(a, 0, 0, 100, 100);
    const harbor = try boxPoly(a, 40, 40, 60, 60);
    const cells = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 1, .cov1 = &.{harbor} },
    };
    const ids = [_]CellId{
        .{ .name = "US4COARSE", .date = "20250101" },
        .{ .name = "US5HARBR", .date = "20250202" },
    };

    var part = try build(testing.allocator, &cells);
    defer part.deinit();
    const bytes = try serialize(testing.allocator, &part, &ids);
    defer testing.allocator.free(bytes);

    var res = try buildIncremental(testing.allocator, &cells, &ids, bytes);
    defer res.part.deinit();
    try testing.expectEqual(@as(u64, 0), res.swept); // nothing recomputed
    try testing.expect(res.adopted > 0);
    const got = &res.part;

    // Structural equality: tiers, per-map faces (IN ORDER — the compositor's tile
    // iteration order rides on it), owned rings and their points.
    try testing.expectEqualSlices(u8, part.tiers, got.tiers);
    try testing.expectEqual(part.maps.len, got.maps.len);
    for (part.maps, got.maps) |m0, m1| {
        try testing.expectEqual(m0.tier, m1.tier);
        try testing.expectEqualSlices(i32, m0.pos, m1.pos);
        try testing.expectEqual(m0.faces.len, m1.faces.len);
        for (m0.faces, m1.faces) |f0, f1| {
            try testing.expectEqual(f0.index, f1.index);
            try testing.expectEqual(f0.owned.len, f1.owned.len);
            for (f0.owned, f1.owned) |r0, r1| {
                try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(r0), std.mem.sliceAsBytes(r1));
            }
        }
    }

    // Re-serializing the adopted partition yields the identical bytes.
    const bytes2 = try serialize(testing.allocator, got, &ids);
    defer testing.allocator.free(bytes2);
    try testing.expectEqualSlices(u8, bytes, bytes2);

    // Ownership queries agree with the freshly-built partition.
    try testing.expectEqual(part.ownerAt(14, 50, 50), got.ownerAt(14, 50, 50));
    try testing.expectEqual(part.ownerAt(14, 10, 10), got.ownerAt(14, 10, 10));
    try testing.expectEqual(part.ownerAt(10, 50, 50), got.ownerAt(10, 50, 50));
}

test "v4 sidecar: a changed cell recomputes only its neighborhood; corrupt blobs rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const coarse = try boxPoly(a, 0, 0, 100, 100);
    const harbor = try boxPoly(a, 40, 40, 60, 60);
    const far = try boxPoly(a, 500, 500, 600, 600); // disjoint from the change
    const cells = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 1, .cov1 = &.{harbor} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 2, .cov1 = &.{far} },
    };
    const ids = [_]CellId{
        .{ .name = "US4COARSE", .date = "20250101" },
        .{ .name = "US5HARBR", .date = "20250202" },
        .{ .name = "US5FARAWY", .date = "20250303" },
    };
    var part = try build(testing.allocator, &cells);
    defer part.deinit();
    const bytes = try serialize(testing.allocator, &part, &ids);
    defer testing.allocator.free(bytes);

    // One harbor vertex moves (a chart update). The incremental build over the
    // new cells must byte-equal a fresh build — and the far cell must adopt.
    const harbor2 = try boxPoly(a, 41, 40, 60, 60);
    const cells2 = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 1, .cov1 = &.{harbor2} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 2, .cov1 = &.{far} },
    };
    var fresh = try build(testing.allocator, &cells2);
    defer fresh.deinit();
    const want = try serialize(testing.allocator, &fresh, &ids);
    defer testing.allocator.free(want);

    var res = try buildIncremental(testing.allocator, &cells2, &ids, bytes);
    defer res.part.deinit();
    const got = try serialize(testing.allocator, &res.part, &ids);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
    try testing.expect(res.adopted > 0); // the far cell's slots adopted
    try testing.expect(res.swept > 0); // the changed neighborhood recomputed

    // A truncated blob, a bad magic, and a pre-v4 version are caught, not UB.
    try testing.expectError(error.Truncated, buildIncremental(testing.allocator, &cells, &ids, bytes[0 .. bytes.len - 4]));
    const bad = [_]u8{0} ** 8;
    try testing.expectError(error.BadMagic, buildIncremental(testing.allocator, &cells, &ids, &bad));
    const old = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(old);
    std.mem.writeInt(u32, old[4..8], 3, .little);
    try testing.expectError(error.UnsupportedVersion, buildIncremental(testing.allocator, &cells, &ids, old));
}

test "fuzz: incremental build over a mutated set == fresh build, byte for byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0x14C4E4E7);
    const rnd = prng.random();
    const grid: i64 = 64;

    const Gen = struct {
        fn cell(aa: std.mem.Allocator, r: std.Random, k: usize) !struct { c: plane.Cell, id: CellId } {
            const x0 = r.intRangeAtMost(i64, -6, 4) * grid;
            const y0 = r.intRangeAtMost(i64, -6, 4) * grid;
            const w = r.intRangeAtMost(i64, 1, 6) * grid;
            const h = r.intRangeAtMost(i64, 1, 6) * grid;
            const cov = try boxPoly(aa, x0, y0, x0 + w, y0 + h);
            const covs = try aa.alloc(plane.Poly, 1);
            covs[0] = cov;
            return .{
                .c = .{
                    .cscl = @intCast(1000 + k * 100),
                    .band_floor = r.intRangeAtMost(u8, 0, 13),
                    .order = k,
                    .reach = if (r.uintLessThan(u8, 4) == 0) r.intRangeAtMost(u8, 5, 13) else 255,
                    .cov1 = covs,
                },
                .id = .{
                    .name = try std.fmt.allocPrint(aa, "C{d}", .{k}),
                    .date = try std.fmt.allocPrint(aa, "202501{d:0>2}", .{(k % 28) + 1}),
                },
            };
        }
    };

    var trial: usize = 0;
    while (trial < 40) : (trial += 1) {
        const n = rnd.intRangeAtMost(usize, 2, 8);
        var cells_a = std.ArrayList(plane.Cell).empty;
        var ids_a = std.ArrayList(CellId).empty;
        for (0..n) |k| {
            const g = try Gen.cell(a, rnd, k);
            try cells_a.append(a, g.c);
            try ids_a.append(a, g.id);
        }
        var part_a = try build(testing.allocator, cells_a.items);
        const sc = try serialize(testing.allocator, &part_a, ids_a.items);
        part_a.deinit();
        defer testing.allocator.free(sc);

        // Mutate into set B: remove one, add one, or update one in place.
        var cells_b = std.ArrayList(plane.Cell).empty;
        try cells_b.appendSlice(a, cells_a.items);
        var ids_b = std.ArrayList(CellId).empty;
        try ids_b.appendSlice(a, ids_a.items);
        switch (rnd.uintLessThan(u8, 3)) {
            0 => { // remove a random cell (ranks recompute below)
                const victim = rnd.uintLessThan(usize, cells_b.items.len);
                _ = cells_b.orderedRemove(victim);
                _ = ids_b.orderedRemove(victim);
            },
            1 => { // add a new cell
                const g = try Gen.cell(a, rnd, n);
                try cells_b.append(a, g.c);
                try ids_b.append(a, g.id);
            },
            else => { // a chart update: new coverage, new date
                const victim = rnd.uintLessThan(usize, cells_b.items.len);
                const g = try Gen.cell(a, rnd, n + 1);
                cells_b.items[victim].cov1 = g.c.cov1;
                ids_b.items[victim].date = "20260101";
            },
        }
        // Re-rank order by (date, name) exactly as toPlaneCells does — order is
        // a derived rank, so a membership change reassigns it.
        const rank = try a.alloc(usize, cells_b.items.len);
        for (rank, 0..) |*v, i| v.* = i;
        std.mem.sort(usize, rank, ids_b.items, struct {
            fn lt(ids: []const CellId, x: usize, y: usize) bool {
                return ordersBeforeKeys(ids[x].date, ids[x].name, ids[y].date, ids[y].name);
            }
        }.lt);
        for (rank, 0..) |ci, r| cells_b.items[ci].order = r;

        var fresh = try build(testing.allocator, cells_b.items);
        const want = try serialize(testing.allocator, &fresh, ids_b.items);
        fresh.deinit();
        defer testing.allocator.free(want);

        var res = try buildIncremental(testing.allocator, cells_b.items, ids_b.items, sc);
        const got = try serialize(testing.allocator, &res.part, ids_b.items);
        res.part.deinit();
        defer testing.allocator.free(got);

        try testing.expectEqualSlices(u8, want, got);
        _ = arena.reset(.retain_capacity);
    }
}

test "merge: a one-pack sidecar seeds the union build; distant faces adopt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Pack A around the origin, pack B far east — disjoint ground.
    const a_coarse = try boxPoly(a, 0, 0, 200, 200);
    const a_fine = try boxPoly(a, 50, 50, 100, 100);
    const b_coarse = try boxPoly(a, 5000, 0, 5200, 200);
    const b_fine = try boxPoly(a, 5050, 50, 5100, 100);

    const cells_a = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{a_coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 1, .cov1 = &.{a_fine} },
    };
    const ids_a = [_]CellId{
        .{ .name = "US4WEST", .date = "20250101" },
        .{ .name = "US5WEST", .date = "20250102" },
    };
    var part_a = try build(testing.allocator, &cells_a);
    defer part_a.deinit();
    const sc = try serialize(testing.allocator, &part_a, &ids_a);
    defer testing.allocator.free(sc);

    // The union: A's cells keep their relative order; B appends after.
    const cells_u = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{a_coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 1, .cov1 = &.{a_fine} },
        .{ .cscl = 100_000, .band_floor = 9, .order = 2, .cov1 = &.{b_coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 3, .cov1 = &.{b_fine} },
    };
    const ids_u = [_]CellId{
        .{ .name = "US4WEST", .date = "20250101" },
        .{ .name = "US5WEST", .date = "20250102" },
        .{ .name = "US4EAST", .date = "20250201" },
        .{ .name = "US5EAST", .date = "20250202" },
    };

    var fresh = try build(testing.allocator, &cells_u);
    defer fresh.deinit();
    const want = try serialize(testing.allocator, &fresh, &ids_u);
    defer testing.allocator.free(want);

    var res = try buildIncremental(testing.allocator, &cells_u, &ids_u, sc);
    defer res.part.deinit();
    const got = try serialize(testing.allocator, &res.part, &ids_u);
    defer testing.allocator.free(got);

    try testing.expectEqualSlices(u8, want, got);
    try testing.expect(res.adopted > 0); // A's ground, untouched by B, seeded the union
}
