//! Integer polygon boolean operations — a Martinez–Rueda–Feito sweep-line.
//!
//! This is the geometry core of the cross-band composition redesign
//! (specs/cross-band-composition-redesign.md, Phase 0). It computes the
//! union / intersection / difference / symmetric-difference of two polygons
//! whose vertices live on an integer lattice (the E7 coverage lattice for the
//! Stage-0 partition, or world-pixel space for per-tile emission). Integers are
//! deliberate: adjacent ENC cells that digitise a shared seam independently
//! collapse to *exact* integer equality once snapped to the lattice, so the
//! dominant seam case is a run of coincident edges rather than a cloud of
//! near-misses. The sweep types those coincident (overlapping) edges
//! (SAME_TRANSITION / DIFFERENT_TRANSITION / NON_CONTRIBUTING) so a shared seam
//! contributes to the result exactly once.
//!
//! Coordinate discipline:
//!   * `Pt` holds i64. E7 degrees are ±1.8e9 (fit i32), but *differences* reach
//!     3.6e9 (need i64) and orientation cross-products reach ~1.3e19 (overflow
//!     i64) — every orientation / area predicate therefore promotes to i128.
//!   * A proper crossing point is rational; it is computed from exact i128
//!     numerators in f64 and rounded to the nearest lattice point. Both sides of
//!     a seam compute the same crossing from the same integer endpoints, so the
//!     snap is deterministic (bake == live) and the ≤0.5-unit error is ~0.5 cm
//!     at E7. Collinear-overlap endpoints are real input vertices, so they are
//!     reproduced exactly.
//!
//! Determinism: the event order and the sweep-status order share one strict
//! total order whose final tie-break is a monotonic event id (never a pointer),
//! so the same input always yields byte-identical output.
//!
//! Winding: the result contours are emitted as *open* rings with unspecified
//! orientation — even-odd fill of the returned ring-set is the region. Callers
//! that need MVT winding hand the rings to scene.orientAreaRings (the sole
//! winding authority); nothing here relies on input orientation either, so
//! every operand is interpreted even-odd.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A lattice point. i64 holds any E7 or world-pixel coordinate with headroom.
pub const Pt = struct {
    x: i64,
    y: i64,
    pub inline fn eql(a: Pt, b: Pt) bool {
        return a.x == b.x and a.y == b.y;
    }
};

/// A contour is an open ring (first vertex != last); a polygon is a set of
/// contours interpreted with the even-odd rule.
pub const Polygon = []const []const Pt;

pub const Op = enum { intersect, unite, diff, sym_diff };

// ---------------------------------------------------------------------------
// Exact predicates (i128).
// ---------------------------------------------------------------------------

/// Twice the signed area of triangle (a,b,c). >0 ⇔ c is left of the directed
/// edge a→b (counter-clockwise in a y-up frame). Exact in i128.
pub inline fn signedArea(a: Pt, b: Pt, c: Pt) i128 {
    const abx: i128 = @as(i128, b.x) - a.x;
    const aby: i128 = @as(i128, b.y) - a.y;
    const acx: i128 = @as(i128, c.x) - a.x;
    const acy: i128 = @as(i128, c.y) - a.y;
    return abx * acy - aby * acx;
}

// ---------------------------------------------------------------------------
// Sweep events.
// ---------------------------------------------------------------------------

const EdgeType = enum { normal, non_contributing, same_transition, different_transition };

const SweepEvent = struct {
    p: Pt,
    /// Is this the left (lower/earlier) endpoint of its edge?
    left: bool,
    /// Which operand this edge belongs to: true = subject, false = clip.
    subject: bool,
    /// The event for the other endpoint of the same edge.
    other: *SweepEvent,
    /// Monotonic creation id — the deterministic final tie-break.
    id: u32,

    // Filled during the sweep.
    in_out: bool = false,
    other_in_out: bool = false,
    edge_type: EdgeType = .normal,
    in_result: bool = false,

    inline fn vertical(self: *const SweepEvent) bool {
        return self.p.x == self.other.p.x;
    }
    /// Is `q` above this edge? (segment below q). For a left event the edge is
    /// p→other.p; for a right event other.p→p (so the test reads left→right).
    inline fn below(self: *const SweepEvent, q: Pt) bool {
        return if (self.left)
            signedArea(self.p, self.other.p, q) > 0
        else
            signedArea(self.other.p, self.p, q) > 0;
    }
    inline fn above(self: *const SweepEvent, q: Pt) bool {
        return !self.below(q);
    }
};

/// Strict total order for the event queue: is `e1` processed strictly before
/// `e2`? Sweep is left→right (x asc), then y asc, right-endpoint before left at
/// a shared point, then the lower edge first, then a stable id tie-break.
fn queueBefore(e1: *const SweepEvent, e2: *const SweepEvent) bool {
    if (e1.p.x != e2.p.x) return e1.p.x < e2.p.x;
    if (e1.p.y != e2.p.y) return e1.p.y < e2.p.y;
    if (e1.left != e2.left) return !e1.left; // right endpoint first
    // Same point, same endpoint kind: the lower edge is processed first.
    const sa = signedArea(e1.p, e1.other.p, e2.other.p);
    if (sa != 0) return sa > 0; // e1 below e2 ⇒ e1 first
    // Collinear & coincident: subject before clip, then stable id.
    if (e1.subject != e2.subject) return e1.subject;
    return e1.id < e2.id;
}

