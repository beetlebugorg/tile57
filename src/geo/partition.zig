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

pub const BandMap = struct {
    /// The band floor (lowest zoom) this map is computed at.
    tier: u8,
    /// One face per cell owning ground at this band; `face.index` indexes
    /// `Partition.cells`. `gpa`-owned.
    faces: []plane.OwnedCell,
    /// `n_cells`-long: global cell index → its slot in `faces`, or -1 if the cell
    /// owns nothing at this band. Lets the compositor fetch a cell's face in O(1).
    pos: []i32,
};

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

    /// Faces owned at band index `i` (0 = finest band) — for the renderer/compositor
    /// to iterate every owner at a band.
    pub fn facesForBand(self: *const Partition, i: usize) []const plane.OwnedCell {
        return self.maps[i].faces;
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
    var built: usize = 0;
    errdefer for (maps[0..built]) |m| {
        plane.freeOwned(gpa, m.faces);
        gpa.free(m.pos);
    };
    for (tiers, 0..) |t, i| {
        const faces = try plane.ownedAtTierIndexed(gpa, cells, t);
        errdefer plane.freeOwned(gpa, faces);
        const pos = try gpa.alloc(i32, cells.len);
        @memset(pos, -1);
        for (faces, 0..) |f, slot| pos[f.index] = @intCast(slot);
        maps[i] = .{ .tier = t, .faces = faces, .pos = pos };
        built = i + 1;
    }

    return .{ .gpa = gpa, .cells = cells, .tiers = tiers, .maps = maps };
}

// ===========================================================================
// Serialization — a precomputed partition as a self-contained sidecar.
// ===========================================================================
//
// The partition is a pure function of the cell set (each cell's coverage rings,
// cscl, band_floor, order, reach). Building it runs the expensive owned-face
// booleans; the RESULT is tiny (the whole owned-face geometry is ~1 MB for a
// district). So it is worth precomputing once and reusing: a cold recompose skips
// the build, and a runtime compositor can serve tiles from the sidecar alone.
//
// Format (little-endian, length-prefixed):
//   magic "T57P" | version u32 | input_key u64 | n_cells u32 | n_maps u32
//   per map:  tier u8 | n_faces u32
//     per face:  cell_index u32 | n_rings u32
//       per ring:  n_pts u32 | pts (x i64, y i64)…
// `pos` and `tiers` are reconstructed on load (pos from faces + n_cells).
//
// `input_key` binds the geometry to the exact cells it was built from: a loader
// recomputes it from the cells it holds and rejects a stale sidecar (→ rebuild),
// which is what makes an incremental recompose safe when coverage is unchanged.

pub const MAGIC = [4]u8{ 'T', '5', '7', 'P' };
pub const FORMAT_VERSION: u32 = 1;

pub const LoadError = error{
    BadMagic,
    UnsupportedVersion,
    StalePartition, // input_key mismatch — the cells changed; rebuild
    CellCountMismatch,
    Truncated,
    OutOfMemory,
};

/// A hash of the exact inputs `build` consumes, so a stored partition can be
/// matched to the cells a loader holds. Coverage points are hashed as raw bytes;
/// both shipped targets are little-endian, and a false mismatch only forces a
/// (safe) rebuild.
fn hashPolyPoints(h: *std.hash.Wyhash, poly: plane.Poly) void {
    for (poly) |ring| {
        const n: u32 = @intCast(ring.len);
        h.update(std.mem.asBytes(&n));
        h.update(std.mem.sliceAsBytes(ring)); // ring is []const Pt — real coordinate bytes
    }
}

pub fn inputKey(cells: []const plane.Cell) u64 {
    var h = std.hash.Wyhash.init(0x5457_3537_5041_5254); // "TW57PART"
    for (cells) |c| {
        h.update(std.mem.asBytes(&c.cscl));
        h.update(std.mem.asBytes(&c.band_floor));
        h.update(std.mem.asBytes(&c.order));
        h.update(std.mem.asBytes(&c.reach));
        // cov1/cov2 are bags of polygons (each a set of rings). Descend to the POINTS and hash
        // their bytes — never the ring slices' fat pointers, which are heap addresses that vary
        // per process. Ring lengths go in too so a regrouping can't alias to the same digest.
        for (c.cov1) |poly| hashPolyPoints(&h, poly);
        h.update(&[_]u8{0xff}); // cov1/cov2 boundary marker
        for (c.cov2) |poly| hashPolyPoints(&h, poly);
        h.update(&[_]u8{0xfe}); // cell boundary marker
    }
    return h.final();
}

fn putInt(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &tmp, v, .little);
    try buf.appendSlice(gpa, &tmp);
}

