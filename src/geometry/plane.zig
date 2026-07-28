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
//! Scope: this computes and validates the partition, the tile classifier
//! (FULL / EMPTY / SEAM), and the coverage line clips. The S-57 adapter (filling
//! `Cell` from an `s57.Cell`, incl. the cscl≤0 and date-order tie-break policy)
//! lives with the consumers; `Cell` is deliberately decoupled so this stays pure
//! and unit-testable.

const std = @import("std");
const builtin = @import("builtin");
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
    /// a double-owned strip. Lower sorts finer (earlier in the walk).
    order: u64,
    /// Highest zoom this cell can EMIT tiles at (native window + overscale fill-up);
    /// the cell is excluded from tiers beyond it. Its face there is dead weight — it
    /// renders nothing there — and the exclusion is invisible to every renderable
    /// face: the builders apply an EFFECTIVE reach (the max of the cell's own and
    /// every coarser cell's, so exclusions always drop a suffix of the finest→
    /// coarsest walk and no kept cell's subtrahend changes — see the reach cut in
    /// `ownedAtTier`). What it buys: the partition skips the expensive coarse-cell
    /// booleans at fine tiers (a whole-district compose spent GBs subtracting
    /// hundreds of harbour coverages from an overview cell that could never draw
    /// there). Must be a true upper bound on the cell's emit zoom; the default (255)
    /// never excludes — pure-geometry callers keep the full pool per tier.
    reach: u8 = 255,
    /// CATCOV=1 coverage features.
    cov1: []const Poly,
    /// CATCOV=2 explicit no-data features (subtracted, so a coarser band can fill).
    cov2: []const Poly = &.{},
    /// Sector-figure reach (the archive's "light_reach" metadata): union bbox
    /// [w,s,e,n] in DEGREES of the cell's figure-constructing light anchors, and
    /// the max ground-length directional leg in metres. The compositor consults
    /// the cell in tiles this ring touches even when it owns no ground there, so
    /// legs/arcs don't amputate at the tile boundary. null = no figures. Carried
    /// beside the partition inputs (never serialized — it rides the live cells).
    light_bbox: ?[4]f64 = null,
    light_range_m: f64 = 0,
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

/// The reach cap: shrink `order` (sorted finest→coarsest) to the cells whose
/// EFFECTIVE reach covers `tier`. Removing a cell only grows the faces of cells
/// AFTER it in the walk (their subtrahend shrinks), and a grown face is sound only
/// if that cell cannot render at this tier either — so the cut must be a SUFFIX of
/// the walk. Per-cell reach values need not be monotone in the sort key (a
/// scale-less cell sorts finest yet gets a mid-band default; a foreign archive can
/// carry tiles past its band window), so each cell's effective reach is the max of
/// its own and every coarser cell's: the drop is a suffix by construction, and
/// raising reach only KEEPS more cells, so nothing that could emit is ever cut.
fn reachCut(cells: []const Cell, order: *std.ArrayList(usize), tier: u8) void {
    var keep = order.items.len;
    var eff: u8 = 0;
    while (keep > 0) {
        eff = @max(eff, cells[order.items[keep - 1]].reach);
        if (tier <= eff) break;
        keep -= 1;
    }
    order.shrinkRetainingCapacity(keep);
}

/// The per-tier partition: for every cell eligible at `tier` (band_floor ≤ tier ≤
/// reach), walking finest→coarsest, `owned = coverage \ (∪ coverage of all finer
/// eligible cells)`. The union of the returned `owned` regions equals the union of
/// all eligible coverages, partitioned with no overlap (validated by the tests).
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
    reachCut(cells, &order, tier);

    // Fill-up gap-fillers: FINER cells (band_floor > tier) own ground at this
    // coarser tier only where NO eligible cell covers — appended after every
    // eligible cell, so they can never take ground from the band's own cells
    // (position in `order` is priority: each cell's face is its coverage minus
    // every earlier cell's). Among the fillers the COARSEST wins (closest to
    // this tier's display scale), equal scales by the usual tie-break. So a
    // harbor-only region still has an owner at z4, scamin-thinned by the bake.
    const n_eligible = order.items.len;
    for (cells, 0..) |c, i| {
        if (c.band_floor > tier) try order.append(gpa, i);
    }
    std.mem.sort(usize, order.items[n_eligible..], cells, struct {
        fn lt(cs: []const Cell, ia: usize, ib: usize) bool {
            if (cs[ia].cscl != cs[ib].cscl) return cs[ia].cscl > cs[ib].cscl; // coarsest first
            return cs[ia].order < cs[ib].order;
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

    for (order.items, 0..) |i, k| {
        const cov = try cellCoverage(sa, cells[i]);
        // owned = cov \ covered, allocated in gpa (the kept result).
        const owned = if (covered.len == 0)
            try dupePolygonGpa(gpa, cov)
        else
            try boolean.compute(gpa, cov, covered, .diff);
        // A gap-filler fully covered by the eligible cells owns nothing here —
        // drop its empty face so a nested finer cell adds no face at all.
        if (k >= n_eligible and owned.len == 0) {
            boolean.freePolygon(gpa, owned);
        } else {
            try out.append(gpa, .{ .index = i, .owned = owned });
        }

        // covered ∪= cov (scratch).
        const merged = try boolean.compute(sa, covered, cov, .unite);
        covered = merged;
    }
    return out.toOwnedSlice(gpa);
}

fn polyBbox(rings: []const []const Pt) [4]i64 {
    var b = [4]i64{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) };
    for (rings) |ring| for (ring) |p| {
        b[0] = @min(b[0], p.x);
        b[1] = @min(b[1], p.y);
        b[2] = @max(b[2], p.x);
        b[3] = @max(b[3], p.y);
    };
    return b;
}

fn bboxOverlap(a: [4]i64, b: [4]i64) bool {
    return a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3];
}