fn eventOrder(_: void, a: *SweepEvent, b: *SweepEvent) std.math.Order {
    if (queueBefore(a, b)) return .lt;
    if (queueBefore(b, a)) return .gt;
    return .eq;
}

/// Sweep-status order: is `e1`'s segment strictly below `e2`'s at the sweep
/// line? Both are left events currently in the status. Mirrors the queue order
/// so the two structures never disagree.
fn segBelow(e1: *SweepEvent, e2: *SweepEvent) bool {
    if (e1 == e2) return false;
    const a1 = signedArea(e1.p, e1.other.p, e2.p);
    const a2 = signedArea(e1.p, e1.other.p, e2.other.p);
    if (a1 != 0 or a2 != 0) {
        // Not collinear.
        if (e1.p.eql(e2.p)) return e1.below(e2.other.p); // share left endpoint
        if (queueBefore(e2, e1)) return e2.above(e1.p); // e2 inserted first
        return e1.below(e2.p);
    }
    // Collinear: subject below clip, then stable id — consistent with queueBefore.
    if (e1.subject != e2.subject) return e1.subject;
    if (e1.p.eql(e2.p)) return e1.id < e2.id;
    return queueBefore(e2, e1); // the later-inserted segment sorts above
}

// ---------------------------------------------------------------------------
// Segment intersection (exact classification, snapped point).
// ---------------------------------------------------------------------------

/// Segment-intersection result: `n` is 0 (disjoint), 1 (a single crossing at
/// `p0`), or 2 (a collinear overlap spanning [`p0`,`p1`]).
pub const Inter = struct { n: u2, p0: Pt, p1: Pt };

/// Intersect segment a0→a1 with b0→b1 on the integer lattice. Public so the
/// coverage clip (plane.zig) can reuse the exact classification + snapped point.
pub fn segIntersect(a0: Pt, a1: Pt, b0: Pt, b1: Pt) Inter {
    return findIntersection(a0, a1, b0, b1);
}

inline fn roundDiv(a: Pt, num: i128, den: i128, d: Pt) Pt {
    // a + (num/den)*d, rounded to nearest lattice point. den != 0.
    const t = @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
    const rx = @round(@as(f64, @floatFromInt(a.x)) + t * @as(f64, @floatFromInt(d.x)));
    const ry = @round(@as(f64, @floatFromInt(a.y)) + t * @as(f64, @floatFromInt(d.y)));
    return .{ .x = @intFromFloat(rx), .y = @intFromFloat(ry) };
}

/// 0 = disjoint, 1 = one crossing point (p0), 2 = collinear overlap [p0,p1].
fn findIntersection(a0: Pt, a1: Pt, b0: Pt, b1: Pt) Inter {
    const d0: Pt = .{ .x = a1.x - a0.x, .y = a1.y - a0.y };
    const d1: Pt = .{ .x = b1.x - b0.x, .y = b1.y - b0.y };
    const e: Pt = .{ .x = b0.x - a0.x, .y = b0.y - a0.y };

    const cross: i128 = @as(i128, d0.x) * d1.y - @as(i128, d0.y) * d1.x;
    if (cross != 0) {
        // Lines cross; solve for the two parameters exactly (as ratios).
        var sNum: i128 = @as(i128, e.x) * d1.y - @as(i128, e.y) * d1.x; // s = sNum/cross
        var tNum: i128 = @as(i128, e.x) * d0.y - @as(i128, e.y) * d0.x; // t = tNum/cross
        var den: i128 = cross;
        if (den < 0) {
            den = -den;
            sNum = -sNum;
            tNum = -tNum;
        }
        if (sNum < 0 or sNum > den) return .{ .n = 0, .p0 = a0, .p1 = a0 };
        if (tNum < 0 or tNum > den) return .{ .n = 0, .p0 = a0, .p1 = a0 };
        const ip = roundDiv(a0, sNum, den, d0);
        return .{ .n = 1, .p0 = ip, .p1 = ip };
    }
    // Parallel. Collinear iff b0 lies on line a0→a1.
    const crossE: i128 = @as(i128, e.x) * d0.y - @as(i128, e.y) * d0.x;
    if (crossE != 0) return .{ .n = 0, .p0 = a0, .p1 = a0 };
    // Collinear: project b0,b1 onto a0→a1, scaled by |d0|². Overlap of the
    // scaled interval [0,L] with [min(pb0,pb1), max(...)].
    const sqrLen0: i128 = @as(i128, d0.x) * d0.x + @as(i128, d0.y) * d0.y;
    if (sqrLen0 == 0) return .{ .n = 0, .p0 = a0, .p1 = a0 }; // degenerate a-segment
    const pb0: i128 = @as(i128, d0.x) * e.x + @as(i128, d0.y) * e.y;
    const e2: Pt = .{ .x = b1.x - a0.x, .y = b1.y - a0.y };
    const pb1: i128 = @as(i128, d0.x) * e2.x + @as(i128, d0.y) * e2.y;
    const lo = @max(@as(i128, 0), @min(pb0, pb1));
    const hi = @min(sqrLen0, @max(pb0, pb1));
    if (lo > hi) return .{ .n = 0, .p0 = a0, .p1 = a0 };
    if (lo == hi) {
        const ip = roundDiv(a0, lo, sqrLen0, d0);
        return .{ .n = 1, .p0 = ip, .p1 = ip };
    }
    const q0 = roundDiv(a0, lo, sqrLen0, d0);
    const q1 = roundDiv(a0, hi, sqrLen0, d0);
    return .{ .n = 2, .p0 = q0, .p1 = q1 };
}

