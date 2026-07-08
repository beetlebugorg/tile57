//! Coverage-clipped best-available partition — the first-stage planar partition of
//! the cross-band chart composition. "The finest cell whose M_COVR(CATCOV=1) covers
//! a point owns that
//! ground; every other cell is clipped away there." This module turns a set of
//! ENC cells (each carrying a compilation scale, a band-eligibility floor, and
//! coverage rings) into, per **zoom tier**, one `owned` region per cell — a
//! seamless planar partition with no overlap and no gap.
//!
//! The partition is **per-tier**, not once-per-bake: because a harbour cell is
//! not drawn below its band floor, "which cells are in the pool" depends on the
//! zoom. Computing ownership once would open a permanent blank window over every
//! basin owned by a below-floor fine cell (the HOLES blocker); recomputing per
//! distinct floor (≤6 tiers) closes it geometrically.
//!
//! Everything runs on integer coordinates via `boolean.Pt` (i64): coverage is
//! stored as degrees × 10⁷, so seams that adjacent cells digitised independently
//! round to the same integers before any boolean runs.
//! All set algebra goes through `boolean` (Martinez, overlap-typed, deterministic).
//!
//! Phase 0 scope: this computes and validates the partition, the tile classifier
//! (FULL / EMPTY / SEAM), and `clipLineOutsidePolys`. Nothing here is wired to the
//! baker or the live oracle yet — that is a later phase. The S-57 adapter (filling
//! `Cell` from an `s57.Cell`, the cscl≤0 / date-order tie-break decisions Q1/Q4)
//! is also deferred; `Cell` is deliberately decoupled so this stays pure and
//! unit-testable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const boolean = @import("boolean.zig");

pub const Pt = boolean.Pt;
/// A polygon: a set of even-odd rings (exterior + holes). One M_COVR feature.
pub const Poly = boolean.Polygon;

/// One ENC cell as the partition sees it. Coverage is already in integer
/// coordinates (degrees × 10⁷).
/// `cov1`/`cov2` are bags of features that may mutually overlap — they are
/// `unionAll`-cleaned into one simple region before use.
pub const Cell = struct {
    /// Compilation scale denominator (1:N). Smaller = finer = wins ties for ground.
    cscl: i32,
    /// Lowest zoom at which this cell participates (its band floor).
    band_floor: u8,
    /// Deterministic tie-break among equal-cscl cells — the adapter fills this
    /// from cell identity (issue/update date, then DSNM) so the newer survey wins
    /// a double-owned strip (spec Q4). Lower sorts finer (earlier in the walk).
    order: u64,
    /// CATCOV=1 coverage features.
    cov1: []const Poly,
    /// CATCOV=2 explicit no-data features (subtracted, so a coarser band can fill).
    cov2: []const Poly = &.{},
};

/// A cell's owned region at a tier: `index` into the caller's cell slice and the
/// clipped coverage it owns (freshly allocated; free with `boolean.freePolygon`).
pub const OwnedCell = struct {
    index: usize,
    owned: [][]Pt,
};

pub fn freeOwned(gpa: Allocator, cells: []OwnedCell) void {
    for (cells) |c| boolean.freePolygon(gpa, c.owned);
    gpa.free(cells);
}

/// `coverage(cell) = ∪CATCOV1 \ ∪CATCOV2`, allocated in `a`.
fn cellCoverage(a: Allocator, cell: Cell) ![][]Pt {
    const cov1 = try boolean.unionAll(a, cell.cov1);
    if (cell.cov2.len == 0) return cov1;
    const cov2 = try boolean.unionAll(a, cell.cov2);
    defer boolean.freePolygon(a, cov2);
    defer boolean.freePolygon(a, cov1);
    return boolean.compute(a, cov1, cov2, .diff);
}

fn finerLess(_: void, a: Cell, b: Cell) bool {
    if (a.cscl != b.cscl) return a.cscl < b.cscl;
    return a.order < b.order;
}

