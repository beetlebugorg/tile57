//! Label declutter — the ONE collision authority.
//!
//! Every surface (pixel, ascii, vector) resolves a crowded chart through this
//! module, and the tile style's collision keys are generated from the same
//! ladder, so a chart declutters the same way whichever backend draws it.
//!
//! The S-52 model this encodes:
//!
//!   * ONLY TEXT COMPETES. A sounding is a SYMBOL — the Presentation Library
//!     draws soundings as symbol glyphs precisely so they stay legible and
//!     correctly located — and every symbol must be drawn: S-52 defines
//!     suppression only for coincident LINES and area boundaries, never for
//!     symbols. So a symbol (sounding included) neither drops a label nor is
//!     dropped by one; text is drawn last, on top of it. Nothing but text ever
//!     enters this pool.
//!
//!   * RANK. Text carries a text group, and the groups split into IMPORTANT
//!     text (10-19) and Other text (everything else) — the one text ranking
//!     S-52 draws, and the split the mariner's own "Important Text" / "Other
//!     Text" selection rides on. Important text claims its space first.
//!
//!     That is the WHOLE ladder. There is no second axis to rank text by:
//!     every label carries display priority 8 — text is drawn last, at a fixed
//!     priority, "independent of the object it applies to" — so a label's
//!     feature draw priority says nothing about the label, and ranking on it
//!     would invent an order the spec does not have.
//!
//!   * TIES. Two labels of the same tier are peers, and S-52 calls for "the
//!     given sequence in the data structure of the SENC, or some other neutral
//!     criterion" to settle the arbitrary decision: the earlier-emitted label
//!     wins, the engine's emission order being that sequence.
//!
//! The pool also settles REPETITION, which collision alone cannot. The engine
//! walks a scene tile by tile and clips each feature to the tile it is drawn in,
//! so one island, one depth contour, one sea area spanning several tiles is
//! labelled once PER TILE — each copy anchored to its own clipped piece, so the
//! copies never overlap and a collision test happily keeps them all. That is the
//! "Rhode Island" printed six times, the 9 m contour printed forty-eight. S-52
//! wants text kept to what the mariner needs to read: a feature is labelled, not
//! labelled repeatedly because of how we cut the tiles. So a label also loses if
//! the SAME text is already placed within `repeat_px` of it — the spacing below
//! which a repeat is redundant rather than informative. A long contour still
//! carries its value again further along, which is what a chart wants.
//!
//! What the pool deliberately does NOT do is let placement fall out of the
//! order the engine happened to walk the cell. Every candidate is RANKED
//! before any of them claims space. That is the whole point: a light
//! description must not vanish because some other feature — a sounding, a
//! buoy name — was encoded ahead of it, and toggling an unrelated display
//! setting must never change which labels survive.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An axis-aligned label box, in whatever pixel space the surface draws in
/// (canvas px for the raster, screen px for the GPU stream, character cells
/// for the text grid). The pool never converts between spaces — it only ever
/// compares boxes with boxes from the same surface.
pub const Box = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    pub fn overlaps(self: Box, o: Box) bool {
        return self.x0 <= o.x1 and self.x1 >= o.x0 and self.y0 <= o.y1 and self.y1 >= o.y0;
    }
};

/// The default repeat spacing for a pixel surface, in reference px: below this,
/// a second copy of the same label is a tiling artefact or noise rather than a
/// second thing worth reading. A long contour still re-states its value beyond
/// it. Chosen at roughly one tile-and-a-half at the reference 256 px tile, so a
/// feature cut across adjacent tiles is deduped whichever seam it straddles.
pub const REPEAT_PX: f64 = 384.0;

/// IMPORTANT text (groups 10-19) outranks Other text. Group 0 (a label the
/// portrayal gave no group) is Other: only a group the spec lists as important
/// gets the higher tier.
pub fn tier(group: i64) u8 {
    return if (group >= 10 and group <= 19) 0 else 1;
}

/// One candidate label. `id` is the caller's handle (an op index, a buffered
/// item index — the pool just hands it back); `seq` is the emission sequence,
/// assigned by the pool on `add`.
const Candidate = struct {
    id: usize,
    tier: u8,
    seq: usize,
    box: Box,
    /// What the label SAYS, hashed (class + text): two candidates with the same
    /// key are the same label — the same feature cut across tiles, or a name so
    /// close by that repeating it tells the mariner nothing.
    key: u64,
};

/// Rank order: important text first, then the earlier-emitted label. A total
/// order — no two candidates ever compare equal (seq is unique), so the
/// outcome never depends on the sort's stability.
fn ranks(_: void, l: Candidate, r: Candidate) bool {
    if (l.tier != r.tier) return l.tier < r.tier;
    return l.seq < r.seq;
}

/// The labels that survived, by caller id.
pub const Kept = struct {
    ids: std.AutoHashMapUnmanaged(usize, void) = .empty,

    pub fn has(self: *const Kept, id: usize) bool {
        return self.ids.contains(id);
    }

    pub fn deinit(self: *Kept, a: Allocator) void {
        self.ids.deinit(a);
    }
};