// ---------------------------------------------------------------------------
// The sweep.
// ---------------------------------------------------------------------------

const Queue = std.PriorityQueue(*SweepEvent, void, eventOrder);

const Sweeper = struct {
    arena: Allocator, // stable storage for events (never freed until arena drop)
    queue: Queue,
    status: std.ArrayList(*SweepEvent), // active left events, sorted by segBelow
    processed: std.ArrayList(*SweepEvent), // every event in pop order
    op: Op,
    next_id: u32 = 0,

    fn newEvent(self: *Sweeper, p: Pt, left: bool, subject: bool) !*SweepEvent {
        const ev = try self.arena.create(SweepEvent);
        ev.* = .{ .p = p, .left = left, .subject = subject, .other = ev, .id = self.next_id };
        self.next_id += 1;
        return ev;
    }

    /// Add both events of one input edge (a→b) to the queue.
    fn addEdge(self: *Sweeper, a: Pt, b: Pt, subject: bool, gpa: Allocator) !void {
        if (a.eql(b)) return; // skip zero-length edges
        const e1 = try self.newEvent(a, true, subject);
        const e2 = try self.newEvent(b, true, subject);
        e1.other = e2;
        e2.other = e1;
        // The left endpoint is the one processed first.
        if (queueBefore(e1, e2)) {
            e2.left = false;
        } else {
            e1.left = false;
        }
        try self.queue.push(gpa, e1);
        try self.queue.push(gpa, e2);
    }

    fn divideSegment(self: *Sweeper, le: *SweepEvent, p: Pt, gpa: Allocator) !void {
        const old_right = le.other;
        // Right endpoint of the left part [le.p, p].
        const r = try self.newEvent(p, false, le.subject);
        r.other = le;
        // Left endpoint of the right part [p, old_right.p].
        const l = try self.newEvent(p, true, le.subject);
        l.other = old_right;
        // Guard a rounding inversion: if l would sort after old_right, swap the
        // endpoint kinds so the shorter piece keeps a valid left→right sense.
        if (queueBefore(old_right, l)) {
            old_right.left = true;
            l.left = false;
        }
        old_right.other = l;
        le.other = r;
        try self.queue.push(gpa, l);
        try self.queue.push(gpa, r);
    }

    fn computeFields(self: *Sweeper, le: *SweepEvent, prev: ?*SweepEvent) void {
        if (prev) |pv| {
            if (le.subject == pv.subject) {
                le.in_out = !pv.in_out;
                le.other_in_out = pv.other_in_out;
            } else {
                le.in_out = !pv.other_in_out;
                le.other_in_out = if (pv.vertical()) !pv.in_out else pv.in_out;
            }
        } else {
            le.in_out = false;
            le.other_in_out = true;
        }
        le.in_result = self.inResult(le);
    }

    fn inResult(self: *Sweeper, le: *SweepEvent) bool {
        return switch (le.edge_type) {
            .normal => switch (self.op) {
                .intersect => !le.other_in_out,
                .unite => le.other_in_out,
                .diff => (le.subject and le.other_in_out) or (!le.subject and !le.other_in_out),
                .sym_diff => true,
            },
            .same_transition => self.op == .intersect or self.op == .unite,
            .different_transition => self.op == .diff,
            .non_contributing => false,
        };
    }

    /// Handle a possible intersection between two active segments. Returns 2 iff
    /// an overlap was typed (caller must then recompute the affected fields); a
    /// pure crossing/subdivision returns 1 or 3 and must NOT trigger a recompute
    /// (the split events carry their own fields when later processed).
    fn possibleIntersection(self: *Sweeper, le1: *SweepEvent, le2: *SweepEvent, gpa: Allocator) !i32 {
        const it = findIntersection(le1.p, le1.other.p, le2.p, le2.other.p);
        if (it.n == 0) return 0;
        if (it.n == 1 and (le1.p.eql(le2.p) or le1.other.p.eql(le2.other.p))) return 0; // shared endpoint only
        if (it.n == 2 and le1.subject == le2.subject) return 0; // overlap within one operand: even-odd cancels, ignore

        if (it.n == 1) {
            if (!le1.p.eql(it.p0) and !le1.other.p.eql(it.p0)) try self.divideSegment(le1, it.p0, gpa);
            if (!le2.p.eql(it.p0) and !le2.other.p.eql(it.p0)) try self.divideSegment(le2, it.p0, gpa);
            return 1;
        }

        // Collinear overlap between the two operands. Order the (≤4) endpoints;
        // a null slot marks a coincident pair.
        var ev: [4]?*SweepEvent = .{ null, null, null, null };
        var n: usize = 0;
        if (le1.p.eql(le2.p)) {
            ev[n] = null;
            n += 1;
        } else if (queueBefore(le1, le2)) {
            ev[n] = le1;
            n += 1;
            ev[n] = le2;
            n += 1;
        } else {
            ev[n] = le2;
            n += 1;
            ev[n] = le1;
            n += 1;
        }
        if (le1.other.p.eql(le2.other.p)) {
            ev[n] = null;
            n += 1;
        } else if (queueBefore(le1.other, le2.other)) {
            ev[n] = le1.other;
            n += 1;
            ev[n] = le2.other;
            n += 1;
        } else {
            ev[n] = le2.other;
            n += 1;
            ev[n] = le1.other;
            n += 1;
        }

        if (n == 2 or (n == 3 and ev[2] != null)) {
            // Segments are equal, or share their left endpoint: one carries the
            // transition, the other contributes nothing.
            le1.edge_type = .non_contributing;
            le2.edge_type = if (le1.in_out == le2.in_out) .same_transition else .different_transition;
            if (n == 3) try self.divideSegment(ev[2].?.other, ev[1].?.p, gpa);
            return 2; // typed → recompute
        }
        if (n == 3) {
            // Share the right endpoint: split the longer-left segment; the now
            // fully-coincident pieces are typed when re-processed.
            try self.divideSegment(ev[0].?, ev[1].?.p, gpa);
            return 3;
        }
        // Four distinct endpoints.
        if (ev[0].? != ev[3].?.other) {
            // Neither segment contains the other.
            try self.divideSegment(ev[0].?, ev[1].?.p, gpa);
            try self.divideSegment(ev[1].?, ev[2].?.p, gpa);
        } else {
            // One segment contains the other.
            try self.divideSegment(ev[0].?, ev[1].?.p, gpa);
            try self.divideSegment(ev[3].?.other, ev[2].?.p, gpa);
        }
        return 3;
    }

    // --- status (sorted array) helpers ---

    fn statusInsert(self: *Sweeper, le: *SweepEvent, gpa: Allocator) !usize {
        var i: usize = 0;
        while (i < self.status.items.len and segBelow(self.status.items[i], le)) : (i += 1) {}
        try self.status.insert(gpa, i, le);
        return i;
    }

    fn statusIndexOf(self: *Sweeper, le: *SweepEvent) ?usize {
        for (self.status.items, 0..) |e, i| {
            if (e == le) return i;
        }
        return null;
    }
};