/// The per-tier partition: for every cell eligible at `tier` (band_floor ≤ tier),
/// walking finest→coarsest, `owned = coverage \ (∪ coverage of all finer eligible
/// cells)`. The union of the returned `owned` regions equals the union of all
/// eligible coverages, partitioned with no overlap (validated by the tests).
pub fn ownedAtTier(gpa: Allocator, cells: []const Cell, tier: u8) ![]OwnedCell {
    // Eligible cells, in a total finest→coarsest, path-independent order.
    var order = std.ArrayList(usize).empty;
    defer order.deinit(gpa);
    for (cells, 0..) |c, i| {
        if (c.band_floor <= tier) try order.append(gpa, i);
    }
    std.mem.sort(usize, order.items, cells, struct {
        fn lt(cs: []const Cell, ia: usize, ib: usize) bool {
            return finerLess({}, cs[ia], cs[ib]);
        }
    }.lt);

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var out = std.ArrayList(OwnedCell).empty;
    errdefer {
        for (out.items) |c| boolean.freePolygon(gpa, c.owned);
        out.deinit(gpa);
    }

    // Accumulated coverage of all finer eligible cells processed so far.
    var covered: [][]Pt = try sa.alloc([]Pt, 0);

    for (order.items) |i| {
        const cov = try cellCoverage(sa, cells[i]);
        // owned = cov \ covered, allocated in gpa (the kept result).
        const owned = if (covered.len == 0)
            try dupePolygonGpa(gpa, cov)
        else
            try boolean.compute(gpa, cov, covered, .diff);
        try out.append(gpa, .{ .index = i, .owned = owned });

        // covered ∪= cov (scratch).
        const merged = try boolean.compute(sa, covered, cov, .unite);
        covered = merged;
    }
    return out.toOwnedSlice(gpa);
}

fn dupePolygonGpa(gpa: Allocator, poly: Poly) ![][]Pt {
    const out = try gpa.alloc([]Pt, poly.len);
    errdefer gpa.free(out);
    var n: usize = 0;
    errdefer for (out[0..n]) |r| gpa.free(r);
    while (n < poly.len) : (n += 1) out[n] = try gpa.dupe(Pt, poly[n]);
    return out;
}

// ---------------------------------------------------------------------------
// Line clipping against coverage (no polygon boolean).
// ---------------------------------------------------------------------------

/// Even-odd containment evaluated at a float point — used for the strictly-
/// interior midpoint of a line sub-run, which by construction lies off every
/// covered edge, so float rounding is safe.
fn pointInEvenOddF(rings: Poly, x: f64, y: f64) bool {
    var inside = false;
    for (rings) |ring| {
        if (ring.len < 3) continue;
        var j = ring.len - 1;
        for (ring, 0..) |pi, i| {
            const pj = ring[j];
            j = i;
            const yi: f64 = @floatFromInt(pi.y);
            const yj: f64 = @floatFromInt(pj.y);
            if ((yi > y) != (yj > y)) {
                const xi: f64 = @floatFromInt(pi.x);
                const xj: f64 = @floatFromInt(pj.x);
                const xint = xi + (y - yi) * (xj - xi) / (yj - yi);
                if (x < xint) inside = !inside;
            }
        }
    }
    return inside;
}

