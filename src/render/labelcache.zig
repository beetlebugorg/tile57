//! Per-tile label-candidate memo — what makes a view-level label pass cheap
//! enough to run on every pan and zoom.
//!
//! The view-level text pass (chart.renderSurfaceLabels / renderComposeLabels)
//! walks every tile under the view into ONE declutter pool, so labels resolve
//! across tile and chart seams. Its cost, though, is the PORTRAYAL of those
//! tiles, and that cost is the same whether fifteen labels survive or a
//! thousand: a host calling it once per view-settle re-portrayed the whole
//! covering set every time.
//!
//! It does not have to. A label splits cleanly in two:
//!
//!   * What the TILE decides — the text, the shaped glyph size and advance
//!     width, the aligned baseline origin, the world anchor, the colour, the
//!     S-52 text group the pool ranks on. All of it is a pure function of the
//!     tile's portrayal at the mariner's settings and palette. That is
//!     vector.Candidate, and that is what this memo stores.
//!
//!   * What the VIEW decides — the collision box in the screen frame (view
//!     zoom + rotation), the depth-contour legibility gate (view zoom), the
//!     upside-down flip on a tangent-rotated run (view rotation). Those derive
//!     per call in VectorSurface.pushCandidate, from the candidate, in
//!     nanoseconds.
//!
//! So a repeat call at a new centre, zoom or rotation portrays NOTHING it has
//! already seen: it gathers the covering tiles' candidates, replays them into
//! the existing pool in the existing walk order, and resolves. The surviving
//! set is identical to portraying from scratch, because the pool sees the same
//! candidates in the same sequence — and sequence is what its tie-break rides
//! on (declutter.zig).
//!
//! Zoom is deliberately NOT part of the key. The tile's own integer z is (it
//! is part of the tile identity), but the request's FRACTIONAL zoom is not:
//! a host zooms continuously, so keying on it would mean a miss on every
//! frame. Nothing shaped here reads the fractional zoom — the display gates
//! evaluate at vector.GATE_ZOOM so only SCAMIN is neutralised, and SCAMIN is
//! passed through per feature for the host to cull. Rotation is not part of it
//! either, for the same reason and more obviously: it only moves boxes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vector = @import("vector.zig");
const resolve = @import("resolve.zig");

pub const Candidate = vector.Candidate;

/// One tile's candidates and the arena that owns them (the candidate slice, and
/// every text/class slice inside it). Each entry owning its own arena means an
/// eviction frees exactly one tile — the same shape as the decoded-tile memo in
/// chart.zig.
pub const Entry = struct {
    arena: std.heap.ArenaAllocator,
    cands: []const Candidate = &.{},
    gen: u64 = 0,
};