/// Compute `subject op clip`. Result is a freshly allocated ring-set (open
/// rings, even-odd fill); free with `freePolygon`.
///
/// Precondition: each operand is a *simple* polygon — its own rings do not
/// overlap in area (holes are allowed as properly-nested reverse rings). Two
/// coincident edges are fine when they come from *different* operands (the seam
/// case, typed once), but three coincident edges — which require one operand to
/// overlap itself — are not resolved. Build operands from overlapping coverage
/// rings with `unionAll`, whose pairwise fold guarantees this. Coincident and
/// shared edges across the two operands are the designed-for common case.
pub fn compute(gpa: Allocator, subject: Polygon, clip: Polygon, op: Op) ![][]Pt {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sw = Sweeper{
        .arena = arena,
        .queue = Queue.initContext({}),
        .status = std.ArrayList(*SweepEvent).empty,
        .processed = std.ArrayList(*SweepEvent).empty,
        .op = op,
    };
    defer sw.queue.deinit(gpa);
    defer sw.status.deinit(gpa);
    defer sw.processed.deinit(gpa);

    for (subject) |ring| try addRing(&sw, ring, true, gpa);
    for (clip) |ring| try addRing(&sw, ring, false, gpa);

    while (sw.queue.pop()) |se| {
        try sw.processed.append(gpa, se);
        if (se.left) {
            const pos = try sw.statusInsert(se, gpa);
            const prev: ?*SweepEvent = if (pos > 0) sw.status.items[pos - 1] else null;
            const next: ?*SweepEvent = if (pos + 1 < sw.status.items.len) sw.status.items[pos + 1] else null;
            sw.computeFields(se, prev);
            if (next) |nx| {
                if (try sw.possibleIntersection(se, nx, gpa) == 2) {
                    sw.computeFields(se, prev);
                    sw.computeFields(nx, se);
                }
            }
            if (prev) |pv| {
                if (try sw.possibleIntersection(pv, se, gpa) == 2) {
                    const pprev: ?*SweepEvent = if (pos >= 2) sw.status.items[pos - 2] else null;
                    sw.computeFields(pv, pprev);
                    sw.computeFields(se, pv);
                }
            }
        } else {
            const le = se.other;
            const idx = sw.statusIndexOf(le) orelse continue;
            const prev: ?*SweepEvent = if (idx > 0) sw.status.items[idx - 1] else null;
            const next: ?*SweepEvent = if (idx + 1 < sw.status.items.len) sw.status.items[idx + 1] else null;
            _ = sw.status.orderedRemove(idx);
            if (prev != null and next != null) {
                _ = try sw.possibleIntersection(prev.?, next.?, gpa);
            }
        }
    }

    return connectEdges(gpa, sw.processed.items);
}