/// The collision pool: collect every candidate label in a scene, then resolve
/// the whole set at once.
pub const Pool = struct {
    cands: std.ArrayListUnmanaged(Candidate) = .empty,

    pub fn deinit(self: *Pool, a: Allocator) void {
        self.cands.deinit(a);
    }

    /// `class` + `text` identify the label for the repeat rule (see the header).
    pub fn add(self: *Pool, a: Allocator, id: usize, group: i64, class: []const u8, text: []const u8, box: Box) !void {
        var h = std.hash.Wyhash.init(0);
        h.update(class);
        h.update(text);
        try self.cands.append(a, .{
            .id = id,
            .tier = tier(group),
            .seq = self.cands.items.len,
            .box = box,
            .key = h.final(),
        });
    }

    /// Rank the pool, then claim space from the top down. A label loses if it
    /// OVERLAPS one already placed, or if it REPEATS one already placed within
    /// `repeat_px` (0 = allow every repeat). Distances are in the surface's own
    /// units — canvas px, screen px, character cells. Returns the survivors.
    pub fn resolve(self: *Pool, a: Allocator, repeat_px: f64) !Kept {
        std.mem.sort(Candidate, self.cands.items, {}, ranks);

        var grid = Occupancy{};
        defer grid.deinit(a);
        // Where each distinct label text has already been placed.
        var placed = std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged([2]f64)){};
        defer {
            var vit = placed.valueIterator();
            while (vit.next()) |v| v.deinit(a);
            placed.deinit(a);
        }
        var kept = Kept{};
        errdefer kept.deinit(a);

        for (self.cands.items) |c| {
            if (grid.hits(c.box)) continue;
            const cx = (c.box.x0 + c.box.x1) * 0.5;
            const cy = (c.box.y0 + c.box.y1) * 0.5;
            if (repeat_px > 0) {
                if (placed.get(c.key)) |spots| {
                    var repeats = false;
                    for (spots.items) |s| {
                        const dx = s[0] - cx;
                        const dy = s[1] - cy;
                        if (dx * dx + dy * dy < repeat_px * repeat_px) {
                            repeats = true;
                            break;
                        }
                    }
                    if (repeats) continue;
                }
            }
            try grid.claim(a, c.box);
            try kept.ids.put(a, c.id, {});
            if (repeat_px > 0) {
                const gop = try placed.getOrPut(a, c.key);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(a, .{ cx, cy });
            }
        }
        return kept;
    }
};

/// Claimed space: exact box overlap, bucketed on a uniform grid so a dense
/// scene stays linear-ish instead of testing every kept box every time. The
/// bucket size only affects speed — the overlap test itself is exact, so
/// every surface resolves identically whatever its scale.
const Occupancy = struct {
    const BUCKET: f64 = 64.0;

    /// bucket (col,row) packed into a key -> the boxes claimed in it.
    cells: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(Box)) = .empty,

    fn key(cx: i32, cy: i32) u64 {
        return (@as(u64, @as(u32, @bitCast(cx))) << 32) | @as(u64, @as(u32, @bitCast(cy)));
    }

    /// The bucket range a box spans. Clamped: a wildly out-of-range box (a
    /// label projected far off-canvas) must not overflow the cast.
    fn span(b: Box) [4]i32 {
        const lim = 1 << 20;
        const c = struct {
            fn f(v: f64) i32 {
                return @intFromFloat(std.math.clamp(@floor(v / BUCKET), -lim, lim));
            }
        };
        return .{ c.f(b.x0), c.f(b.y0), c.f(b.x1), c.f(b.y1) };
    }

    fn hits(self: *const Occupancy, b: Box) bool {
        const s = span(b);
        var cy = s[1];
        while (cy <= s[3]) : (cy += 1) {
            var cx = s[0];
            while (cx <= s[2]) : (cx += 1) {
                const bucket = self.cells.get(key(cx, cy)) orelse continue;
                for (bucket.items) |k| if (b.overlaps(k)) return true;
            }
        }
        return false;
    }

    fn claim(self: *Occupancy, a: Allocator, b: Box) !void {
        const s = span(b);
        var cy = s[1];
        while (cy <= s[3]) : (cy += 1) {
            var cx = s[0];
            while (cx <= s[2]) : (cx += 1) {
                const gop = try self.cells.getOrPut(a, key(cx, cy));
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(a, b);
            }
        }
    }

    fn deinit(self: *Occupancy, a: Allocator) void {
        var it = self.cells.valueIterator();
        while (it.next()) |v| v.deinit(a);
        self.cells.deinit(a);
    }
};

// ---- tests ------------------------------------------------------------------

const t = std.testing;