/// The memo. NOT internally synchronized — it hangs off a chart / compositor
/// handle and inherits that handle's threading rule.
pub const Cache = struct {
    entries: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
    /// Touch counter for the LRU eviction (mirrors chart.zig's view_gen).
    gen: u64 = 0,
    /// The portrayal identity every resident entry was built under (epochOf).
    epoch: u64 = 0,
    epoch_set: bool = false,
    max: usize = MAX_TILES,

    /// The resident tile bound. One 2560x2560 view covers ~121 tiles, so this holds
    /// a whole view plus a generous pan/zoom history and can never evict mid-render.
    ///
    /// Candidates are small: a shaped label is ~150 bytes including its text and
    /// class. Measured full at this bound over a NOAA Chesapeake set — panned across
    /// the coverage at seven zooms — the memo holds ~765 KB (256 tiles, ~1000
    /// candidates); a label-dense harbour set would be a few MB. Note the bound is
    /// on TILES, not charts: a composed tile costs the same whether the library
    /// behind it is six charts or seventeen hundred.
    ///
    /// Raising it is nearly free; LOWERING it is not, and costs more than it saves —
    /// at 16 tiles the same walk thrashes, re-portraying constantly, and total RSS
    /// came out ~4 MB HIGHER than at 256.
    pub const MAX_TILES: usize = 256;

    /// Point the cache at a portrayal identity. A DIFFERENT identity (any mariner
    /// setting, or the palette) means every resident candidate was shaped under
    /// rules that no longer hold — drop the lot rather than try to reason about
    /// which settings touch which label.
    pub fn retarget(self: *Cache, a: Allocator, epoch: u64) void {
        if (self.epoch_set and self.epoch == epoch) return;
        self.clear(a);
        self.epoch = epoch;
        self.epoch_set = true;
    }

    pub fn key(z: u8, x: u32, y: u32) u64 {
        return (@as(u64, z) << 58) | (@as(u64, x) << 29) | @as(u64, y);
    }

    /// The memoized candidates for tile (z,x,y), or null if it has not been
    /// portrayed under the current identity. An EMPTY slice is a real answer —
    /// "this tile carries no labels" — and is cached like any other, so a view
    /// over open water stops re-portraying it too.
    pub fn get(self: *Cache, z: u8, x: u32, y: u32) ?[]const Candidate {
        self.gen += 1;
        const e = self.entries.get(key(z, x, y)) orelse return null;
        e.gen = self.gen;
        return e.cands;
    }

    /// A fresh entry to capture one tile's candidates into. Null on OOM — the
    /// caller then skips the tile, exactly as the decoded-tile memo does.
    pub fn newEntry(self: *Cache, a: Allocator) ?*Entry {
        self.gen += 1;
        const e = a.create(Entry) catch return null;
        e.* = .{ .arena = std.heap.ArenaAllocator.init(a), .gen = self.gen };
        return e;
    }

    /// Take ownership of a captured entry and return its candidates. `cands` must
    /// live in the entry's own arena. Null (entry released) if it cannot be
    /// stored — the tile contributes no labels to this call rather than risking a
    /// dangling slice.
    pub fn store(self: *Cache, a: Allocator, z: u8, x: u32, y: u32, e: *Entry, cands: []const Candidate) ?[]const Candidate {
        e.cands = cands;
        if (self.entries.count() >= self.max) self.evictOldest(a);
        self.entries.put(a, key(z, x, y), e) catch {
            release(a, e);
            return null;
        };
        return e.cands;
    }

    /// Evict the least-recently-touched entry (linear scan; the map is small and
    /// bounded by `max`).
    fn evictOldest(self: *Cache, a: Allocator) void {
        var oldest_key: u64 = 0;
        var oldest_gen: u64 = std.math.maxInt(u64);
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*.gen < oldest_gen) {
                oldest_gen = kv.value_ptr.*.gen;
                oldest_key = kv.key_ptr.*;
            }
        }
        if (self.entries.fetchRemove(oldest_key)) |kv| release(a, kv.value);
    }

    fn release(a: Allocator, e: *Entry) void {
        e.arena.deinit();
        a.destroy(e);
    }

    pub fn clear(self: *Cache, a: Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |v| release(a, v.*);
        self.entries.clearRetainingCapacity();
    }

    pub fn deinit(self: *Cache, a: Allocator) void {
        self.clear(a);
        self.entries.deinit(a);
    }
};

/// The PORTRAYAL IDENTITY a memoized candidate was shaped under: the palette
/// (candidates carry a resolved colour) plus every mariner setting.
///
/// Every field, not a hand-picked few. Which labels exist and what they say
/// already rides on a long list of them — the text-group switches, the depth
/// unit a contour value is printed in, the display categories and viewing
/// groups that gate a feature out entirely, the contours a shade resolves
/// against, the text size multiplier that sets both glyph px and box — and a
/// field wrongly left out is a stale label on screen, which on a chart is not
/// a cosmetic bug. Hashing the struct reflectively also means a setting added
/// later is covered the day it is added, with nobody having to remember.
pub fn epochOf(palette: resolve.PaletteId, m: *const resolve.Settings) u64 {
    var h = std.hash.Wyhash.init(0);
    hashValue(&h, palette);
    inline for (std.meta.fields(resolve.Settings)) |f| hashValue(&h, @field(m, f.name));
    return h.final();
}

fn hashValue(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => {
            if (v) |inner| {
                h.update(&.{1});
                hashValue(h, inner);
            } else h.update(&.{0});
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("label cache: cannot hash setting of type " ++ @typeName(T));
            const n: usize = v.len;
            h.update(std.mem.asBytes(&n));
            h.update(std.mem.sliceAsBytes(v));
        },
        .@"enum" => {
            const tag = @intFromEnum(v);
            h.update(std.mem.asBytes(&tag));
        },
        .bool => h.update(&.{@intFromBool(v)}),
        // Ints and floats: their bytes ARE their value (no padding in a scalar).
        else => h.update(std.mem.asBytes(&v)),
    }
}

// ---- tests -------------------------------------------------------------------

const t = std.testing;