fn addRing(sw: *Sweeper, ring: []const Pt, subject: bool, gpa: Allocator) !void {
    if (ring.len < 3) return;
    var j = ring.len - 1;
    for (ring, 0..) |p, i| {
        try sw.addEdge(ring[j], p, subject, gpa);
        j = i;
    }
}

// ---------------------------------------------------------------------------
// Result reconstruction — closed contours from the surviving result edges.
// ---------------------------------------------------------------------------
//
// `pointInEvenOdd` is a *global* even-odd over the whole ring-set, so the region
// depends only on the emitted edge multiset, not on how edges are grouped into
// rings or whether a ring self-touches at a pinch vertex. Reconstruction therefore
// needs only to (1) reduce the result edges modulo 2 — canceling the doubled
// coincident edges an even-odd operand contributes at a shared seam — and (2) walk
// the survivors into closed loops (Hierholzer: pick any unused incident edge). On
// the even-degree survivor graph every non-start vertex always has an exit, so the
// walk always returns to its start on a real edge; the loop's implied edges are
// exactly the walked edges, keeping even-odd exact. Winding/nesting is deferred to
// scene.orientAreaRings.

const EdgeKey = struct { ax: i64, ay: i64, bx: i64, by: i64 };

fn canonEdge(a: Pt, b: Pt) EdgeKey {
    // Order the endpoints so the two directions of an edge share one key.
    if (a.x < b.x or (a.x == b.x and a.y <= b.y)) {
        return .{ .ax = a.x, .ay = a.y, .bx = b.x, .by = b.y };
    }
    return .{ .ax = b.x, .ay = b.y, .bx = a.x, .by = a.y };
}

const HEdge = struct { a: Pt, b: Pt, used: bool = false };

fn connectEdges(gpa: Allocator, all: []const *SweepEvent) ![][]Pt {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // (1) Reduce result edges modulo 2.
    var parity = std.AutoHashMap(EdgeKey, void).init(sa);
    for (all) |e| {
        if (!(e.left and e.in_result)) continue;
        if (e.p.eql(e.other.p)) continue;
        const key = canonEdge(e.p, e.other.p);
        if (parity.contains(key)) {
            _ = parity.remove(key);
        } else {
            try parity.put(key, {});
        }
    }

    var edges = std.ArrayList(HEdge).empty;
    var it = parity.keyIterator();
    while (it.next()) |k| {
        try edges.append(sa, .{ .a = .{ .x = k.ax, .y = k.ay }, .b = .{ .x = k.bx, .y = k.by } });
    }
    // Sort so the trace order (and hence ring order / start vertex) is a function
    // of geometry alone, not of hash-map iteration — the byte-stability the
    // bake==live contract needs.
    std.mem.sort(HEdge, edges.items, {}, struct {
        fn lt(_: void, x: HEdge, y: HEdge) bool {
            if (x.a.x != y.a.x) return x.a.x < y.a.x;
            if (x.a.y != y.a.y) return x.a.y < y.a.y;
            if (x.b.x != y.b.x) return x.b.x < y.b.x;
            return x.b.y < y.b.y;
        }
    }.lt);

    var adj = std.AutoHashMap(Pt, std.ArrayList(usize)).init(sa);
    for (edges.items, 0..) |e, idx| {
        for ([_]Pt{ e.a, e.b }) |p| {
            const gop = try adj.getOrPut(p);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(usize).empty;
            try gop.value_ptr.append(sa, idx);
        }
    }

    // (2) Walk closed loops.
    var out = std.ArrayList([]Pt).empty;
    errdefer {
        for (out.items) |c| gpa.free(c);
        out.deinit(gpa);
    }
    for (edges.items) |e0| {
        if (e0.used) continue;
        var ring = std.ArrayList(Pt).empty;
        defer ring.deinit(sa);
        const loop_start = e0.a;
        var cur = loop_start;
        try ring.append(sa, cur);
        var guard: usize = 0;
        const cap = edges.items.len + 2;
        while (guard <= cap) : (guard += 1) {
            const incident = adj.getPtr(cur).?;
            var picked: ?usize = null;
            for (incident.items) |ei| {
                if (!edges.items[ei].used) {
                    picked = ei;
                    break;
                }
            }
            const ei = picked orelse break;
            edges.items[ei].used = true;
            cur = if (edges.items[ei].a.eql(cur)) edges.items[ei].b else edges.items[ei].a;
            if (cur.eql(loop_start)) break; // closed on a real edge
            try ring.append(sa, cur);
        }
        if (ring.items.len >= 3) try out.append(gpa, try gpa.dupe(Pt, ring.items));
    }
    return out.toOwnedSlice(gpa);
}

pub fn freePolygon(gpa: Allocator, poly: [][]Pt) void {
    for (poly) |ring| gpa.free(ring);
    gpa.free(poly);
}

fn dupePolygon(gpa: Allocator, poly: Polygon) ![][]Pt {
    const out = try gpa.alloc([]Pt, poly.len);
    errdefer gpa.free(out);
    var n: usize = 0;
    errdefer for (out[0..n]) |r| gpa.free(r);
    while (n < poly.len) : (n += 1) out[n] = try gpa.dupe(Pt, poly[n]);
    return out;
}