/// For each order position k: the ascending positions j<k whose bbox overlaps
/// k's — the cell's diff subtrahends, in application order. A uniform grid over
/// the bboxes makes enumeration output-sensitive instead of the O(m²) all-pairs
/// scan; the lists are IDENTICAL to that scan's (asserted by the test below),
/// so the diff chains — and their bytes — are unchanged.
pub fn subtrahendLists(sa: Allocator, bbs: []const [4]i64) ![]const []const u32 {
    const m = bbs.len;
    const lists = try sa.alloc([]const u32, m);
    for (lists) |*l| l.* = &.{};
    if (m == 0) return lists;

    // Data extent over valid bboxes. A cell whose coverage emptied has an
    // inverted bbox: it overlaps nothing and nothing overlaps it — skipped on
    // insert, and its own query yields the empty list, exactly like the scan.
    var ext = [4]i64{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) };
    var any = false;
    for (bbs) |b| {
        if (b[0] > b[2] or b[1] > b[3]) continue;
        any = true;
        ext[0] = @min(ext[0], b[0]);
        ext[1] = @min(ext[1], b[1]);
        ext[2] = @max(ext[2], b[2]);
        ext[3] = @max(ext[3], b[3]);
    }
    if (!any) return lists;

    // ~256 buckets per axis. A cell spanning more than 64 buckets per axis
    // (an overview cell over the whole extent) would flood thousands of
    // buckets; it goes on the linear whale list instead — there are few, and
    // they overlap nearly everything anyway.
    const GRID: i64 = 256;
    const OVERSIZE: i64 = 64;
    const cw = @max(1, @divTrunc(ext[2] - ext[0], GRID) + 1);
    const ch = @max(1, @divTrunc(ext[3] - ext[1], GRID) + 1);

    var buckets = std.AutoHashMap([2]i32, std.ArrayList(u32)).init(sa);
    var whales = std.ArrayList(u32).empty;

    for (bbs, 0..) |b, k| {
        if (b[0] > b[2] or b[1] > b[3]) continue;
        const gx0 = @divFloor(b[0] - ext[0], cw);
        const gx1 = @divFloor(b[2] - ext[0], cw);
        const gy0 = @divFloor(b[1] - ext[1], ch);
        const gy1 = @divFloor(b[3] - ext[1], ch);
        if (gx1 - gx0 > OVERSIZE or gy1 - gy0 > OVERSIZE) {
            try whales.append(sa, @intCast(k));
            continue;
        }
        var gy = gy0;
        while (gy <= gy1) : (gy += 1) {
            var gx = gx0;
            while (gx <= gx1) : (gx += 1) {
                const gop = try buckets.getOrPut(.{ @intCast(gx), @intCast(gy) });
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
                try gop.value_ptr.append(sa, @intCast(k));
            }
        }
    }

    // Generation-stamped dedup across the buckets one query touches.
    const stamp = try sa.alloc(u32, m);
    @memset(stamp, 0);
    var gen: u32 = 0;
    var hits = std.ArrayList(u32).empty;

    for (bbs, 0..) |b, k| {
        if (b[0] > b[2] or b[1] > b[3]) continue;
        hits.clearRetainingCapacity();
        const gx0 = @divFloor(b[0] - ext[0], cw);
        const gx1 = @divFloor(b[2] - ext[0], cw);
        const gy0 = @divFloor(b[1] - ext[1], ch);
        const gy1 = @divFloor(b[3] - ext[1], ch);
        if (gx1 - gx0 > OVERSIZE or gy1 - gy0 > OVERSIZE) {
            // A whale's own query would walk most buckets anyway — plain scan.
            for (0..k) |j| {
                if (bboxOverlap(bbs[j], b)) try hits.append(sa, @intCast(j));
            }
        } else {
            gen += 1;
            // Whale and bucket lists are both ascending in k: prefix cut at k.
            for (whales.items) |j| {
                if (j >= k) break;
                if (bboxOverlap(bbs[j], b)) {
                    stamp[j] = gen;
                    try hits.append(sa, j);
                }
            }
            var gy = gy0;
            while (gy <= gy1) : (gy += 1) {
                var gx = gx0;
                while (gx <= gx1) : (gx += 1) {
                    const bucket = buckets.get(.{ @intCast(gx), @intCast(gy) }) orelse continue;
                    for (bucket.items) |j| {
                        if (j >= k) break;
                        if (stamp[j] != gen and bboxOverlap(bbs[j], b)) {
                            stamp[j] = gen;
                            try hits.append(sa, j);
                        }
                    }
                }
            }
            std.mem.sort(u32, hits.items, {}, comptime std.sort.asc(u32));
        }
        lists[k] = try sa.dupe(u32, hits.items);
    }
    return lists;
}

/// Monotonic ns for the TILE57_PARTITION_STATS harness — a dev tool; plane has
/// no std.Io handle, so posix, and 0 where that clock doesn't exist.
pub fn statNow() u64 {
    if (builtin.os.tag == .windows) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Worker count for the parallel partition passes. Overridable because the
/// passes' correctness claim IS that they serialize byte-identically to a
/// serial run, and checking that means forcing both over the same input.
fn workerCount(m: usize) usize {
    if (std.c.getenv("TILE57_PARTITION_WORKERS")) |w| {
        if (std.fmt.parseInt(usize, std.mem.sliceTo(w, 0), 10) catch null) |n|
            return @max(1, @min(n, 64));
    }
    if (m < 64) return 1; // not worth the threads
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(cpus, 8));
}

/// Every cell's coverage (∪cov1 \ ∪cov2) and its bbox, keyed by GLOBAL cell
/// index. Coverage is tier-invariant, so the multi-tier build computes it once
/// here instead of once per tier. Ring geometry lives in per-worker arenas over
/// the page allocator; the slices live in `gpa`. Free with `deinit`.
pub const CoverageIndex = struct {
    covs: []Poly,
    bbs: [][4]i64,
    arenas: []std.heap.ArenaAllocator,

    pub fn deinit(self: *CoverageIndex, gpa: Allocator) void {
        for (self.arenas) |*ar| ar.deinit();
        gpa.free(self.arenas);
        gpa.free(self.covs);
        gpa.free(self.bbs);
    }
};

pub fn buildCoverageIndex(gpa: Allocator, cells: []const Cell) !CoverageIndex {
    const stats = std.c.getenv("TILE57_PARTITION_STATS") != null;
    const t0 = if (stats) statNow() else 0;

    const n = cells.len;
    const covs = try gpa.alloc(Poly, n);
    errdefer gpa.free(covs);
    const bbs = try gpa.alloc([4]i64, n);
    errdefer gpa.free(bbs);

    const workers = workerCount(n);
    const arenas = try gpa.alloc(std.heap.ArenaAllocator, workers);
    for (arenas) |*ar| ar.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer {
        for (arenas) |*ar| ar.deinit();
        gpa.free(arenas);
    }

    var next = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);

    const Job = struct {
        cells: []const Cell,
        covs: []Poly,
        bbs: [][4]i64,
        arenas: []std.heap.ArenaAllocator,
        next: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),

        fn run(j: *const @This(), w: usize) void {
            // The worker's own arena: the caller's allocator may be an arena
            // and is not required to be thread-safe.
            const ka = j.arenas[w].allocator();
            while (true) {
                const i = j.next.fetchAdd(1, .monotonic);
                if (i >= j.cells.len) return;
                if (j.failed.load(.acquire)) return;
                const cov = cellCoverage(ka, j.cells[i]) catch
                    return j.failed.store(true, .release);
                j.covs[i] = cov;
                j.bbs[i] = polyBbox(cov);
            }
        }
    };

    const job = Job{ .cells = cells, .covs = covs, .bbs = bbs, .arenas = arenas, .next = &next, .failed = &failed };
    {
        var threads: [63]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        while (spawned < workers - 1) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, Job.run, .{ &job, spawned + 1 }) catch break;
        }
        job.run(0); // this thread takes a share too
    }
    if (failed.load(.acquire)) return error.OutOfMemory;

    if (stats) std.debug.print("partition coverage index: {d} cells workers={d} {d:.0} ms\n", .{
        n, workers, @as(f64, @floatFromInt(statNow() - t0)) / 1e6,
    });
    return .{ .covs = covs, .bbs = bbs, .arenas = arenas };
}