/// Keep the parts of `line` that lie OUTSIDE `covered`. Each segment is split at
/// its integer crossings with every covered edge; a sub-run survives iff its
/// midpoint is outside `covered` (the finer cell owns the covered side and the
/// seam stroke). Returns a list of poly-lines allocated in `gpa`.
///
/// This is the line analogue of the area difference — no polygon boolean, so a
/// coarse coastline inside finer coverage is dropped whole (not offset-doubled).
pub fn clipLineOutsidePolys(gpa: Allocator, line: []const Pt, covered: Poly) ![][]Pt {
    var out = std.ArrayList([]Pt).empty;
    errdefer {
        for (out.items) |r| gpa.free(r);
        out.deinit(gpa);
    }
    if (line.len < 2) return out.toOwnedSlice(gpa);

    var run = std.ArrayList(Pt).empty;
    defer run.deinit(gpa);

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    for (0..line.len - 1) |si| {
        const a = line[si];
        const b = line[si + 1];
        if (a.eql(b)) continue;

        // Gather split points (crossings) along a→b, as (t_scaled, point).
        _ = scratch.reset(.retain_capacity);
        const sc = scratch.allocator();
        var splits = std.ArrayList(SplitPt).empty;
        try splits.append(sc, .{ .key = keyOf(a, a, b), .p = a });
        try splits.append(sc, .{ .key = keyOf(b, a, b), .p = b });
        for (covered) |ring| {
            if (ring.len < 2) continue;
            var j = ring.len - 1;
            for (ring, 0..) |c, k| {
                const d = ring[j];
                j = k;
                const it = boolean.segIntersect(a, b, d, c);
                switch (it.n) {
                    1 => try splits.append(sc, .{ .key = keyOf(it.p0, a, b), .p = it.p0 }),
                    2 => {
                        try splits.append(sc, .{ .key = keyOf(it.p0, a, b), .p = it.p0 });
                        try splits.append(sc, .{ .key = keyOf(it.p1, a, b), .p = it.p1 });
                    },
                    else => {},
                }
            }
        }
        std.mem.sort(SplitPt, splits.items, {}, SplitPt.lt);

        // Walk consecutive distinct split points; keep sub-runs whose midpoint is
        // outside covered.
        var prev = splits.items[0].p;
        if (run.items.len == 0) try run.append(gpa, prev);
        for (splits.items[1..]) |sp| {
            const q = sp.p;
            if (q.eql(prev)) continue;
            const mx = (@as(f64, @floatFromInt(prev.x)) + @as(f64, @floatFromInt(q.x))) / 2;
            const my = (@as(f64, @floatFromInt(prev.y)) + @as(f64, @floatFromInt(q.y))) / 2;
            if (pointInEvenOddF(covered, mx, my)) {
                // Sub-run is covered: flush the kept run (it ends at prev) and skip.
                try flushRun(gpa, &out, &run);
                try run.append(gpa, q);
            } else {
                try run.append(gpa, q);
            }
            prev = q;
        }
    }
    try flushRun(gpa, &out, &run);
    return out.toOwnedSlice(gpa);
}

const SplitPt = struct {
    key: i128,
    p: Pt,
    fn lt(_: void, a: SplitPt, b: SplitPt) bool {
        return a.key < b.key;
    }
};

/// A monotone parameter of point `p` along a→b (projection onto the longer axis,
/// scaled) — enough to sort crossings without division.
fn keyOf(p: Pt, a: Pt, b: Pt) i128 {
    const dx = @as(i128, b.x) - a.x;
    const dy = @as(i128, b.y) - a.y;
    if (@abs(dx) >= @abs(dy)) {
        const t = (@as(i128, p.x) - a.x);
        return if (dx >= 0) t else -t;
    }
    const t = (@as(i128, p.y) - a.y);
    return if (dy >= 0) t else -t;
}