/// Union of many polygons via a pairwise fold. Each fold step unions the clean
/// accumulator with one clean input, so no fold ever sees a self-overlapping
/// operand — this is the primitive that turns a bag of (possibly mutually
/// overlapping) ENC coverage rings into one simple partition operand, and the
/// reason `compute`'s simple-operand precondition is never violated in practice.
pub fn unionAll(gpa: Allocator, polys: []const Polygon) ![][]Pt {
    if (polys.len == 0) return gpa.alloc([]Pt, 0);
    var acc = try dupePolygon(gpa, polys[0]);
    errdefer freePolygon(gpa, acc);
    for (polys[1..]) |p| {
        const next = try compute(gpa, acc, p, .unite);
        freePolygon(gpa, acc);
        acc = next;
    }
    return acc;
}

// ---------------------------------------------------------------------------
// Even-odd point-in-polygon (exact) — the result oracle and a public helper.
// ---------------------------------------------------------------------------

/// Even-odd containment of (x,y) in a ring-set. On-boundary results are
/// edge-dependent (as with every even-odd test); callers that care sample off
/// the edges. Exact integer arithmetic (no float).
pub fn pointInEvenOdd(rings: []const []const Pt, x: i64, y: i64) bool {
    var inside = false;
    for (rings) |ring| {
        if (ring.len < 3) continue;
        var j = ring.len - 1;
        for (ring, 0..) |pi, i| {
            const pj = ring[j];
            j = i;
            if ((pi.y > y) != (pj.y > y)) {
                const dy: i128 = @as(i128, pj.y) - pi.y; // != 0 here
                const lhs: i128 = (@as(i128, x) - pi.x) * dy;
                const rhs: i128 = (@as(i128, y) - pi.y) * (@as(i128, pj.x) - pi.x);
                if (dy > 0) {
                    if (lhs < rhs) inside = !inside;
                } else {
                    if (lhs > rhs) inside = !inside;
                }
            }
        }
    }
    return inside;
}

/// True if (x,y) lies exactly on any edge of the ring-set. Used by tests to
/// skip ambiguous on-boundary samples.
pub fn pointOnEdge(rings: []const []const Pt, x: i64, y: i64) bool {
    const q: Pt = .{ .x = x, .y = y };
    for (rings) |ring| {
        if (ring.len < 2) continue;
        var j = ring.len - 1;
        for (ring, 0..) |pi, i| {
            const pj = ring[j];
            j = i;
            if (signedArea(pj, pi, q) != 0) continue; // not collinear with edge
            if (q.x < @min(pi.x, pj.x) or q.x > @max(pi.x, pj.x)) continue;
            if (q.y < @min(pi.y, pj.y) or q.y > @max(pi.y, pj.y)) continue;
            return true;
        }
    }
    return false;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn box(a: Allocator, x0: i64, y0: i64, x1: i64, y1: i64) ![]const []const Pt {
    const ring = try a.alloc(Pt, 4);
    ring[0] = .{ .x = x0, .y = y0 };
    ring[1] = .{ .x = x1, .y = y0 };
    ring[2] = .{ .x = x1, .y = y1 };
    ring[3] = .{ .x = x0, .y = y1 };
    const rings = try a.alloc([]const Pt, 1);
    rings[0] = ring;
    return rings;
}

// Free a ring-set: inner rings first, then the outer array (the ring slices
// live *inside* the outer buffer, so the order matters).
fn freeRings(a: Allocator, rings: []const []const Pt) void {
    for (rings) |ring| a.free(ring);
    a.free(rings);
}

fn combine(op: Op, in_a: bool, in_b: bool) bool {
    return switch (op) {
        .intersect => in_a and in_b,
        .unite => in_a or in_b,
        .diff => in_a and !in_b,
        .sym_diff => in_a != in_b,
    };
}

test "signedArea sign and exactness at E7 scale" {
    const a: Pt = .{ .x = -1_800_000_000, .y = -900_000_000 };
    const b: Pt = .{ .x = 1_800_000_000, .y = -900_000_000 };
    const c: Pt = .{ .x = 0, .y = 900_000_000 };
    try testing.expect(signedArea(a, b, c) > 0); // c left of a→b (CCW)
    try testing.expect(signedArea(a, c, b) < 0);
    try testing.expectEqual(@as(i128, 0), signedArea(a, b, b));
}

test "findIntersection: proper crossing, snapped" {
    const it = findIntersection(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, .{ .x = 0, .y = 100 }, .{ .x = 100, .y = 0 });
    try testing.expectEqual(@as(u2, 1), it.n);
    try testing.expectEqual(@as(i64, 50), it.p0.x);
    try testing.expectEqual(@as(i64, 50), it.p0.y);
}

test "findIntersection: collinear overlap returns the shared interval" {
    const it = findIntersection(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 40, .y = 0 }, .{ .x = 160, .y = 0 });
    try testing.expectEqual(@as(u2, 2), it.n);
    try testing.expectEqual(@as(i64, 40), it.p0.x);
    try testing.expectEqual(@as(i64, 100), it.p1.x);
}

test "findIntersection: parallel non-collinear is disjoint" {
    const it = findIntersection(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 0, .y = 10 }, .{ .x = 100, .y = 10 });
    try testing.expectEqual(@as(u2, 0), it.n);
}