/// Identical result to `ownedAtTier`, built for scale. `ownedAtTier` accumulates a
/// GLOBAL union of every finer cell and differences each cell against it — the
/// operands grow to the whole nation, so it is O(cells²) in operand size (a
/// national district takes seconds). Here each cell is differenced only against
/// the finer eligible cells whose bounding box OVERLAPS it. A finer cell whose
/// bbox is disjoint cannot remove any area, so the result is the same partition
/// (cross-checked by the test below); charts overlap locally, so the per-cell
/// subtrahend stays small. Use this variant for real ENC data.
pub fn ownedAtTierIndexed(gpa: Allocator, cells: []const Cell, tier: u8) ![]OwnedCell {
    var idx = try buildCoverageIndex(gpa, cells);
    defer idx.deinit(gpa);
    return ownedAtTierWithIndex(gpa, cells, tier, &idx);
}

/// `ownedAtTierIndexed` with the coverage precomputed — the multi-tier caller
/// (`partition.build`) shares one CoverageIndex across every tier.
pub fn ownedAtTierWithIndex(gpa: Allocator, cells: []const Cell, tier: u8, idx: *const CoverageIndex) ![]OwnedCell {
    return ownedAtTierImpl(gpa, cells, tier, idx, null, null);
}

/// Cross-tier face reuse. A face is a pure function of the cell's own coverage
/// (tier-invariant, shared via the CoverageIndex) and its ordered subtrahend
/// list AS GLOBAL INDICES: if a later tier produces the same list for the same
/// cell, the diff chain — and therefore the face bytes — is identical, so the
/// earlier face is duped instead of recomputed.
const ReuseCtx = struct {
    /// Build-lifetime storage for the cached lists.
    arena: Allocator,
    /// Per GLOBAL cell index: one entry per distinct subtrahend list seen.
    caches: []std.ArrayList(Entry),
    /// Faces of the tiers already built (gpa memory, owned by the caller).
    prior: *std.ArrayList([]OwnedCell),
    /// Index of the tier being built, into `prior` once it lands there.
    cur_tier: u32 = 0,
    hits: u64 = 0,

    const Entry = struct {
        hash: u64,
        glist: []const u32,
        tier_idx: u32,
        /// Slot in that tier's faces, or -1: the face was empty and dropped
        /// (a fully-covered gap-filler).
        slot: i32,
    };
};

/// Sidecar adoption. A stored face carries a digest of everything its diff
/// chain read — its own cell's content and every subtrahend's, in order. If a
/// cell's CURRENT face input digest matches a stored one, the stored geometry
/// IS what the sweep would recompute, and is adopted verbatim.
pub const AdoptCtx = struct {
    /// Per GLOBAL cell index: identity-stable content digest
    /// (partition.contentDigest — no order rank, it shifts under insertion).
    digests: []const u64,
    /// (global cell index, face input digest) → geometry to adopt. An empty
    /// Poly is a real entry: the face was empty (a fully-covered gap-filler).
    pool: std.AutoHashMap(PoolKey, Poly),
    adopted: u64 = 0,
    /// Face slots that ran a diff chain — neither adopted nor tier-reused.
    /// Zero ⇒ the sidecar already IS this partition.
    swept: u64 = 0,

    pub const PoolKey = struct { ci: u32, fdig: u64 };
};

/// The digest a face's diff chain is a pure function of: own content digest,
/// then each subtrahend's, in application order.
pub fn faceInputDigest(digests: []const u64, ci: usize, glist: []const u32) u64 {
    var h = std.hash.Wyhash.init(0x7457_4644_4947_5354); // face-digest seed
    h.update(std.mem.asBytes(&digests[ci]));
    for (glist) |g| h.update(std.mem.asBytes(&digests[g]));
    return h.final();
}

const HitSrc = union(enum) {
    /// A face already built at an earlier tier of this run.
    prior: struct { tier_idx: u32, slot: i32 },
    /// A face adopted verbatim from a sidecar (borrowed; duped on assembly).
    ext: Poly,
};

/// One tier's walk: every cell in priority order (position IS priority), and
/// how many lead it as eligible. Eligible cells (band_floor ≤ tier, surviving
/// the reach cut) come first, finest→coarsest; then the fill-up gap-fillers —
/// FINER cells (band_floor > tier) that own ground at this coarser tier only
/// where NO eligible cell covers. Among the fillers the COARSEST wins (closest
/// to this tier's display scale), equal scales by the usual tie-break. So a
/// harbor-only region still has an owner at z4, scamin-thinned by the bake.
/// The serializer re-derives face digests through this same walk.
pub const TierWalk = struct { order: []usize, n_eligible: usize };

pub fn tierWalk(a: Allocator, cells: []const Cell, tier: u8) !TierWalk {
    var order = std.ArrayList(usize).empty;
    errdefer order.deinit(a);
    for (cells, 0..) |c, i| {
        if (c.band_floor <= tier) try order.append(a, i);
    }
    std.mem.sort(usize, order.items, cells, struct {
        fn lt(cs: []const Cell, ia: usize, ib: usize) bool {
            return finerLess({}, cs[ia], cs[ib]);
        }
    }.lt);
    reachCut(cells, &order, tier);

    const n_eligible = order.items.len;
    for (cells, 0..) |c, i| {
        if (c.band_floor > tier) try order.append(a, i);
    }
    std.mem.sort(usize, order.items[n_eligible..], cells, struct {
        fn lt(cs: []const Cell, ia: usize, ib: usize) bool {
            if (cs[ia].cscl != cs[ib].cscl) return cs[ia].cscl > cs[ib].cscl; // coarsest first
            return cs[ia].order < cs[ib].order;
        }
    }.lt);
    return .{ .order = try order.toOwnedSlice(a), .n_eligible = n_eligible };
}