fn flushRun(gpa: Allocator, out: *std.ArrayList([]Pt), run: *std.ArrayList(Pt)) !void {
    if (run.items.len >= 2) {
        try out.append(gpa, try gpa.dupe(Pt, run.items));
    }
    run.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Tile classifier — FULL / EMPTY / SEAM via an edge-bucket grid.
// ---------------------------------------------------------------------------

pub const Box = struct { min_x: i64, min_y: i64, max_x: i64, max_y: i64 };
pub const Verdict = enum {
    /// No covered edge crosses the tile and it is outside coverage: the cell owns
    /// the whole tile — box-clip, byte-identical to today's non-seam tiles.
    full,
    /// The tile is inside coverage: emit nothing.
    empty,
    /// A covered edge crosses the tile: real geometry must run here.
    seam,
};

/// A uniform bucket index of every covered-coverage edge, keyed by grid cell, so
/// the per-tile classifier touches only edges near the tile instead of all of them.
pub const EdgeGrid = struct {
    cell: i64,
    buckets: std.AutoHashMap(BKey, std.ArrayList(Seg)),
    covered: Poly,
    gpa: Allocator,

    const BKey = struct { gx: i64, gy: i64 };
    pub const Seg = struct { a: Pt, b: Pt };

    /// Build over `covered` with square buckets of side `cell` (E7 units).
    pub fn init(gpa: Allocator, covered: Poly, cell: i64) !EdgeGrid {
        std.debug.assert(cell > 0);
        var g: EdgeGrid = .{
            .cell = cell,
            .buckets = std.AutoHashMap(BKey, std.ArrayList(Seg)).init(gpa),
            .covered = covered,
            .gpa = gpa,
        };
        for (covered) |ring| {
            if (ring.len < 2) continue;
            var j = ring.len - 1;
            for (ring, 0..) |p, k| {
                const q = ring[j];
                j = k;
                try g.insert(.{ .a = q, .b = p });
            }
        }
        return g;
    }

    pub fn deinit(self: *EdgeGrid) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |list| list.deinit(self.gpa);
        self.buckets.deinit();
    }

    fn gridOf(self: *const EdgeGrid, v: i64) i64 {
        return @divFloor(v, self.cell);
    }

    fn insert(self: *EdgeGrid, s: Seg) !void {
        const gx0 = self.gridOf(@min(s.a.x, s.b.x));
        const gx1 = self.gridOf(@max(s.a.x, s.b.x));
        const gy0 = self.gridOf(@min(s.a.y, s.b.y));
        const gy1 = self.gridOf(@max(s.a.y, s.b.y));
        var gx = gx0;
        while (gx <= gx1) : (gx += 1) {
            var gy = gy0;
            while (gy <= gy1) : (gy += 1) {
                const gop = try self.buckets.getOrPut(.{ .gx = gx, .gy = gy });
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Seg).empty;
                try gop.value_ptr.append(self.gpa, s);
            }
        }
    }

    /// Any covered edge that intersects (crosses or touches) the box.
    pub fn crossesBox(self: *const EdgeGrid, box: Box) bool {
        const gx0 = self.gridOf(box.min_x);
        const gx1 = self.gridOf(box.max_x);
        const gy0 = self.gridOf(box.min_y);
        const gy1 = self.gridOf(box.max_y);
        var gx = gx0;
        while (gx <= gx1) : (gx += 1) {
            var gy = gy0;
            while (gy <= gy1) : (gy += 1) {
                const list = self.buckets.get(.{ .gx = gx, .gy = gy }) orelse continue;
                for (list.items) |s| {
                    if (segIntersectsBox(s.a, s.b, box)) return true;
                }
            }
        }
        return false;
    }

    /// Classify a tile against the coverage this grid indexes.
    pub fn classify(self: *const EdgeGrid, box: Box) Verdict {
        if (self.crossesBox(box)) return .seam;
        const cx = (@as(f64, @floatFromInt(box.min_x)) + @as(f64, @floatFromInt(box.max_x))) / 2;
        const cy = (@as(f64, @floatFromInt(box.min_y)) + @as(f64, @floatFromInt(box.max_y))) / 2;
        return if (pointInEvenOddF(self.covered, cx, cy)) .empty else .full;
    }
};

/// Does segment a→b intersect the axis-aligned box (interior or boundary)?
fn segIntersectsBox(a: Pt, b: Pt, box: Box) bool {
    // Trivial accept: an endpoint inside the box.
    if (inBox(a, box) or inBox(b, box)) return true;
    // Otherwise test the segment against the four box edges.
    const c0: Pt = .{ .x = box.min_x, .y = box.min_y };
    const c1: Pt = .{ .x = box.max_x, .y = box.min_y };
    const c2: Pt = .{ .x = box.max_x, .y = box.max_y };
    const c3: Pt = .{ .x = box.min_x, .y = box.max_y };
    if (boolean.segIntersect(a, b, c0, c1).n != 0) return true;
    if (boolean.segIntersect(a, b, c1, c2).n != 0) return true;
    if (boolean.segIntersect(a, b, c2, c3).n != 0) return true;
    if (boolean.segIntersect(a, b, c3, c0).n != 0) return true;
    return false;
}