test "union of two disjoint boxes keeps both areas" {
    const a = testing.allocator;
    const s = try box(a, 0, 0, 100, 100);
    defer freeRings(a, s);
    const c = try box(a, 200, 200, 300, 300);
    defer freeRings(a, c);
    const r = try compute(a, s, c, .unite);
    defer freePolygon(a, r);
    try testing.expect(pointInEvenOdd(r, 50, 50));
    try testing.expect(pointInEvenOdd(r, 250, 250));
    try testing.expect(!pointInEvenOdd(r, 150, 150));
}

test "difference punches the overlap" {
    const a = testing.allocator;
    const s = try box(a, 0, 0, 100, 100);
    defer freeRings(a, s);
    const c = try box(a, 50, 50, 150, 150);
    defer freeRings(a, c);
    const r = try compute(a, s, c, .diff);
    defer freePolygon(a, r);
    try testing.expect(pointInEvenOdd(r, 25, 25)); // subject-only corner kept
    try testing.expect(!pointInEvenOdd(r, 75, 75)); // overlap removed
    try testing.expect(!pointInEvenOdd(r, 125, 125)); // clip-only not added
}

test "intersection keeps only the overlap" {
    const a = testing.allocator;
    const s = try box(a, 0, 0, 100, 100);
    defer freeRings(a, s);
    const c = try box(a, 50, 50, 150, 150);
    defer freeRings(a, c);
    const r = try compute(a, s, c, .intersect);
    defer freePolygon(a, r);
    try testing.expect(pointInEvenOdd(r, 75, 75));
    try testing.expect(!pointInEvenOdd(r, 25, 25));
    try testing.expect(!pointInEvenOdd(r, 125, 125));
}

test "shared-edge seam: abutting boxes union to one rectangle, no slit" {
    const a = testing.allocator;
    const s = try box(a, 0, 0, 100, 100);
    defer freeRings(a, s);
    const c = try box(a, 100, 0, 200, 100); // shares the x=100 edge exactly
    defer freeRings(a, c);
    const r = try compute(a, s, c, .unite);
    defer freePolygon(a, r);
    // Points either side of the shared seam and on it are all inside.
    try testing.expect(pointInEvenOdd(r, 50, 50));
    try testing.expect(pointInEvenOdd(r, 150, 50));
    try testing.expect(pointInEvenOdd(r, 99, 50));
    try testing.expect(pointInEvenOdd(r, 101, 50));
    try testing.expect(!pointInEvenOdd(r, 250, 50));
}

test "difference against identical polygon is empty" {
    const a = testing.allocator;
    const s = try box(a, 0, 0, 100, 100);
    defer freeRings(a, s);
    const c = try box(a, 0, 0, 100, 100);
    defer freeRings(a, c);
    const r = try compute(a, s, c, .diff);
    defer freePolygon(a, r);
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "difference of a hole-creating clip yields a ring with a hole (even-odd)" {
    const a = testing.allocator;
    const s = try box(a, 0, 0, 100, 100);
    defer freeRings(a, s);
    const c = try box(a, 25, 25, 75, 75); // fully interior
    defer freeRings(a, c);
    const r = try compute(a, s, c, .diff);
    defer freePolygon(a, r);
    try testing.expect(pointInEvenOdd(r, 10, 10)); // ring body
    try testing.expect(!pointInEvenOdd(r, 50, 50)); // hole
}

// A random bag of axis-aligned boxes on a coarse grid (so the ≤0.5-unit
// intersection snap can never move a query point across an edge). The boxes may
// overlap each other — a simple operand is obtained by `unionAll`-ing them.
const BoxBag = struct {
    boxes: [3][4]Pt,
    n: usize,
    fn contains(self: *const BoxBag, x: i64, y: i64) bool {
        for (self.boxes[0..self.n]) |bxr| {
            if (x >= bxr[0].x and x <= bxr[1].x and y >= bxr[0].y and y <= bxr[2].y) return true;
        }
        return false;
    }
    // Present each box as a single-ring Polygon. `backing` supplies storage for
    // the length-1 ring slices and must outlive the returned polygons.
    fn polys(self: *const BoxBag, backing: *[3][1][]const Pt) [3]Polygon {
        var out: [3]Polygon = undefined;
        for (0..self.n) |i| {
            backing[i][0] = self.boxes[i][0..];
            out[i] = backing[i][0..];
        }
        return out;
    }
};

fn randBoxBag(rnd: std.Random, grid: i64) BoxBag {
    const n = rnd.intRangeAtMost(usize, 1, 3);
    var bag: BoxBag = .{ .boxes = undefined, .n = n };
    for (0..n) |i| {
        const x0 = rnd.intRangeAtMost(i64, -8, 6) * grid;
        const y0 = rnd.intRangeAtMost(i64, -8, 6) * grid;
        const w = rnd.intRangeAtMost(i64, 1, 6) * grid;
        const h = rnd.intRangeAtMost(i64, 1, 6) * grid;
        bag.boxes[i] = .{
            .{ .x = x0, .y = y0 },
            .{ .x = x0 + w, .y = y0 },
            .{ .x = x0 + w, .y = y0 + h },
            .{ .x = x0, .y = y0 + h },
        };
    }
    return bag;
}

test "fuzz: unionAll of overlapping boxes == 'in any box'" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var prng = std.Random.DefaultPrng.init(0x5EED1);
    const rnd = prng.random();
    const grid: i64 = 64;

    var trial: usize = 0;
    while (trial < 1500) : (trial += 1) {
        const bag = randBoxBag(rnd, grid);
        var backing: [3][1][]const Pt = undefined;
        const ps = bag.polys(&backing);
        const u = try unionAll(a, ps[0..bag.n]);
        var qy: i64 = -9 * grid;
        while (qy <= 12 * grid) : (qy += 17) {
            var qx: i64 = -9 * grid;
            while (qx <= 12 * grid) : (qx += 17) {
                if (pointOnEdge(u, qx, qy)) continue;
                const want = bag.contains(qx, qy);
                const got = pointInEvenOdd(u, qx, qy);
                if (want != got) {
                    std.debug.print("unionAll MISMATCH trial={} at ({},{}): want={} got={}\n", .{ trial, qx, qy, want, got });
                    std.debug.print("  bag n={} boxes={any}\n  U={any}\n", .{ bag.n, bag.boxes[0..bag.n], u });
                    return error.UnionAllMismatch;
                }
            }
        }
        _ = arena_state.reset(.retain_capacity);
    }
}