test "epochOf: the palette and every mariner setting move the identity" {
    const base = resolve.Settings{};
    const day = epochOf(.day, &base);
    try t.expectEqual(day, epochOf(.day, &base)); // stable
    try t.expect(day != epochOf(.night, &base)); // candidates carry colour

    // A field from each family that shapes candidates.
    var m = base;
    m.text_names = false;
    try t.expect(day != epochOf(.day, &m));
    m = base;
    m.show_light_descriptions = false;
    try t.expect(day != epochOf(.day, &m));
    m = base;
    m.text_other = false;
    try t.expect(day != epochOf(.day, &m));
    m = base;
    m.depth_unit = .feet; // a contour value's text
    try t.expect(day != epochOf(.day, &m));
    m = base;
    m.safety_contour = 12; // the contours a shade resolves against
    try t.expect(day != epochOf(.day, &m));
    m = base;
    m.text_size_scale = 1.5; // glyph px AND the declutter box
    try t.expect(day != epochOf(.day, &m));
    m = base;
    m.display_other = true; // gates whole features out
    try t.expect(day != epochOf(.day, &m));
    m = base;
    m.show_soundings = true; // ?bool: null and set must differ
    try t.expect(day != epochOf(.day, &m));

    // The two slice-valued settings hash by CONTENT, not by pointer.
    const off_a = [_]i32{ 21030, 26050 };
    const off_b = [_]i32{21030};
    var va = base;
    va.viewing_groups_off = &off_a;
    var vb = base;
    vb.viewing_groups_off = &off_b;
    try t.expect(epochOf(.day, &va) != epochOf(.day, &vb));
    try t.expect(epochOf(.day, &va) != day); // set vs null
    var dv = base;
    dv.date_view = "20260101";
    try t.expect(day != epochOf(.day, &dv));
}

test "epochOf covers EVERY settings field — a new one cannot be forgotten" {
    // Reflective proof of the claim in the doc comment: flip/perturb each field in
    // turn and require the identity to move. A setting added later that this loop
    // cannot perturb (a new kind of type) fails to compile here rather than
    // silently going unhashed.
    const base = resolve.Settings{};
    const h0 = epochOf(.day, &base);
    inline for (std.meta.fields(resolve.Settings)) |f| {
        var m = base;
        switch (@typeInfo(f.type)) {
            .bool => @field(m, f.name) = !@field(base, f.name),
            .float => @field(m, f.name) = @field(base, f.name) + 7.25,
            .int => @field(m, f.name) = @field(base, f.name) +% 1,
            // Every enum setting here has at least two members; take the one the
            // default is not.
            .@"enum" => |e| @field(m, f.name) = if (@intFromEnum(@field(base, f.name)) == e.fields[0].value)
                @enumFromInt(e.fields[1].value)
            else
                @enumFromInt(e.fields[0].value),
            // An optional setting defaults to null, so any value differs.
            .optional => |o| switch (@typeInfo(o.child)) {
                .bool => @field(m, f.name) = !(@field(base, f.name) orelse false), // show_soundings
                .pointer => @field(m, f.name) = comptime blk: { // viewing_groups_off
                    break :blk &[_]std.meta.Elem(o.child){1};
                },
                else => @compileError("label cache test: unhandled optional setting " ++ f.name),
            },
            // []const u8 (date_view).
            .pointer => @field(m, f.name) = "perturbed",
            else => @compileError("label cache test: unhandled setting type " ++ @typeName(f.type)),
        }
        try t.expect(h0 != epochOf(.day, &m));
    }
}

test "Cache: retarget keeps entries for the same identity and drops them for another" {
    const a = t.allocator;
    var c = Cache{};
    defer c.deinit(a);

    const day = epochOf(.day, &resolve.Settings{});
    c.retarget(a, day);
    const e = c.newEntry(a).?;
    _ = c.store(a, 5, 1, 2, e, &.{}).?;
    try t.expect(c.get(5, 1, 2) != null); // a cached EMPTY tile is still a hit
    try t.expectEqual(@as(?[]const Candidate, null), c.get(5, 1, 3));

    c.retarget(a, day); // same identity: nothing dropped
    try t.expect(c.get(5, 1, 2) != null);

    c.retarget(a, epochOf(.night, &resolve.Settings{}));
    try t.expectEqual(@as(?[]const Candidate, null), c.get(5, 1, 2));
}

test "Cache: the tile bound holds, evicting least-recently-touched" {
    const a = t.allocator;
    var c = Cache{ .max = 4 };
    defer c.deinit(a);

    for (0..4) |i| {
        const e = c.newEntry(a).?;
        _ = c.store(a, 5, @intCast(i), 0, e, &.{}).?;
    }
    try t.expectEqual(@as(usize, 4), c.entries.count());
    // Touch every tile but x=1, then add a fifth: x=1 is the one that goes.
    _ = c.get(5, 0, 0);
    _ = c.get(5, 2, 0);
    _ = c.get(5, 3, 0);
    const e = c.newEntry(a).?;
    _ = c.store(a, 5, 4, 0, e, &.{}).?;
    try t.expectEqual(@as(usize, 4), c.entries.count()); // bounded
    try t.expectEqual(@as(?[]const Candidate, null), c.get(5, 1, 0));
    try t.expect(c.get(5, 0, 0) != null);
    try t.expect(c.get(5, 4, 0) != null);
}

test "Cache: key packs (z,x,y) without collision" {
    try t.expect(Cache.key(5, 1, 2) != Cache.key(5, 2, 1));
    try t.expect(Cache.key(5, 1, 2) != Cache.key(6, 1, 2));
    try t.expectEqual(Cache.key(14, 4823, 6160), Cache.key(14, 4823, 6160));
}