fn inBox(p: Pt, box: Box) bool {
    return p.x >= box.min_x and p.x <= box.max_x and p.y >= box.min_y and p.y <= box.max_y;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn boxPoly(a: Allocator, x0: i64, y0: i64, x1: i64, y1: i64) !Poly {
    const ring = try a.alloc(Pt, 4);
    ring[0] = .{ .x = x0, .y = y0 };
    ring[1] = .{ .x = x1, .y = y0 };
    ring[2] = .{ .x = x1, .y = y1 };
    ring[3] = .{ .x = x0, .y = y1 };
    const rings = try a.alloc([]const Pt, 1);
    rings[0] = ring;
    return rings;
}

test "ownedAtTier: finest cell wins the overlap, coarse keeps the remainder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Coarse cell covers [0,100]²; fine cell covers [40,60]² inside it.
    const coarse_cov = try boxPoly(a, 0, 0, 100, 100);
    const fine_cov = try boxPoly(a, 40, 40, 60, 60);
    const cells = [_]Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse_cov} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 0, .cov1 = &.{fine_cov} },
    };

    // Tier 13: both eligible → fine owns its box, coarse owns the rest (a hole).
    const t13 = try ownedAtTier(a, &cells, 13);
    var fine_owns: bool = false;
    var coarse_owns_hole: bool = false;
    for (t13) |oc| {
        if (cells[oc.index].cscl == 20_000) {
            fine_owns = boolean.pointInEvenOdd(oc.owned, 50, 50);
        } else {
            coarse_owns_hole = boolean.pointInEvenOdd(oc.owned, 10, 10) and !boolean.pointInEvenOdd(oc.owned, 50, 50);
        }
    }
    try testing.expect(fine_owns);
    try testing.expect(coarse_owns_hole);
}

test "ownedAtTier: below-floor fine cell drops out of the pool (no blank window)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const coarse_cov = try boxPoly(a, 0, 0, 100, 100);
    const fine_cov = try boxPoly(a, 40, 40, 60, 60);
    const cells = [_]Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse_cov} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 0, .cov1 = &.{fine_cov} },
    };

    // Tier 10: fine cell is below its floor (13) → not in the pool → the coarse
    // cell owns the whole basin, including (50,50). This is the per-tier fix.
    const t10 = try ownedAtTier(a, &cells, 10);
    try testing.expectEqual(@as(usize, 1), t10.len);
    try testing.expectEqual(@as(i32, 100_000), cells[t10[0].index].cscl);
    try testing.expect(boolean.pointInEvenOdd(t10[0].owned, 50, 50));
    try testing.expect(boolean.pointInEvenOdd(t10[0].owned, 10, 10));
}

test "fuzz: partition == per-point finest-eligible-covering, zero overlap, zero gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0xDECAFBAD);
    const rnd = prng.random();
    const grid: i64 = 64;

    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        const ncells = rnd.intRangeAtMost(usize, 1, 5);
        var cells = std.ArrayList(Cell).empty;
        var bboxes = std.ArrayList([4]i64).empty;
        for (0..ncells) |k| {
            const x0 = rnd.intRangeAtMost(i64, -6, 4) * grid;
            const y0 = rnd.intRangeAtMost(i64, -6, 4) * grid;
            const w = rnd.intRangeAtMost(i64, 1, 6) * grid;
            const h = rnd.intRangeAtMost(i64, 1, 6) * grid;
            const cov = try boxPoly(a, x0, y0, x0 + w, y0 + h);
            const covs = try a.alloc(Poly, 1);
            covs[0] = cov;
            // Distinct cscl per cell so finest-covering is unambiguous.
            try cells.append(a, .{
                .cscl = @intCast(1000 + k * 100),
                .band_floor = rnd.intRangeAtMost(u8, 0, 13),
                .order = k,
                .cov1 = covs,
            });
            try bboxes.append(a, .{ x0, y0, x0 + w, y0 + h });
        }
        const tier = rnd.intRangeAtMost(u8, 0, 13);
        const owned = try ownedAtTier(a, cells.items, tier);

        var qy: i64 = -7 * grid;
        while (qy <= 11 * grid) : (qy += 19) {
            var qx: i64 = -7 * grid;
            while (qx <= 11 * grid) : (qx += 19) {
                // Reference: finest (smallest cscl) eligible cell whose bbox covers.
                var best: ?usize = null;
                for (cells.items, 0..) |c, i| {
                    if (c.band_floor > tier) continue;
                    const bb = bboxes.items[i];
                    if (qx >= bb[0] and qx <= bb[2] and qy >= bb[1] and qy <= bb[3]) {
                        if (best == null or c.cscl < cells.items[best.?].cscl) best = i;
                    }
                }
                // Skip points on any bbox edge (even-odd ambiguity).
                var on_edge = false;
                for (bboxes.items) |bb| {
                    if ((qx == bb[0] or qx == bb[2]) and qy >= bb[1] and qy <= bb[3]) on_edge = true;
                    if ((qy == bb[1] or qy == bb[3]) and qx >= bb[0] and qx <= bb[2]) on_edge = true;
                }
                if (on_edge) continue;

                // Which owned region contains the point? Must be exactly the ref.
                var owners: usize = 0;
                var owner_cell: ?usize = null;
                for (owned) |oc| {
                    if (boolean.pointInEvenOdd(oc.owned, qx, qy)) {
                        owners += 1;
                        owner_cell = oc.index;
                    }
                }
                if (owners > 1) {
                    std.debug.print("OVERLAP trial={} at ({},{}) owners={}\n", .{ trial, qx, qy, owners });
                    return error.PartitionOverlap;
                }
                if (best == null) {
                    try testing.expectEqual(@as(usize, 0), owners);
                } else {
                    if (owners != 1 or owner_cell.? != best.?) {
                        std.debug.print("MISMATCH trial={} at ({},{}) ref_cell={?} owner={?}\n", .{ trial, qx, qy, best, owner_cell });
                        return error.PartitionMismatch;
                    }
                }
            }
        }
        _ = arena.reset(.retain_capacity);
    }
}