fn ownedAtTierImpl(gpa: Allocator, cells: []const Cell, tier: u8, idx: *const CoverageIndex, reuse: ?*ReuseCtx, adopt: ?*AdoptCtx) ![]OwnedCell {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const walk = try tierWalk(sa, cells, tier);
    const order = walk.order;
    const n_eligible = walk.n_eligible;

    // TILE57_PARTITION_STATS=1: per-tier phase timings + worst per-cell diff
    // chains, for aiming optimization work at what the profile actually says.
    const stats = std.c.getenv("TILE57_PARTITION_STATS") != null;

    // Order-position views into the shared index (the sweep addresses cells by
    // their position in this tier's walk).
    const m = order.len;
    const covs = try sa.alloc(Poly, m);
    const bbs = try sa.alloc([4]i64, m);
    for (order, 0..) |ci, k| {
        covs[k] = idx.covs[ci];
        bbs[k] = idx.bbs[ci];
    }

    const t_lists0 = if (stats) statNow() else 0;
    const lists = try subtrahendLists(sa, bbs);
    const lists_ns = if (stats) statNow() - t_lists0 else 0;

    // Reuse/adoption lookup: rewrite each list to global indices, hash it, and
    // match it (a) against the cell's lists from earlier tiers, (b) against the
    // sidecar adoption pool by face input digest. Either hit skips the sweep
    // for that cell entirely; only misses go on the todo list.
    var hitv: []?HitSrc = &.{};
    var glists: [][]u32 = &.{};
    var hashes: []u64 = &.{};
    if (reuse != null or adopt != null) {
        hitv = try sa.alloc(?HitSrc, m);
        @memset(hitv, null);
        glists = try sa.alloc([]u32, m);
        hashes = try sa.alloc(u64, m);
    }
    var todo = std.ArrayList(u32).empty;
    if (reuse != null or adopt != null) {
        var reuse_hits: u64 = 0;
        for (0..m) |k| {
            const ci = order[k];
            const gl = try sa.alloc(u32, lists[k].len);
            for (lists[k], 0..) |j, x| gl[x] = @intCast(order[j]);
            glists[k] = gl;
            hashes[k] = std.hash.Wyhash.hash(0x7457_5245, std.mem.sliceAsBytes(gl));
            if (reuse) |rc| {
                for (rc.caches[ci].items) |e| {
                    if (e.hash == hashes[k] and std.mem.eql(u32, e.glist, gl)) {
                        hitv[k] = .{ .prior = .{ .tier_idx = e.tier_idx, .slot = e.slot } };
                        reuse_hits += 1;
                        break;
                    }
                }
            }
            if (hitv[k] == null) if (adopt) |ac| {
                if (ac.pool.get(.{ .ci = @intCast(ci), .fdig = faceInputDigest(ac.digests, ci, gl) })) |face| {
                    hitv[k] = .{ .ext = face };
                    ac.adopted += 1;
                }
            };
            if (hitv[k] == null) try todo.append(sa, @intCast(k));
        }
        if (reuse) |rc| rc.hits += reuse_hits;
        if (adopt) |ac| ac.swept += todo.items.len;
    } else {
        try todo.ensureTotalCapacity(sa, m);
        for (0..m) |k| todo.appendAssumeCapacity(@intCast(k));
    }

    // Claim order = longest chain first. A chain's cost tracks its subtrahend
    // count, and the count is known up front now — better than the coarse-end
    // heuristic at keeping a whale off one worker's tail. Pure scheduling:
    // results land by index, so any deterministic order is byte-safe.
    std.mem.sort(u32, todo.items, lists, struct {
        fn lt(ls: []const []const u32, x: u32, y: u32) bool {
            if (ls[x].len != ls[y].len) return ls[x].len > ls[y].len;
            return x > y; // tie: coarse end first, as before
        }
    }.lt);

    var out = std.ArrayList(OwnedCell).empty;
    errdefer {
        for (out.items) |c| boolean.freePolygon(gpa, c.owned);
        out.deinit(gpa);
    }

    // Every cell's face is its coverage minus the coverage of the earlier cells
    // that overlap it — and `covs`/`bbs` above are INPUTS, computed for all m
    // cells before any face is. No iteration reads another's result, so the
    // whole sweep is parallel across cells. Results are placed BY INDEX and the
    // output assembled in order afterwards, so a parallel build serializes to
    // the same bytes as a serial one.
    const results = try sa.alloc(Poly, m);
    for (results) |*r| r.* = &.{};

    // Per-cell stat slots: workers write only their claimed index — race-free.
    const stat_ns: ?[]u64 = if (stats) try sa.alloc(u64, m) else null;
    const stat_nsub: ?[]u32 = if (stats) try sa.alloc(u32, m) else null;
    if (stat_ns) |v| @memset(v, 0);
    if (stat_nsub) |v| @memset(v, 0);

    const workers = workerCount(todo.items.len);

    var next = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);

    const Sweep = struct {
        covs: []const Poly,
        lists: []const []const u32,
        todo: []const u32,
        results: []Poly,
        keeps: []std.heap.ArenaAllocator,
        next: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),
        stat_ns: ?[]u64,
        stat_nsub: ?[]u32,

        fn run(s: *const @This(), w: usize) void {
            // Both arenas are the worker's own, over the page allocator: the
            // caller's allocator may be an arena and is not required to be
            // thread-safe, so nothing here may touch it. `work` holds the
            // boolean intermediates and is reset per cell — the RSS bound the
            // serial sweep relied on, now per worker. `keep` holds the finished
            // faces, which must outlive the join.
            var work = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer work.deinit();
            const ka = s.keeps[w].allocator();

            // Subtrahend pointer list, reused (cleared) each iteration — it only
            // holds borrowed pointers into `covs`, so it stays tiny.
            var subtr = std.ArrayList(Poly).empty;

            while (true) {
                // `todo` is presorted longest-chain-first; claim in order.
                const claimed = s.next.fetchAdd(1, .monotonic);
                if (claimed >= s.todo.len) return;
                const k = s.todo[claimed];
                if (s.failed.load(.acquire)) return;
                const c0 = if (s.stat_ns != null) statNow() else 0;

                subtr.clearRetainingCapacity();
                for (s.lists[k]) |j| {
                    subtr.append(ka, s.covs[j]) catch return s.failed.store(true, .release);
                }
                // A \ (B ∪ C ∪ …) = ((A \ B) \ C) \ … : sequential small diffs
                // instead of unioning every overlapping finer cell first and
                // diffing once. The pairwise-fold union grew its accumulator
                // toward whole-district size — O(N²) sweep work for a coarse
                // cell overlapped by hundreds of finer ones. Here the subject
                // only SHRINKS, every subtrahend is one cell's coverage, and a
                // subject emptied early — a gap-filler fully covered by the
                // eligible cells, the common case — exits without the rest.
                var cur: Poly = s.covs[k];
                if (subtr.items.len != 0) {
                    const wa = work.allocator();
                    for (subtr.items) |sub| {
                        cur = boolean.compute(wa, cur, sub, .diff) catch
                            return s.failed.store(true, .release);
                        if (cur.len == 0) break;
                    }
                }
                // Into `keep` before the reset below reclaims `work`.
                s.results[k] = dupePolygonGpa(ka, cur) catch
                    return s.failed.store(true, .release);
                if (s.stat_ns) |ns| {
                    ns[k] = statNow() - c0;
                    s.stat_nsub.?[k] = @intCast(subtr.items.len);
                }
                _ = work.reset(.retain_capacity); // reuse the pages next cell; no munmap
            }
        }
    };

    const keeps = try sa.alloc(std.heap.ArenaAllocator, workers);
    for (keeps) |*ka| ka.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer for (keeps) |*ka| ka.deinit();

    const sweep = Sweep{
        .covs = covs,
        .lists = lists,
        .todo = todo.items,
        .results = results,
        .keeps = keeps,
        .next = &next,
        .failed = &failed,
        .stat_ns = stat_ns,
        .stat_nsub = stat_nsub,
    };

    const t_sweep0 = if (stats) statNow() else 0;
    {
        var threads = try sa.alloc(std.Thread, workers - 1);
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        while (spawned < workers - 1) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, Sweep.run, .{ &sweep, spawned + 1 }) catch break;
        }
        sweep.run(0); // this thread takes a share too
    }
    if (failed.load(.acquire)) return error.OutOfMemory;

    if (stats) {
        const sweep_ns = statNow() - t_sweep0;
        std.debug.print("partition tier {d}: m={d} ({d} eligible, {d} reused) workers={d} lists={d:.0} ms sweep={d:.0} ms\n", .{
            tier,                                       m, n_eligible, m - todo.items.len, workers,
            @as(f64, @floatFromInt(lists_ns)) / 1e6,    @as(f64, @floatFromInt(sweep_ns)) / 1e6,
        });
        const by_ns = try sa.alloc(usize, m);
        for (by_ns, 0..) |*v, i| v.* = i;
        std.mem.sort(usize, by_ns, stat_ns.?, struct {
            fn gt(ns: []const u64, x: usize, y: usize) bool {
                return ns[x] > ns[y];
            }
        }.gt);
        for (by_ns[0..@min(m, 20)]) |k| {
            std.debug.print("  cell[{d}] {s} subs={d} diff={d:.1} ms\n", .{
                order[k],
                if (k >= n_eligible) @as([]const u8, "fill") else "elig",
                stat_nsub.?[k],
                @as(f64, @floatFromInt(stat_ns.?[k])) / 1e6,
            });
        }
    }

    for (order, 0..) |ci, k| {
        const poly: Poly = if (hitv.len != 0 and hitv[k] != null) switch (hitv[k].?) {
            // Same cell, same subtrahend content at an earlier tier or in the
            // sidecar: the diff chain is identical, so the face bytes are —
            // dupe, don't diff.
            .prior => |hs| if (hs.slot < 0)
                &.{} // was an empty (dropped) face
            else
                reuse.?.prior.items[hs.tier_idx][@intCast(hs.slot)].owned,
            .ext => |face| face,
        } else results[k];

        // A gap-filler fully covered by the eligible cells owns nothing here —
        // drop its empty face so a nested finer cell adds no face at all.
        const dropped = k >= n_eligible and poly.len == 0;
        if (!dropped) {
            const owned = try dupePolygonGpa(gpa, poly);
            out.append(gpa, .{ .index = ci, .owned = owned }) catch |e| {
                boolean.freePolygon(gpa, owned);
                return e;
            };
        }
        if (reuse) |rc| if (hitv[k] == null) {
            // First time this cell produced this list — remember the face.
            try rc.caches[ci].append(rc.arena, .{
                .hash = hashes[k],
                .glist = try rc.arena.dupe(u32, glists[k]),
                .tier_idx = rc.cur_tier,
                .slot = if (dropped) -1 else @intCast(out.items.len - 1),
            });
        };
    }
    return out.toOwnedSlice(gpa);
}