/// Encode `part` to a fresh `gpa`-owned byte slice (free with `gpa.free`).
pub fn serialize(gpa: std.mem.Allocator, part: *const Partition) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, &MAGIC);
    try putInt(gpa, &buf, u32, FORMAT_VERSION);
    try putInt(gpa, &buf, u64, inputKey(part.cells));
    try putInt(gpa, &buf, u32, @intCast(part.cells.len));
    try putInt(gpa, &buf, u32, @intCast(part.maps.len));
    for (part.maps) |m| {
        try putInt(gpa, &buf, u8, m.tier);
        try putInt(gpa, &buf, u32, @intCast(m.faces.len));
        for (m.faces) |f| {
            try putInt(gpa, &buf, u32, @intCast(f.index));
            try putInt(gpa, &buf, u32, @intCast(f.owned.len));
            for (f.owned) |ring| {
                try putInt(gpa, &buf, u32, @intCast(ring.len));
                for (ring) |p| {
                    try putInt(gpa, &buf, i64, p.x);
                    try putInt(gpa, &buf, i64, p.y);
                }
            }
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
};

// Read one face (index + rings) fully, or free its partial geometry and error.
fn readFace(gpa: std.mem.Allocator, cur: *Cursor) !plane.OwnedCell {
    const index: usize = @intCast(try cur.getInt(u32));
    const n_rings = try cur.getInt(u32);
    const owned = try gpa.alloc([]plane.Pt, n_rings);
    var built: usize = 0;
    errdefer {
        for (owned[0..built]) |r| gpa.free(r);
        gpa.free(owned);
    }
    while (built < n_rings) : (built += 1) {
        const n_pts = try cur.getInt(u32);
        const ring = try gpa.alloc(plane.Pt, n_pts);
        errdefer gpa.free(ring);
        for (ring) |*p| p.* = .{ .x = try cur.getInt(i64), .y = try cur.getInt(i64) };
        owned[built] = ring;
    }
    return .{ .index = index, .owned = owned };
}

/// Decode a sidecar produced by `serialize` into a live `Partition` that borrows
/// `cells` (kept alive by the caller, exactly as `build` does). Rejects a sidecar
/// whose `input_key` does not match `cells` (the cells changed → rebuild).
pub fn deserialize(gpa: std.mem.Allocator, bytes: []const u8, cells: []const plane.Cell) LoadError!Partition {
    if (bytes.len < MAGIC.len or !std.mem.eql(u8, bytes[0..MAGIC.len], &MAGIC)) return error.BadMagic;
    var cur = Cursor{ .bytes = bytes, .pos = MAGIC.len };
    if (try cur.getInt(u32) != FORMAT_VERSION) return error.UnsupportedVersion;
    if (try cur.getInt(u64) != inputKey(cells)) return error.StalePartition;
    if (try cur.getInt(u32) != @as(u32, @intCast(cells.len))) return error.CellCountMismatch;
    const n_maps = try cur.getInt(u32);

    const tiers = try gpa.alloc(u8, n_maps);
    errdefer gpa.free(tiers);
    const maps = try gpa.alloc(BandMap, n_maps);
    errdefer gpa.free(maps);
    var built_maps: usize = 0;
    errdefer for (maps[0..built_maps]) |m| {
        plane.freeOwned(gpa, m.faces);
        gpa.free(m.pos);
    };

    for (0..n_maps) |i| {
        const tier = try cur.getInt(u8);
        const n_faces = try cur.getInt(u32);
        const faces = try gpa.alloc(plane.OwnedCell, n_faces);
        var built_faces: usize = 0;
        errdefer {
            for (faces[0..built_faces]) |f| boolean.freePolygon(gpa, f.owned);
            gpa.free(faces);
        }
        while (built_faces < n_faces) : (built_faces += 1) {
            faces[built_faces] = try readFace(gpa, &cur);
        }
        const pos = try gpa.alloc(i32, cells.len);
        @memset(pos, -1);
        for (faces, 0..) |f, slot| pos[f.index] = @intCast(slot);
        tiers[i] = tier;
        maps[i] = .{ .tier = tier, .faces = faces, .pos = pos };
        built_maps = i + 1;
    }

    return .{ .gpa = gpa, .cells = cells, .tiers = tiers, .maps = maps };
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

test "partition serialize/deserialize round-trips exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const coarse = try boxPoly(a, 0, 0, 100, 100);
    const harbor = try boxPoly(a, 40, 40, 60, 60);
    const cells = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 0, .cov1 = &.{harbor} },
    };

    var part = try build(testing.allocator, &cells);
    defer part.deinit();

    const bytes = try serialize(testing.allocator, &part);
    defer testing.allocator.free(bytes);

    var got = try deserialize(testing.allocator, bytes, &cells);
    defer got.deinit();

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

    // Re-serializing the loaded partition yields the identical bytes.
    const bytes2 = try serialize(testing.allocator, &got);
    defer testing.allocator.free(bytes2);
    try testing.expectEqualSlices(u8, bytes, bytes2);

    // Ownership queries agree with the freshly-built partition.
    try testing.expectEqual(part.ownerAt(14, 50, 50), got.ownerAt(14, 50, 50));
    try testing.expectEqual(part.ownerAt(14, 10, 10), got.ownerAt(14, 10, 10));
    try testing.expectEqual(part.ownerAt(10, 50, 50), got.ownerAt(10, 50, 50));
}

test "partition sidecar rejects a stale cell set + a corrupt blob" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const coarse = try boxPoly(a, 0, 0, 100, 100);
    const harbor = try boxPoly(a, 40, 40, 60, 60);
    const cells = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 0, .cov1 = &.{harbor} },
    };
    var part = try build(testing.allocator, &cells);
    defer part.deinit();
    const bytes = try serialize(testing.allocator, &part);
    defer testing.allocator.free(bytes);

    // Different coverage → different input_key → rejected (→ caller rebuilds).
    const harbor2 = try boxPoly(a, 41, 40, 60, 60); // one vertex moved
    const cells2 = [_]plane.Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 0, .cov1 = &.{harbor2} },
    };
    try testing.expectError(error.StalePartition, deserialize(testing.allocator, bytes, &cells2));

    // A truncated blob and a bad magic are caught, not UB.
    try testing.expectError(error.Truncated, deserialize(testing.allocator, bytes[0 .. bytes.len - 4], &cells));
    const bad = [_]u8{0} ** 8;
    try testing.expectError(error.BadMagic, deserialize(testing.allocator, &bad, &cells));
}