test "clipLineOutsidePolys: keeps the outside, drops the covered middle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const covered = try boxPoly(a, 40, -10, 60, 10); // covers x∈[40,60] on the y=0 line
    const line = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const runs = try clipLineOutsidePolys(a, &line, covered);
    // Expect two runs: [0,40] and [60,100].
    try testing.expectEqual(@as(usize, 2), runs.len);
    var saw_left = false;
    var saw_right = false;
    for (runs) |r| {
        const x0 = r[0].x;
        const x1 = r[r.len - 1].x;
        if (@min(x0, x1) == 0 and @max(x0, x1) == 40) saw_left = true;
        if (@min(x0, x1) == 60 and @max(x0, x1) == 100) saw_right = true;
    }
    try testing.expect(saw_left);
    try testing.expect(saw_right);
}

test "clipLineOutsidePolys: fully-covered line yields nothing; fully-outside line is kept whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const covered = try boxPoly(a, -10, -10, 200, 10);
    const inside = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const in_runs = try clipLineOutsidePolys(a, &inside, covered);
    try testing.expectEqual(@as(usize, 0), in_runs.len);

    const cov2 = try boxPoly(a, 500, 500, 600, 600);
    const outside = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 50 } };
    const out_runs = try clipLineOutsidePolys(a, &outside, cov2);
    try testing.expectEqual(@as(usize, 1), out_runs.len);
    try testing.expectEqual(@as(usize, 3), out_runs[0].len);
}

// Clip every coverage feature of a cell to `box` (a quadrant), dropping empties —
// the operation the quadrant-partitioned Stage 0 applies before computing a
// quadrant's partition locally.
fn clipCellToBox(a: Allocator, cell: Cell, box: Box) !Cell {
    const bp = try boxPoly(a, box.min_x, box.min_y, box.max_x, box.max_y);
    var c1 = std.ArrayList(Poly).empty;
    for (cell.cov1) |f| {
        const r = try boolean.compute(a, f, bp, .intersect);
        if (r.len > 0) try c1.append(a, r);
    }
    var c2 = std.ArrayList(Poly).empty;
    for (cell.cov2) |f| {
        const r = try boolean.compute(a, f, bp, .intersect);
        if (r.len > 0) try c2.append(a, r);
    }
    return .{
        .cscl = cell.cscl,
        .band_floor = cell.band_floor,
        .order = cell.order,
        .cov1 = try c1.toOwnedSlice(a),
        .cov2 = try c2.toOwnedSlice(a),
    };
}