/// The whole band stack in one call: one faces slice per tier, with cross-tier
/// face reuse (see ReuseCtx). Each tier's slice has the same element semantics
/// as `ownedAtTierIndexed`; free each with `freeOwned` and the outer slice with
/// `gpa.free`. TILE57_PARTITION_NO_REUSE=1 disables the reuse path — the A/B
/// switch for proving it changes nothing.
pub fn ownedTiers(gpa: Allocator, cells: []const Cell, tiers: []const u8, idx: *const CoverageIndex) ![][]OwnedCell {
    const use_reuse = std.c.getenv("TILE57_PARTITION_NO_REUSE") == null;
    return ownedTiersOpt(gpa, cells, tiers, idx, use_reuse, null);
}

/// `ownedTiers` with a sidecar adoption pool: faces whose input digest matches
/// a pool entry are adopted verbatim instead of swept. Adoption changes only
/// HOW a face is produced, never its bytes — the pool key IS the proof.
pub fn ownedTiersAdopt(gpa: Allocator, cells: []const Cell, tiers: []const u8, idx: *const CoverageIndex, adopt: ?*AdoptCtx) ![][]OwnedCell {
    const use_reuse = std.c.getenv("TILE57_PARTITION_NO_REUSE") == null;
    return ownedTiersOpt(gpa, cells, tiers, idx, use_reuse, adopt);
}

fn ownedTiersOpt(gpa: Allocator, cells: []const Cell, tiers: []const u8, idx: *const CoverageIndex, use_reuse: bool, adopt: ?*AdoptCtx) ![][]OwnedCell {
    var prior = std.ArrayList([]OwnedCell).empty;
    errdefer {
        for (prior.items) |faces| freeOwned(gpa, faces);
        prior.deinit(gpa);
    }
    try prior.ensureTotalCapacity(gpa, tiers.len);

    var cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cache_arena.deinit();
    const ca = cache_arena.allocator();

    var rc = ReuseCtx{
        .arena = ca,
        .caches = try ca.alloc(std.ArrayList(ReuseCtx.Entry), cells.len),
        .prior = &prior,
    };
    for (rc.caches) |*c| c.* = std.ArrayList(ReuseCtx.Entry).empty;

    for (tiers, 0..) |tier, ti| {
        rc.cur_tier = @intCast(ti);
        const faces = try ownedAtTierImpl(gpa, cells, tier, idx, if (use_reuse) &rc else null, adopt);
        prior.appendAssumeCapacity(faces);
    }
    if (std.c.getenv("TILE57_PARTITION_STATS") != null and use_reuse)
        std.debug.print("partition reuse: {d} faces duped across {d} tiers\n", .{ rc.hits, tiers.len });
    return prior.toOwnedSlice(gpa);
}


fn dupePolygonGpa(gpa: Allocator, poly: Poly) ![][]Pt {
    const out = try gpa.alloc([]Pt, poly.len);
    errdefer gpa.free(out);
    var n: usize = 0;
    errdefer for (out[0..n]) |r| gpa.free(r);
    while (n < poly.len) : (n += 1) out[n] = try gpa.dupe(Pt, poly[n]);
    return out;
}

