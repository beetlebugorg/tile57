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
        for (self.maps) |m| plane.freeOwned(self.gpa, m.faces);
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
    errdefer for (maps[0..built]) |m| plane.freeOwned(gpa, m.faces);
    for (tiers, 0..) |t, i| {
        maps[i] = .{ .tier = t, .faces = try plane.ownedAtTierIndexed(gpa, cells, t) };
        built = i + 1;
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
}