fn bx(x0: f64, y0: f64, x1: f64, y1: f64) Box {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

test "important text claims space over other text, whatever the emission order" {
    var p = Pool{};
    defer p.deinit(t.allocator);
    // The OTHER-text label is emitted FIRST (the cell encoded it first) and the
    // important one second, on the same spot. Rank, not order, must decide.
    try p.add(t.allocator, 1, 26, "CLS", "t1", bx(0, 0, 40, 10)); // geographic name
    try p.add(t.allocator, 2, 11, "CLS", "t2", bx(5, 0, 45, 10)); // vertical clearance

    var kept = try p.resolve(t.allocator, 0);
    defer kept.deinit(t.allocator);
    try t.expect(kept.has(2));
    try t.expect(!kept.has(1));
}

test "peers within a tier fall to the SENC sequence — the first label wins" {
    var p = Pool{};
    defer p.deinit(t.allocator);
    // A light description and a geographic name are both Other text: peers. The
    // engine's emission order settles it, and nothing else may.
    try p.add(t.allocator, 1, 26, "CLS", "t1", bx(0, 0, 40, 10));
    try p.add(t.allocator, 2, 23, "CLS", "t2", bx(5, 0, 45, 10));
    var kept = try p.resolve(t.allocator, 0);
    defer kept.deinit(t.allocator);
    try t.expect(kept.has(1));
    try t.expect(!kept.has(2));
}

test "a dropped label claims nothing: it never blocks a label it lost to" {
    var p = Pool{};
    defer p.deinit(t.allocator);
    try p.add(t.allocator, 1, 26, "CLS", "t1", bx(0, 0, 200, 10)); // wide Other-text banner
    try p.add(t.allocator, 2, 11, "CLS", "t2", bx(0, 0, 20, 10)); // important, both ends
    try p.add(t.allocator, 3, 11, "CLS", "t3", bx(180, 0, 200, 10));
    var kept = try p.resolve(t.allocator, 0);
    defer kept.deinit(t.allocator);
    try t.expect(kept.has(2));
    try t.expect(kept.has(3));
    try t.expect(!kept.has(1)); // the banner lost to BOTH; it claims nothing
}

test "non-overlapping labels all survive, and boxes are exact (bucket-independent)" {
    var p = Pool{};
    defer p.deinit(t.allocator);
    // Adjacent-but-disjoint boxes inside ONE bucket, and a pair straddling a
    // bucket seam: all must survive — the bucket grid is an index, not the test.
    try p.add(t.allocator, 1, 26, "CLS", "t1", bx(0, 0, 10, 10));
    try p.add(t.allocator, 2, 26, "CLS", "t2", bx(11, 0, 20, 10));
    try p.add(t.allocator, 3, 26, "CLS", "t3", bx(60, 0, 63, 10)); // left of the seam at 64
    try p.add(t.allocator, 4, 26, "CLS", "t4", bx(65, 0, 80, 10)); // right of it
    var kept = try p.resolve(t.allocator, 0);
    defer kept.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), kept.ids.count());
}

test "tier: only the spec's important groups outrank other text" {
    try t.expectEqual(@as(u8, 0), tier(11)); // vertical clearance of bridges
    try t.expectEqual(@as(u8, 1), tier(21)); // buoy/beacon names
    try t.expectEqual(@as(u8, 1), tier(23)); // light description
    try t.expectEqual(@as(u8, 1), tier(26)); // geographic names
    try t.expectEqual(@as(u8, 1), tier(0)); // ungrouped
}

test "the same label repeated by tiling is placed once; a genuine repeat further off survives" {
    var p = Pool{};
    defer p.deinit(t.allocator);
    // One island cut across three tiles: three copies of the same name, each
    // anchored to its own clipped piece, none of them overlapping. Collision
    // cannot see the problem — the repeat rule must.
    try p.add(t.allocator, 1, 26, "LNDARE", "Rhode Island", bx(0, 0, 80, 12));
    try p.add(t.allocator, 2, 26, "LNDARE", "Rhode Island", bx(200, 0, 280, 12));
    try p.add(t.allocator, 3, 26, "LNDARE", "Rhode Island", bx(0, 200, 80, 212));
    // A DIFFERENT feature that happens to sit close by keeps its own label...
    try p.add(t.allocator, 4, 26, "SEAARE", "Mount Hope Bay", bx(200, 200, 280, 212));
    // ...and the same text far away is a second thing worth reading, not a repeat.
    try p.add(t.allocator, 5, 26, "LNDARE", "Rhode Island", bx(900, 900, 980, 912));

    var kept = try p.resolve(t.allocator, REPEAT_PX);
    defer kept.deinit(t.allocator);
    try t.expect(kept.has(1)); // the first copy wins the name
    try t.expect(!kept.has(2)); // the tiling artefacts do not
    try t.expect(!kept.has(3));
    try t.expect(kept.has(4)); // a different label is untouched
    try t.expect(kept.has(5)); // beyond the spacing, a repeat is informative again
}

test "repeat_px 0 keeps every repeat (the rule is opt-in)" {
    var p = Pool{};
    defer p.deinit(t.allocator);
    try p.add(t.allocator, 1, 26, "LNDARE", "Maryland", bx(0, 0, 80, 12));
    try p.add(t.allocator, 2, 26, "LNDARE", "Maryland", bx(100, 0, 180, 12));
    var kept = try p.resolve(t.allocator, 0);
    defer kept.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), kept.ids.count());
}