/// Sutherland–Hodgman rect clip of a ring bag: cuts boolean operands to tile
/// size in LINEAR time, so the cross-band fill's cost per tile is bounded by
/// the tile — never by the face. A tier-0 face is a whole coastal cell
/// (hundreds of thousands of points); exact booleans against it requested
/// oversized allocations that FAILED tile-by-tile on a memory-limited device,
/// at exactly the coarse zooms.
pub fn rectClipRings(a: std.mem.Allocator, rings: []const []const Pt, box: Box) ![][]Pt {
    var out = std.ArrayList([]Pt).empty;
    for (rings) |ring| {
        var cur = std.ArrayList(Pt).empty;
        try cur.appendSlice(a, ring);
        inline for (.{
            .{ .axis = 0, .lim = "min_x", .keep_ge = true },
            .{ .axis = 0, .lim = "max_x", .keep_ge = false },
            .{ .axis = 1, .lim = "min_y", .keep_ge = true },
            .{ .axis = 1, .lim = "max_y", .keep_ge = false },
        }) |cl| {
            if (cur.items.len == 0) break;
            const lim: i64 = @field(box, cl.lim);
            var nxt = std.ArrayList(Pt).empty;
            const npts = cur.items.len;
            for (cur.items, 0..) |p, k| {
                const q = cur.items[(k + 1) % npts];
                const pv: i64 = if (cl.axis == 0) p.x else p.y;
                const qv: i64 = if (cl.axis == 0) q.x else q.y;
                const pin = if (cl.keep_ge) pv >= lim else pv <= lim;
                const qin = if (cl.keep_ge) qv >= lim else qv <= lim;
                if (pin) try nxt.append(a, p);
                if (pin != qin) {
                    const t = @as(f64, @floatFromInt(lim - pv)) / @as(f64, @floatFromInt(qv - pv));
                    const ox: i64 = if (cl.axis == 0) lim else p.x + @as(i64, @intFromFloat(@round(t * @as(f64, @floatFromInt(q.x - p.x)))));
                    const oy: i64 = if (cl.axis == 1) lim else p.y + @as(i64, @intFromFloat(@round(t * @as(f64, @floatFromInt(q.y - p.y)))));
                    try nxt.append(a, .{ .x = ox, .y = oy });
                }
            }
            cur = nxt;
        }
        if (cur.items.len >= 3) try out.append(a, try cur.toOwnedSlice(a));
    }
    return out.toOwnedSlice(a);
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

/// Split `line` at every integer crossing with `covered`'s edges and keep each
/// sub-run whose midpoint is on the wanted side — INSIDE `covered` when `keep_inside`,
/// else OUTSIDE. Returns a list of poly-lines allocated in `gpa`. The line analogue of
/// a polygon intersect/difference: no polygon boolean, so a line crossing the boundary
/// is cut cleanly, not offset-doubled. `grid`, when supplied, must index exactly
/// `covered`'s edges: splits then come from the buckets near each segment and the
/// midpoint parity from the grid's ray walk, so the cost per segment is the
/// geometry NEAR it — never the whole coverage. Output is identical either way.
fn clipLineByCoverage(gpa: Allocator, line: []const Pt, covered: Poly, keep_inside: bool, grid: ?*const EdgeGrid) ![][]Pt {
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
        if (grid) |g| {
            const Gather = struct {
                sc: Allocator,
                splits: *std.ArrayList(SplitPt),
                a: Pt,
                b: Pt,
                fn each(ctx: *const @This(), e: EdgeGrid.Seg) error{OutOfMemory}!void {
                    const it = boolean.segIntersect(ctx.a, ctx.b, e.a, e.b);
                    switch (it.n) {
                        1 => try ctx.splits.append(ctx.sc, .{ .key = keyOf(it.p0, ctx.a, ctx.b), .p = it.p0 }),
                        2 => {
                            try ctx.splits.append(ctx.sc, .{ .key = keyOf(it.p0, ctx.a, ctx.b), .p = it.p0 });
                            try ctx.splits.append(ctx.sc, .{ .key = keyOf(it.p1, ctx.a, ctx.b), .p = it.p1 });
                        },
                        else => {},
                    }
                }
            };
            const g_ctx = Gather{ .sc = sc, .splits = &splits, .a = a, .b = b };
            try g.eachNearBox(.{
                .min_x = @min(a.x, b.x),
                .min_y = @min(a.y, b.y),
                .max_x = @max(a.x, b.x),
                .max_y = @max(a.y, b.y),
            }, &g_ctx, Gather.each);
        } else for (covered) |ring| {
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

        // Walk consecutive distinct split points; keep sub-runs whose midpoint is on
        // the wanted side of `covered`.
        var prev = splits.items[0].p;
        if (run.items.len == 0) try run.append(gpa, prev);
        for (splits.items[1..]) |sp| {
            const q = sp.p;
            if (q.eql(prev)) continue;
            const mx = (@as(f64, @floatFromInt(prev.x)) + @as(f64, @floatFromInt(q.x))) / 2;
            const my = (@as(f64, @floatFromInt(prev.y)) + @as(f64, @floatFromInt(q.y))) / 2;
            const mid_in = if (grid) |g| g.parityF(mx, my) else pointInEvenOddF(covered, mx, my);
            if (mid_in != keep_inside) {
                // Sub-run is on the unwanted side: flush the kept run (ends at prev), skip.
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

/// Keep the parts of `line` OUTSIDE `covered` — the parts a cell owns when `covered`
/// is the finer coverage that beats it (the seam stroke stays on the covered side).
pub fn clipLineOutsidePolys(gpa: Allocator, line: []const Pt, covered: Poly) ![][]Pt {
    return clipLineByCoverage(gpa, line, covered, false, null);
}

/// Keep the parts of `line` INSIDE `covered` — clips a cell's line features to its
/// owned face at compose time (`covered` = the cell's owned region).
pub fn clipLineInsidePolys(gpa: Allocator, line: []const Pt, covered: Poly) ![][]Pt {
    return clipLineByCoverage(gpa, line, covered, true, null);
}

/// clipLineInsidePolys with the caller's edge grid over the SAME coverage —
/// identical output, cost bounded by the geometry near the line.
pub fn clipLineInsidePolysGrid(gpa: Allocator, line: []const Pt, covered: Poly, grid: *const EdgeGrid) ![][]Pt {
    return clipLineByCoverage(gpa, line, covered, true, grid);
}

const SplitPt = struct {
    key: i128,
    p: Pt,
    // Total order: key first (position along the segment), then the point
    // itself. Two DISTINCT crossings can share a key (the key projects onto
    // the dominant axis, and near-tangent crossings collide on it) — under a
    // key-only sort their order is whatever the sort felt like, and duplicate
    // gatherings (the grid path sees an edge once per bucket it spans)
    // interleave instead of collapsing against the consecutive-equal dedup.
    fn lt(_: void, a: SplitPt, b: SplitPt) bool {
        if (a.key != b.key) return a.key < b.key;
        if (a.p.x != b.p.x) return a.p.x < b.p.x;
        return a.p.y < b.p.y;
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
    // Occupied bucket bounds, so a ray walk knows where the geometry ends.
    min_gx: i64 = std.math.maxInt(i64),
    max_gx: i64 = std.math.minInt(i64),

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
        self.min_gx = @min(self.min_gx, gx0);
        self.max_gx = @max(self.max_gx, gx1);
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

    /// Even-odd containment of a float point against the indexed coverage,
    /// equal by construction to the brute-force scan: the +x ray visits the
    /// bucket row once per column, applies the SAME per-edge crossing predicate,
    /// and counts each crossing exactly once — in the one column that contains
    /// the crossing's x (an edge spanning several buckets is seen in each, and
    /// skipped in all but that one). Touches only edges near the ray instead of
    /// every edge of the coverage.
    pub fn parityF(self: *const EdgeGrid, x: f64, y: f64) bool {
        if (self.max_gx < self.min_gx) return false; // no edges at all
        const fx: i64 = @intFromFloat(@floor(x));
        const gy = self.gridOf(@intFromFloat(@floor(y)));
        var inside = false;
        var gx = @max(self.gridOf(fx), self.min_gx);
        while (gx <= self.max_gx) : (gx += 1) {
            const list = self.buckets.get(.{ .gx = gx, .gy = gy }) orelse continue;
            for (list.items) |e| {
                const yi: f64 = @floatFromInt(e.a.y);
                const yj: f64 = @floatFromInt(e.b.y);
                if ((yi > y) == (yj > y)) continue;
                const xi: f64 = @floatFromInt(e.a.x);
                const xj: f64 = @floatFromInt(e.b.x);
                const xint = xi + (y - yi) * (xj - xi) / (yj - yi);
                if (x >= xint) continue;
                if (self.gridOf(@intFromFloat(@floor(xint))) != gx) continue;
                inside = !inside;
            }
        }
        return inside;
    }

    /// Visit every indexed edge whose bucket range meets `box`, possibly more
    /// than once (an edge lives in each bucket its bbox spans). Callers that
    /// split at intersections tolerate the duplicates — identical split points
    /// collapse in their sort — so no dedup set is paid here.
    pub fn eachNearBox(self: *const EdgeGrid, box: Box, ctx: anytype, comptime f: fn (@TypeOf(ctx), Seg) error{OutOfMemory}!void) !void {
        const gx0 = self.gridOf(box.min_x);
        const gx1 = self.gridOf(box.max_x);
        const gy0 = self.gridOf(box.min_y);
        const gy1 = self.gridOf(box.max_y);
        var gx = gx0;
        while (gx <= gx1) : (gx += 1) {
            var gy = gy0;
            while (gy <= gy1) : (gy += 1) {
                const list = self.buckets.get(.{ .gx = gx, .gy = gy }) orelse continue;
                for (list.items) |e| try f(ctx, e);
            }
        }
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

test "reach cap: a cell beyond its tile reach drops out of finer tiers only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Coarse [0,100]² can emit up to z10 (native max 9 + one fill-up); fine [40,60]²
    // is unbounded. At tier 13 the coarse cell is out of the pool — the fine cell
    // owns its box and NOTHING owns the surround; at tier 9 the coarse cell is back
    // (fine below floor) and owns the whole basin.
    const coarse_cov = try boxPoly(a, 0, 0, 100, 100);
    const fine_cov = try boxPoly(a, 40, 40, 60, 60);
    const cells = [_]Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .reach = 10, .cov1 = &.{coarse_cov} },
        .{ .cscl = 20_000, .band_floor = 13, .order = 0, .cov1 = &.{fine_cov} },
    };

    for ([_]bool{ false, true }) |indexed| {
        const t13 = if (indexed) try ownedAtTierIndexed(a, &cells, 13) else try ownedAtTier(a, &cells, 13);
        try testing.expectEqual(@as(usize, 1), t13.len);
        try testing.expectEqual(@as(usize, 1), t13[0].index); // only the fine cell
        try testing.expect(boolean.pointInEvenOdd(t13[0].owned, 50, 50));
        // The fine cell's face is its own coverage, unchanged by the exclusion —
        // it never subtracted against the (coarser) capped cell.
        try testing.expect(!boolean.pointInEvenOdd(t13[0].owned, 10, 10));

        const t9 = if (indexed) try ownedAtTierIndexed(a, &cells, 9) else try ownedAtTier(a, &cells, 9);
        try testing.expectEqual(@as(usize, 1), t9.len);
        try testing.expectEqual(@as(usize, 0), t9[0].index); // coarse back in the pool
        try testing.expect(boolean.pointInEvenOdd(t9[0].owned, 50, 50));
    }
}

test "reach cap: non-monotone reach cuts only a suffix (effective reach keeps the finer cell)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Pathological input: the FINER cell has the LOWER reach (a scale-less cell that
    // sorted finest but banded mid-ladder, or a foreign archive). Cutting it while the
    // coarser cell stays would grow the coarse face over ground the finer cell used to
    // mask — so the effective reach (max of own + all coarser) must keep it, and the
    // partition must match the uncapped one exactly.
    const coarse_cov = try boxPoly(a, 0, 0, 100, 100);
    const fine_cov = try boxPoly(a, 40, 40, 60, 60);
    const capped = [_]Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .reach = 255, .cov1 = &.{coarse_cov} },
        .{ .cscl = 20_000, .band_floor = 9, .order = 0, .reach = 10, .cov1 = &.{fine_cov} },
    };
    const uncapped = [_]Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse_cov} },
        .{ .cscl = 20_000, .band_floor = 9, .order = 0, .cov1 = &.{fine_cov} },
    };

    for ([_]bool{ false, true }) |indexed| {
        const got = if (indexed) try ownedAtTierIndexed(a, &capped, 13) else try ownedAtTier(a, &capped, 13);
        const want = if (indexed) try ownedAtTierIndexed(a, &uncapped, 13) else try ownedAtTier(a, &uncapped, 13);
        try testing.expectEqual(want.len, got.len); // both cells kept
        // Same owner at a probe point inside the fine box and one outside it.
        for ([_][2]i64{ .{ 50, 50 }, .{ 10, 10 } }) |p| {
            var want_owner: ?usize = null;
            var got_owner: ?usize = null;
            for (want) |oc| if (boolean.pointInEvenOdd(oc.owned, p[0], p[1])) {
                want_owner = oc.index;
            };
            for (got) |oc| if (boolean.pointInEvenOdd(oc.owned, p[0], p[1])) {
                got_owner = oc.index;
            };
            try testing.expectEqual(want_owner, got_owner);
        }
    }
}