test "fuzz: even-odd(result) == even-odd(A) op even-odd(B), A/B cleaned via unionAll" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var prng = std.Random.DefaultPrng.init(0xC0FFEEBABE);
    const rnd = prng.random();
    const grid: i64 = 64;
    const ops = [_]Op{ .unite, .intersect, .diff, .sym_diff };

    var trial: usize = 0;
    while (trial < 1500) : (trial += 1) {
        const bagA = randBoxBag(rnd, grid);
        const bagB = randBoxBag(rnd, grid);
        var backA: [3][1][]const Pt = undefined;
        var backB: [3][1][]const Pt = undefined;
        const psA = bagA.polys(&backA);
        const psB = bagB.polys(&backB);
        const A = try unionAll(a, psA[0..bagA.n]); // simple operand
        const B = try unionAll(a, psB[0..bagB.n]);
        for (ops) |op| {
            const r = try compute(a, A, B, op);
            var qy: i64 = -9 * grid;
            while (qy <= 12 * grid) : (qy += 17) {
                var qx: i64 = -9 * grid;
                while (qx <= 12 * grid) : (qx += 17) {
                    if (pointOnEdge(A, qx, qy) or pointOnEdge(B, qx, qy) or pointOnEdge(r, qx, qy)) continue;
                    const want = combine(op, pointInEvenOdd(A, qx, qy), pointInEvenOdd(B, qx, qy));
                    const got = pointInEvenOdd(r, qx, qy);
                    if (want != got) {
                        std.debug.print("MISMATCH trial={} op={} at ({},{}): want={} got={}\n", .{ trial, op, qx, qy, want, got });
                        std.debug.print("  A={any}\n  B={any}\n  R={any}\n", .{ A, B, r });
                        return error.BooleanMismatch;
                    }
                }
            }
        }
        _ = arena_state.reset(.retain_capacity);
    }
}

test "fuzz: union is commutative and idempotent (region equality)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var prng = std.Random.DefaultPrng.init(0x1234ABCD);
    const rnd = prng.random();
    const grid: i64 = 64;

    var trial: usize = 0;
    while (trial < 400) : (trial += 1) {
        const bagA = randBoxBag(rnd, grid);
        const bagB = randBoxBag(rnd, grid);
        var backA: [3][1][]const Pt = undefined;
        var backB: [3][1][]const Pt = undefined;
        const psA = bagA.polys(&backA);
        const psB = bagB.polys(&backB);
        const A = try unionAll(a, psA[0..bagA.n]);
        const B = try unionAll(a, psB[0..bagB.n]);
        const ab = try compute(a, A, B, .unite);
        const ba = try compute(a, B, A, .unite);
        const aa = try compute(a, A, A, .unite);
        var qy: i64 = -9 * grid;
        while (qy <= 12 * grid) : (qy += 23) {
            var qx: i64 = -9 * grid;
            while (qx <= 12 * grid) : (qx += 23) {
                if (pointOnEdge(ab, qx, qy) or pointOnEdge(ba, qx, qy)) continue;
                try testing.expectEqual(pointInEvenOdd(ab, qx, qy), pointInEvenOdd(ba, qx, qy));
                if (!pointOnEdge(A, qx, qy) and !pointOnEdge(aa, qx, qy)) {
                    try testing.expectEqual(pointInEvenOdd(A, qx, qy), pointInEvenOdd(aa, qx, qy));
                }
            }
        }
        _ = arena_state.reset(.retain_capacity);
    }
}

test "determinism: same input yields byte-identical rings" {
    const a = testing.allocator;
    const s = try box(a, 0, 0, 100, 100);
    defer freeRings(a, s);
    const c = try box(a, 50, 25, 150, 75);
    defer freeRings(a, c);
    const r1 = try compute(a, s, c, .unite);
    defer freePolygon(a, r1);
    const r2 = try compute(a, s, c, .unite);
    defer freePolygon(a, r2);
    try testing.expectEqual(r1.len, r2.len);
    for (r1, r2) |ring1, ring2| {
        try testing.expectEqualSlices(Pt, ring1, ring2);
    }
}