test "quadrant-split partition stitches to the same result (shared integer grid)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0x9042BEEF);
    const rnd = prng.random();
    const grid: i64 = 64;
    // Split seam on the integer grid; cell coords are grid multiples so coverage
    // edges meeting the seam collapse to exact equality.
    const sx: i64 = 0;
    const sy: i64 = 0;

    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        const ncells = rnd.intRangeAtMost(usize, 1, 4);
        var cells = std.ArrayList(Cell).empty;
        for (0..ncells) |k| {
            const x0 = rnd.intRangeAtMost(i64, -6, 4) * grid;
            const y0 = rnd.intRangeAtMost(i64, -6, 4) * grid;
            const w = rnd.intRangeAtMost(i64, 1, 6) * grid;
            const h = rnd.intRangeAtMost(i64, 1, 6) * grid;
            const covs = try a.alloc(Poly, 1);
            covs[0] = try boxPoly(a, x0, y0, x0 + w, y0 + h);
            try cells.append(a, .{ .cscl = @intCast(1000 + k * 100), .band_floor = 0, .order = k, .cov1 = covs });
        }
        const tier: u8 = 13;
        const whole = try ownedAtTier(a, cells.items, tier);

        // Four quadrants around (sx,sy), each computed independently.
        const lo: i64 = -9 * grid;
        const hi: i64 = 12 * grid;
        const quads = [_]Box{
            .{ .min_x = lo, .min_y = lo, .max_x = sx, .max_y = sy },
            .{ .min_x = sx, .min_y = lo, .max_x = hi, .max_y = sy },
            .{ .min_x = lo, .min_y = sy, .max_x = sx, .max_y = hi },
            .{ .min_x = sx, .min_y = sy, .max_x = hi, .max_y = hi },
        };
        var quad_owned: [4][]OwnedCell = undefined;
        for (quads, 0..) |qbox, qi| {
            var qcells = std.ArrayList(Cell).empty;
            for (cells.items) |c| try qcells.append(a, try clipCellToBox(a, c, qbox));
            quad_owned[qi] = try ownedAtTier(a, qcells.items, tier);
        }

        // A point strictly inside a quadrant must have the same owner both ways.
        var qy: i64 = lo + 7;
        while (qy <= hi - 7) : (qy += 21) {
            var qx: i64 = lo + 7;
            while (qx <= hi - 7) : (qx += 21) {
                if (qx == sx or qy == sy) continue; // avoid the seam itself
                const qi: usize = (if (qx > sx) @as(usize, 1) else 0) + (if (qy > sy) @as(usize, 2) else 0);
                var whole_owner: ?usize = null;
                for (whole) |oc| {
                    if (boolean.pointInEvenOdd(oc.owned, qx, qy)) whole_owner = oc.index;
                }
                var quad_owner: ?usize = null;
                for (quad_owned[qi]) |oc| {
                    if (boolean.pointInEvenOdd(oc.owned, qx, qy)) quad_owner = oc.index;
                }
                try testing.expectEqual(whole_owner, quad_owner);
            }
        }
        _ = arena.reset(.retain_capacity);
    }
}

test "EdgeGrid.classify matches a brute-force verdict over random tiles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rnd = prng.random();
    const grid: i64 = 64;

    var trial: usize = 0;
    while (trial < 300) : (trial += 1) {
        // Covered = a union of a couple of boxes (a clean simple region).
        const b0 = try boxPoly(a, 0, 0, 300, 300);
        const b1 = try boxPoly(a, 200, 200, 500, 500);
        const covered = try boolean.unionAll(a, &.{ b0, b1 });

        var g = try EdgeGrid.init(testing.allocator, covered, grid);
        defer g.deinit();

        var t: usize = 0;
        while (t < 40) : (t += 1) {
            const x0 = rnd.intRangeAtMost(i64, -100, 500);
            const y0 = rnd.intRangeAtMost(i64, -100, 500);
            const s = rnd.intRangeAtMost(i64, 8, 120);
            const box: Box = .{ .min_x = x0, .min_y = y0, .max_x = x0 + s, .max_y = y0 + s };

            const got = g.classify(box);
            // Brute-force reference verdict.
            var crosses = false;
            for (covered) |ring| {
                var j = ring.len - 1;
                for (ring, 0..) |p, k| {
                    const q = ring[j];
                    j = k;
                    if (segIntersectsBox(q, p, box)) crosses = true;
                }
            }
            const cx = (@as(f64, @floatFromInt(box.min_x)) + @as(f64, @floatFromInt(box.max_x))) / 2;
            const cy = (@as(f64, @floatFromInt(box.min_y)) + @as(f64, @floatFromInt(box.max_y))) / 2;
            const ref: Verdict = if (crosses) .seam else if (pointInEvenOddF(covered, cx, cy)) .empty else .full;
            try testing.expectEqual(ref, got);
        }
        _ = arena.reset(.retain_capacity);
    }
}