test "ownedAtTierIndexed matches ownedAtTier (owner-at-point, overlap + adjacency)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A mix: coarse [0,100]² with a nested fine [40,60]² (vertical overlap), plus
    // two same-cscl [0,50]² / [50,100]² halves that abut (horizontal adjacency).
    const coarse = try boxPoly(a, 0, 0, 100, 100);
    const fine = try boxPoly(a, 40, 40, 60, 60);
    const west = try boxPoly(a, 0, 0, 50, 100);
    const east = try boxPoly(a, 50, 0, 100, 100);
    const cells = [_]Cell{
        .{ .cscl = 100_000, .band_floor = 9, .order = 0, .cov1 = &.{coarse} },
        .{ .cscl = 20_000, .band_floor = 9, .order = 0, .cov1 = &.{fine} },
        .{ .cscl = 50_000, .band_floor = 9, .order = 0, .cov1 = &.{west} },
        .{ .cscl = 50_000, .band_floor = 9, .order = 1, .cov1 = &.{east} },
    };

    const plain = try ownedAtTier(a, &cells, 9);
    const idx = try ownedAtTierIndexed(a, &cells, 9);

    const ownerAt = struct {
        fn f(faces: []const OwnedCell, x: i64, y: i64) ?usize {
            for (faces) |oc| if (boolean.pointInEvenOdd(oc.owned, x, y)) return oc.index;
            return null;
        }
    }.f;

    // Step 7 from 2 never lands on an edge (40/50/60/100), avoiding even-odd
    // ambiguity; the two builders must name the same owner at every point.
    var y: i64 = 2;
    while (y < 100) : (y += 7) {
        var x: i64 = 2;
        while (x < 100) : (x += 7) {
            try testing.expectEqual(ownerAt(plain, x, y), ownerAt(idx, x, y));
        }
    }
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
                // Reference: finest (smallest cscl) eligible cell whose bbox covers;
                // where none covers, the COARSEST (largest cscl) finer cell fills up.
                var best: ?usize = null;
                for (cells.items, 0..) |c, i| {
                    if (c.band_floor > tier) continue;
                    const bb = bboxes.items[i];
                    if (qx >= bb[0] and qx <= bb[2] and qy >= bb[1] and qy <= bb[3]) {
                        if (best == null or c.cscl < cells.items[best.?].cscl) best = i;
                    }
                }
                if (best == null) {
                    for (cells.items, 0..) |c, i| {
                        if (c.band_floor <= tier) continue;
                        const bb = bboxes.items[i];
                        if (qx >= bb[0] and qx <= bb[2] and qy >= bb[1] and qy <= bb[3]) {
                            if (best == null or c.cscl > cells.items[best.?].cscl) best = i;
                        }
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

test "fuzz: ownedTiers with reuse is byte-identical to reuse off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0xFACE5EED);
    const rnd = prng.random();
    const grid: i64 = 64;

    var trial: usize = 0;
    while (trial < 120) : (trial += 1) {
        const ncells = rnd.intRangeAtMost(usize, 1, 8);
        var cells = std.ArrayList(Cell).empty;
        for (0..ncells) |k| {
            const x0 = rnd.intRangeAtMost(i64, -6, 4) * grid;
            const y0 = rnd.intRangeAtMost(i64, -6, 4) * grid;
            const w = rnd.intRangeAtMost(i64, 1, 6) * grid;
            const h = rnd.intRangeAtMost(i64, 1, 6) * grid;
            const cov = try boxPoly(a, x0, y0, x0 + w, y0 + h);
            const covs = try a.alloc(Poly, 1);
            covs[0] = cov;
            try cells.append(a, .{
                .cscl = @intCast(1000 + k * 100),
                .band_floor = rnd.intRangeAtMost(u8, 0, 13),
                .order = k,
                // Some cells reach-capped so the pool flips across tiers.
                .reach = if (rnd.uintLessThan(u8, 4) == 0) rnd.intRangeAtMost(u8, 5, 13) else 255,
                .cov1 = covs,
            });
        }
        // Distinct floors, descending — the band stack partition.build derives.
        var tier_set = std.ArrayList(u8).empty;
        for (cells.items) |c| {
            if (std.mem.indexOfScalar(u8, tier_set.items, c.band_floor) == null)
                try tier_set.append(a, c.band_floor);
        }
        std.mem.sort(u8, tier_set.items, {}, comptime std.sort.desc(u8));

        var idx = try buildCoverageIndex(a, cells.items);

        const with = try ownedTiersOpt(a, cells.items, tier_set.items, &idx, true, null);
        const without = try ownedTiersOpt(a, cells.items, tier_set.items, &idx, false, null);

        try testing.expectEqual(without.len, with.len);
        for (without, with) |w0, w1| {
            try testing.expectEqual(w0.len, w1.len);
            for (w0, w1) |f0, f1| {
                try testing.expectEqual(f0.index, f1.index);
                try testing.expectEqual(f0.owned.len, f1.owned.len);
                for (f0.owned, f1.owned) |r0, r1|
                    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(r0), std.mem.sliceAsBytes(r1));
            }
        }
        idx.deinit(a); // release its page-allocator worker arenas before the reset
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

test "clipLineInsidePolys: keeps the inside, drops the outside (compose clip-to-face)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const covered = try boxPoly(a, 40, -10, 60, 10); // covers x∈[40,60] on the y=0 line
    const line = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const runs = try clipLineInsidePolys(a, &line, covered);
    // Complement of the OUTSIDE clip: keep only the covered middle [40,60].
    try testing.expectEqual(@as(usize, 1), runs.len);
    const r = runs[0];
    try testing.expectEqual(@as(i64, 40), @min(r[0].x, r[r.len - 1].x));
    try testing.expectEqual(@as(i64, 60), @max(r[0].x, r[r.len - 1].x));
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

test "subtrahendLists: grid equals the all-pairs scan, element for element" {
    var prng = std.Random.DefaultPrng.init(0xA3B0C5);
    const rnd = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (0..60) |trial| {
        _ = arena.reset(.retain_capacity);
        const n = 1 + rnd.uintLessThan(usize, 150);
        const bbs = try a.alloc([4]i64, n);
        for (bbs) |*b| {
            if (rnd.uintLessThan(u8, 12) == 0) {
                // Emptied coverage: inverted bbox, overlaps nothing.
                b.* = .{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) };
            } else if (trial % 3 == 0 and rnd.uintLessThan(u8, 8) == 0) {
                // Whale: spans the whole extent (exercises the oversize path).
                b.* = .{ -2000, -2000, 2000, 2000 };
            } else {
                const x0 = rnd.intRangeAtMost(i64, -1000, 1000);
                const y0 = rnd.intRangeAtMost(i64, -1000, 1000);
                b.* = .{ x0, y0, x0 + rnd.intRangeAtMost(i64, 0, 400), y0 + rnd.intRangeAtMost(i64, 0, 400) };
            }
        }
        const lists = try subtrahendLists(a, bbs);
        for (bbs, 0..) |b, k| {
            var want = std.ArrayList(u32).empty;
            for (0..k) |j| {
                if (bboxOverlap(bbs[j], b)) try want.append(a, @intCast(j));
            }
            try testing.expectEqualSlices(u32, want.items, lists[k]);
        }
    }
}

test "EdgeGrid.parityF and grid line clip match their brute-force twins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(57);
    const rnd = prng.random();

    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        // A random jagged multi-ring coverage in a 4096 box.
        const nrings = 1 + rnd.uintLessThan(usize, 3);
        const rings = try a.alloc([]const Pt, nrings);
        for (rings) |*ring| {
            const n = 4 + rnd.uintLessThan(usize, 12);
            const r = try a.alloc(Pt, n);
            for (r) |*pp| pp.* = .{
                .x = @as(i64, rnd.uintLessThan(u16, 4097)),
                .y = @as(i64, rnd.uintLessThan(u16, 4097)),
            };
            ring.* = r;
        }
        var grid = try EdgeGrid.init(a, rings, 512);
        defer grid.deinit();

        // Parity at scattered float points (the .0/.5 midpoint lattice the
        // line clip actually queries).
        var q: usize = 0;
        while (q < 50) : (q += 1) {
            const x = @as(f64, @floatFromInt(rnd.uintLessThan(u16, 8193))) / 2.0 - 64.0;
            const y = @as(f64, @floatFromInt(rnd.uintLessThan(u16, 8193))) / 2.0 - 64.0;
            try testing.expectEqual(pointInEvenOddF(rings, x, y), grid.parityF(x, y));
        }

        // A random polyline clipped with and without the grid: identical runs.
        const ln = try a.alloc(Pt, 2 + rnd.uintLessThan(usize, 6));
        for (ln) |*pp| pp.* = .{
            .x = @as(i64, rnd.uintLessThan(u16, 4097)),
            .y = @as(i64, rnd.uintLessThan(u16, 4097)),
        };
        const plain = try clipLineInsidePolys(a, ln, rings);
        const via_grid = try clipLineInsidePolysGrid(a, ln, rings, &grid);
        try testing.expectEqual(plain.len, via_grid.len);
        for (plain, via_grid) |pr, gr| {
            try testing.expectEqual(pr.len, gr.len);
            for (pr, gr) |pp, gp| {
                try testing.expectEqual(pp.x, gp.x);
                try testing.expectEqual(pp.y, gp.y);
            }
        }
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
