//! SCAMIN standalone (specs/scamin-standalone.md): cross-cell point-object
//! matching, SCAMIN union, per-feature scale-window eligibility, and the
//! synthetic "mini cell" the deduped features are emitted from.
//!
//! A SCAMIN-carrying POINT feature (a light, buoy, beacon, wreck, …) is charted
//! in several cells of different compilation scales — the SAME real-world
//! object with per-scale SCAMINs. Its display lifecycle is purely a SCALE
//! question, so these features leave band quilting entirely: the copies are
//! matched into one object (FOID identity first, class + position epsilon +
//! light character as the fallback), collapse to ONE feature (geometry +
//! attributes from the FINEST copy, effective scamin = MAX over the copies),
//! and that feature enters every tile whose display window its effective
//! scamin can reach (eligibleAt) — no band ranges, no emitted-skip, no
//! carry-down. Copies that match nothing keep their own scamin; where a
//! strictly-FINER chart covers the point without contributing a copy, the
//! feature is capped (`smax`) at that chart's scale so the finest chart still
//! owns its own display window (capFor — the per-feature descendant of the
//! band-handoff carryGate).
//!
//! Shared by the bundle/archive bakers (a global pre-pass over all cells) and
//! the live chart.zig path (a per-tile local dedup over the covering cells) so
//! the two cannot drift.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57");
const scene = @import("scene.zig");
const bake_enc = @import("bake_enc.zig");

/// Fallback position epsilon (metres) for copies with no FOID: measured on the
/// NOAA Chesapeake cells, cross-cell copies are almost always < 5 m apart while
/// DISTINCT same-class aids (gate buoy pairs, jetty lights) come no closer than
/// ~23 m — 30 m still catches slightly-generalized copies without collapsing a
/// real pair. A missed match degrades gracefully (the copy keeps its own scamin
/// + smax cap, i.e. the old band-handoff behaviour for that object).
pub const MATCH_EPS_M: f64 = 30.0;

/// Sanity bound on a FOID match: the same FOID more than this far apart is bad
/// data (or a re-used identifier) — refuse the union rather than teleport the
/// object. Measured NOAA FOID copies are all < 100 m apart.
pub const FOID_GUARD_M: f64 = 500.0;

/// Live-path gate: skip the per-tile overlay entirely when the tile's display
/// window opens coarser than any plausible SCAMIN (D(z+1) above this bound —
/// roughly z <= 4 at mid-latitudes). Nothing could be eligible there, and the
/// gather would otherwise lazily load every covering cell of the whole root.
pub const MAX_OVERLAY_DENOM: f64 = 10_000_000;

/// One SCAMIN-carrying point feature's matchable identity (collectRecs) plus
/// the dedup outputs (dedup fills effective/winner).
pub const Rec = struct {
    lon: f64,
    lat: f64,
    scamin: u32,
    objl: u16,
    foid: u64, // S-57 FOID identity (0 = absent)
    mkey: u64, // discriminator hash: COLOUR + light character/sectors/range
    cell: u32, // caller's cell ordinal
    feat: u32, // feature index within the cell
    rcid: u32, // path-independent tie-break
    cscl: i32, // owning cell's compilation scale (0 = unknown)
    // dedup() outputs:
    effective: u32 = 0, // MAX scamin over the matched group (the union window)
    winner: bool = false, // this copy carries the group (finest cscl)
};

// Attributes that discriminate DISTINCT objects sharing a class + position:
// COLOUR separates gate pairs; the light character/sector/range set separates
// stacked sector/range lights at one structure. Absent attrs hash as "".
const MKEY_ATTRS = [_]u16{
    s57.ATTR_COLOUR,
    s57.ATTR_LITCHR, s57.ATTR_SIGGRP, s57.ATTR_SIGPER,
    s57.ATTR_SECTR1, s57.ATTR_SECTR2, s57.ATTR_VALNMR,
    86, // HEIGHT
};

fn matchKey(f: s57.Feature) u64 {
    var h = std.hash.Wyhash.init(0x5ca317);
    for (MKEY_ATTRS) |code| {
        const v = std.mem.trim(u8, f.attr(code) orelse "", " ");
        h.update(v);
        h.update(&[_]u8{0}); // field separator so "1","2" != "12",""
    }
    return h.final();
}

/// Equirectangular ground distance (metres) — exact enough at aid-to-navigation
/// separations (< 1 km) for the epsilon/guard tests.
pub fn distM(lon1: f64, lat1: f64, lon2: f64, lat2: f64) f64 {
    const m_per_deg = 111_320.0;
    const cx = @cos((lat1 + lat2) * 0.5 * std.math.pi / 180.0);
    const dx = (lon1 - lon2) * m_per_deg * cx;
    const dy = (lat1 - lat2) * m_per_deg;
    return std.math.hypot(dx, dy);
}

/// Collect one cell's matchable SCAMIN point records: prim==1 features carrying
/// SCAMIN, excluding SOUNDG (spec: soundings stay as-is). `cell_idx` is the
/// caller's ordinal for the cell. Allocates the slice in `a`.
pub fn collectRecs(a: Allocator, cell: *const s57.Cell, cscl: i32, cell_idx: u32) ![]Rec {
    var out = std.ArrayList(Rec).empty;
    for (cell.features, 0..) |f, fi| {
        if (f.prim != 1 or f.objl == 129) continue;
        const sc = scene.featureScamin(f) orelse continue;
        const pg = cell.pointGeometry(f) orelse continue;
        try out.append(a, .{
            .lon = pg.lon(),
            .lat = pg.lat(),
            .scamin = @intCast(sc),
            .objl = f.objl,
            .foid = f.foid,
            .mkey = matchKey(f),
            .cell = cell_idx,
            .feat = @intCast(fi),
            .rcid = f.rcid,
            .cscl = cscl,
        });
    }
    return out.toOwnedSlice(a);
}

// Union-find with path halving.
fn ufFind(parent: []u32, start: u32) u32 {
    var i = start;
    while (parent[i] != i) {
        parent[i] = parent[parent[i]];
        i = parent[i];
    }
    return i;
}

fn ufUnion(parent: []u32, a_: u32, b_: u32) void {
    const ra = ufFind(parent, a_);
    const rb = ufFind(parent, b_);
    if (ra != rb) parent[@max(ra, rb)] = @min(ra, rb);
}

// Effective-cscl for the winner ordering: unknown (<=0) sorts coarsest.
fn ecscl(c: i32) i64 {
    return if (c > 0) c else std.math.maxInt(i32);
}

// Path-independent winner ordering within a group: finest compilation scale
// first; ties broken by the copy's own scamin (larger = charted to a coarser
// window, keep it), then position, then RCID — never by the caller's cell
// ordinal, so the live and bake paths pick the same copy.
fn winnerBetter(a_: Rec, b: Rec) bool {
    if (ecscl(a_.cscl) != ecscl(b.cscl)) return ecscl(a_.cscl) < ecscl(b.cscl);
    if (a_.scamin != b.scamin) return a_.scamin > b.scamin;
    if (a_.lat != b.lat) return a_.lat < b.lat;
    if (a_.lon != b.lon) return a_.lon < b.lon;
    return a_.rcid < b.rcid;
}

/// Match the records into object groups and fill each Rec's dedup outputs:
/// `effective` = MAX scamin over its group (the union of the copies' display
/// windows) and `winner` on exactly one copy per group (the finest cscl; ties
/// broken path-independently). Matching: same FOID (+ class + FOID_GUARD_M
/// sanity distance) unions unconditionally — NOAA carries the same FOID for the
/// same object across US3/US4/US5; records WITHOUT a FOID fall back to class +
/// discriminator-attrs + MATCH_EPS_M. `recs` may span many cells (bake global
/// pre-pass) or one tile's gather (live). O(n·bucket) — buckets are tiny.
pub fn dedup(gpa: Allocator, recs: []Rec) !void {
    if (recs.len == 0) return;
    const n: u32 = @intCast(recs.len);
    const parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);

    // FOID identity pass: bucket by (foid, objl); union members within the guard.
    var by_foid = std.AutoHashMap(u64, u32).init(gpa); // (foid^objl-mix) -> first idx
    defer by_foid.deinit();
    var chain = try gpa.alloc(u32, n); // singly-linked bucket chains
    defer gpa.free(chain);
    @memset(chain, std.math.maxInt(u32));
    for (recs, 0..) |r, ri| {
        const i: u32 = @intCast(ri);
        if (r.foid == 0) continue;
        const key = r.foid ^ (@as(u64, r.objl) << 1) ^ 0x9e3779b97f4a7c15;
        const gop = try by_foid.getOrPut(key);
        if (gop.found_existing) {
            // Walk the bucket; union with every in-guard member (handles the
            // pathological same-FOID-far-apart case by NOT merging it).
            var j = gop.value_ptr.*;
            while (j != std.math.maxInt(u32)) : (j = chain[j]) {
                if (recs[j].objl == r.objl and
                    distM(r.lon, r.lat, recs[j].lon, recs[j].lat) <= FOID_GUARD_M)
                    ufUnion(parent, i, j);
            }
            chain[i] = gop.value_ptr.*;
            gop.value_ptr.* = i;
        } else {
            gop.value_ptr.* = i;
        }
    }

    // Fallback pass for FOID-less records: spatial grid, match by class +
    // discriminator key + epsilon against ALL records.
    var any_no_foid = false;
    for (recs) |r| {
        if (r.foid == 0) {
            any_no_foid = true;
            break;
        }
    }
    if (any_no_foid) {
        // Grid cell ~ MATCH_EPS_M at the records' latitude span; neighbours checked 3x3.
        const cell_deg = MATCH_EPS_M / 111_320.0 * 2.0;
        var grid = std.AutoHashMap(u64, u32).init(gpa); // grid key -> first idx
        defer grid.deinit();
        var gchain = try gpa.alloc(u32, n);
        defer gpa.free(gchain);
        @memset(gchain, std.math.maxInt(u32));
        const keyOf = struct {
            fn f(lon: f64, lat: f64, cd: f64) u64 {
                const gx: i64 = @intFromFloat(@floor(lon / cd));
                const gy: i64 = @intFromFloat(@floor(lat / cd));
                return (@as(u64, @bitCast(gx)) << 32) ^ @as(u64, @bitCast(gy));
            }
        }.f;
        for (recs, 0..) |r, ri| {
            const i: u32 = @intCast(ri);
            const k = keyOf(r.lon, r.lat, cell_deg);
            const gop = try grid.getOrPut(k);
            if (gop.found_existing) {
                gchain[i] = gop.value_ptr.*;
            }
            gop.value_ptr.* = i;
        }
        for (recs, 0..) |r, ri| {
            const i: u32 = @intCast(ri);
            if (r.foid != 0) continue; // fallback matching only for FOID-less records
            var dxi: i64 = -1;
            while (dxi <= 1) : (dxi += 1) {
                var dyi: i64 = -1;
                while (dyi <= 1) : (dyi += 1) {
                    const k = keyOf(
                        r.lon + @as(f64, @floatFromInt(dxi)) * cell_deg,
                        r.lat + @as(f64, @floatFromInt(dyi)) * cell_deg,
                        cell_deg,
                    );
                    var j = grid.get(k) orelse continue;
                    while (true) {
                        if (j != i and recs[j].objl == r.objl and recs[j].mkey == r.mkey and
                            distM(r.lon, r.lat, recs[j].lon, recs[j].lat) <= MATCH_EPS_M)
                            ufUnion(parent, i, j);
                        if (gchain[j] == std.math.maxInt(u32)) break;
                        j = gchain[j];
                    }
                }
            }
        }
    }

    // Resolve groups: effective = max scamin; winner = the best-ordered copy.
    const best = try gpa.alloc(u32, n); // root -> winner idx
    defer gpa.free(best);
    const eff = try gpa.alloc(u32, n); // root -> max scamin
    defer gpa.free(eff);
    @memset(eff, 0);
    for (recs, 0..) |r, ri| {
        const i: u32 = @intCast(ri);
        const root = ufFind(parent, i);
        if (eff[root] == 0) {
            best[root] = i;
        } else if (winnerBetter(r, recs[best[root]])) {
            best[root] = i;
        }
        eff[root] = @max(eff[root], r.scamin);
    }
    for (recs, 0..) |*r, ri| {
        const i: u32 = @intCast(ri);
        const root = ufFind(parent, i);
        r.effective = eff[root];
        r.winner = (best[root] == i);
    }
}

/// The per-feature smax cap: where a STRICTLY finer chart than the group's
/// finest copy covers the point (finest_covering_cscl < group_min_cscl), the
/// deduped feature must hand the display off to that chart once the display
/// reaches its scale — quantized UP onto the covering cells' scamin ladders
/// (bake_enc.quantizeHandoff) so the crossing exists on the client's ladder.
/// 0 = no cap (the group's finest copy IS the finest chart here — it owns the
/// display to maxzoom). Mirrors carryGate's suppress→carry semantics per POINT.
pub fn capFor(group_min_cscl: i32, finest_covering_cscl: i32, ladders: []const []const u32) i64 {
    if (finest_covering_cscl <= 0 or finest_covering_cscl == std.math.maxInt(i32)) return 0;
    if (group_min_cscl > 0 and finest_covering_cscl >= group_min_cscl) return 0;
    return bake_enc.quantizeHandoff(ladders, finest_covering_cscl);
}

/// Per-feature scale-window eligibility (spec model §1): a feature with
/// `effective` scamin (+ optional `smax` cap) enters tile zoom z iff it can be
/// visible somewhere in the tile's display window [D(z), D(z+1)):
///   scamin >= D(z+1)            — the window's fine end reaches the feature
///   smax == 0 or smax < D(z)    — the cap hasn't swallowed the whole window
/// `floor_denom` is D(z+1, tile_lat) (assets.displayDenomZ; D(z) = 2·D(z+1)).
pub fn eligibleAt(effective: i64, smax: i64, floor_denom: f64) bool {
    if (@as(f64, @floatFromInt(effective)) < floor_denom) return false;
    if (smax > 0 and @as(f64, @floatFromInt(smax)) >= floor_denom * 2.0) return false;
    return true;
}

/// One cell's pre-pass scan: its matchable records plus what the cap
/// computation needs from OTHER cells at each winner's point (real M_COVR
/// coverage + the scamin ladder). Everything is allocated in the scan's own
/// allocator so the parsed cell can be freed right after scanning.
pub const CellScan = struct {
    recs: []Rec = &.{},
    coverage: []const []const []const s57.LonLat = &.{},
    cov_bounds: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 }, // bbox over the coverage rings
    ladder: []const u32 = &.{}, // distinct SCAMIN denoms, ascending (collectScamins)
    cscl: i32 = 0,
};

/// Scan one parsed cell for the pre-pass (bake drivers run this per cell, in
/// parallel, then free the cell). Allocates everything in `a`.
pub fn scanCell(a: Allocator, cell: *const s57.Cell, cell_idx: u32) !CellScan {
    const cscl = cell.params.cscl;
    var s = CellScan{
        .recs = try collectRecs(a, cell, cscl, cell_idx),
        .coverage = cell.mcovrCoverage(a),
        .ladder = try bake_enc.collectScamins(a, cell),
        .cscl = cscl,
    };
    for (s.coverage) |rings| for (rings) |ring| for (ring) |p| {
        s.cov_bounds[0] = @min(s.cov_bounds[0], p.lon());
        s.cov_bounds[1] = @min(s.cov_bounds[1], p.lat());
        s.cov_bounds[2] = @max(s.cov_bounds[2], p.lon());
        s.cov_bounds[3] = @max(s.cov_bounds[3], p.lat());
    };
    return s;
}

/// Dedup the union of all scans' records and derive each winner's MiniEntry:
/// effective scamin from the group union, smax cap from the finest OTHER chart
/// really covering the point (capFor; the winner's own cscl IS the group's
/// finest — winners are elected finest-first). Returns per-cell entry lists
/// indexed by cell ordinal (`n_cells` slots; empty = no winners). Allocates
/// results in `a`; `gpa` is transient working memory.
pub fn resolveWinners(gpa: Allocator, a: Allocator, scans: []const CellScan, n_cells: usize) ![][]MiniEntry {
    var all = std.ArrayList(Rec).empty;
    for (scans) |s| try all.appendSlice(a, s.recs);
    try dedup(gpa, all.items);

    var lists = try a.alloc(std.ArrayList(MiniEntry), n_cells);
    for (lists) |*l| l.* = std.ArrayList(MiniEntry).empty;
    var ladders = std.ArrayList([]const u32).empty; // covering ladders, reused per winner
    for (all.items) |r| {
        if (!r.winner) continue;
        // Finest covering compilation scale at the point (real M_COVR only —
        // the fills/points rule) + the covering cells' ladders for quantizing.
        var finest: i32 = std.math.maxInt(i32);
        ladders.clearRetainingCapacity();
        for (scans) |s| {
            if (s.cscl <= 0 or s.coverage.len == 0) continue;
            if (r.lon < s.cov_bounds[0] or r.lon > s.cov_bounds[2] or
                r.lat < s.cov_bounds[1] or r.lat > s.cov_bounds[3]) continue;
            if (!s57.coverageContains(s.coverage, r.lon, r.lat)) continue;
            finest = @min(finest, s.cscl);
            try ladders.append(a, s.ladder);
        }
        const cap = capFor(r.cscl, finest, ladders.items);
        if (r.cell < n_cells)
            try lists[r.cell].append(a, .{ .feat = r.feat, .lon = r.lon, .lat = r.lat, .effective = r.effective, .smax = cap });
    }
    const out = try a.alloc([]MiniEntry, n_cells);
    for (lists, 0..) |*l, i| out[i] = l.items;
    return out;
}

/// One winner going into a mini cell: the source feature index, its (winner
/// copy) position, the group's effective scamin and smax cap.
pub const MiniEntry = struct {
    feat: u32,
    lon: f64,
    lat: f64,
    effective: u32,
    smax: i64 = 0,
};

/// A synthetic cell carrying one source cell's deduped SCAMIN point features,
/// ready to ride tile generation as a scene.CellRef with `scamin_floor` set:
/// every feature is a prim==1 copy of the winner (attrs deep-copied, SCAMIN
/// rewritten to the effective union value) anchored at a single VI node.
/// Everything is allocated in the arena given to buildMini — do NOT call
/// cell.deinit(); drop the arena instead.
pub const Mini = struct {
    cell: s57.Cell,
    portrayal: ?[]const ?[]const u8 = null,
    portrayal_simplified: ?[]const ?[]const u8 = null,
    feat_smax: []const i64 = &.{}, // per-feature smax cap (0 = none)
    feat_bbox: []const ?[4]f64 = &.{},
    bounds: [4]f64,
};

/// Build a mini cell for `entries` (winners from ONE source cell). `base` /
/// `simplified` are the SOURCE cell's per-feature instruction streams (indexed
/// by source feature index; null = none) — the mini borrows each winner's
/// stream by COPY into `a`, so the source cell may be freed afterwards. The
/// SCAMIN attribute is rewritten to the effective value so featureScamin (and
/// the emitted `scamin` tile property) carry the union.
pub fn buildMini(
    a: Allocator,
    src: *const s57.Cell,
    entries: []const MiniEntry,
    base: ?[]const ?[]const u8,
    simplified: ?[]const ?[]const u8,
) !Mini {
    const feats = try a.alloc(s57.Feature, entries.len);
    const p_base = try a.alloc(?[]const u8, entries.len);
    const p_simp = try a.alloc(?[]const u8, entries.len);
    const smax = try a.alloc(i64, entries.len);
    const bbox = try a.alloc(?[4]f64, entries.len);
    var nodes = std.AutoHashMap(u64, s57.LonLat).init(a);
    var b = [4]f64{ 1e9, 1e9, -1e9, -1e9 };

    for (entries, 0..) |e, i| {
        const sf = src.features[e.feat];
        const attrs = try a.alloc(s57.Attr, sf.attrs.len);
        for (sf.attrs, 0..) |at, j| {
            if (at.code == 133) { // SCAMIN -> the group's effective (union) value
                attrs[j] = .{ .code = at.code, .value = try std.fmt.allocPrint(a, "{d}", .{e.effective}) };
            } else {
                attrs[j] = .{ .code = at.code, .value = try a.dupe(u8, at.value) };
            }
        }
        const rcid: u32 = @intCast(i + 1);
        const refs = try a.alloc(s57.SpatialRef, 1);
        refs[0] = .{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = rcid }, .ornt = 255 };
        feats[i] = .{
            .rcnm = sf.rcnm,
            .rcid = sf.rcid, // keep the source RCID (pick-report identity)
            .prim = 1,
            .objl = sf.objl,
            .foid = sf.foid,
            .refs = refs,
            .attrs = attrs,
        };
        try nodes.put((@as(u64, s57.RCNM_VI) << 32) | rcid, s57.LonLat.init(e.lon, e.lat));
        p_base[i] = if (base) |bs| (if (e.feat < bs.len and bs[e.feat] != null) try a.dupe(u8, bs[e.feat].?) else null) else null;
        p_simp[i] = if (simplified) |ss| (if (e.feat < ss.len and ss[e.feat] != null) try a.dupe(u8, ss[e.feat].?) else null) else null;
        smax[i] = e.smax;
        bbox[i] = .{ e.lon, e.lat, e.lon, e.lat };
        b[0] = @min(b[0], e.lon);
        b[1] = @min(b[1], e.lat);
        b[2] = @max(b[2], e.lon);
        b[3] = @max(b[3], e.lat);
    }

    return .{
        .cell = .{
            .params = .{ .cscl = src.params.cscl },
            .name = try a.dupe(u8, src.name),
            .vectors = &.{},
            .features = feats,
            .nodes = nodes,
            .edges = std.AutoHashMap(u32, usize).init(a),
            .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
            .arena = std.heap.ArenaAllocator.init(a),
        },
        .portrayal = p_base,
        .portrayal_simplified = p_simp,
        .feat_smax = smax,
        .feat_bbox = bbox,
        .bounds = b,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn rec(lon: f64, lat: f64, scamin: u32, objl: u16, foid: u64, mkey: u64, cell: u32, feat: u32, cscl: i32) Rec {
    return .{ .lon = lon, .lat = lat, .scamin = scamin, .objl = objl, .foid = foid, .mkey = mkey, .cell = cell, .feat = feat, .rcid = feat + 1, .cscl = cscl };
}

test "dedup: FOID chain collapses to the finest copy with MAX scamin" {
    // The Chesapeake acceptance chain: US3 499999 / US4 119999 / US5 29999,
    // identical positions, one FOID.
    var recs = [_]Rec{
        rec(-76.4261103, 38.9418108, 499_999, 75, 0xABCD, 1, 0, 0, 380_000),
        rec(-76.4261103, 38.9418108, 119_999, 75, 0xABCD, 1, 1, 0, 80_000),
        rec(-76.4261103, 38.9418108, 29_999, 75, 0xABCD, 1, 2, 0, 25_000),
    };
    try dedup(testing.allocator, &recs);
    for (recs) |r| try testing.expectEqual(@as(u32, 499_999), r.effective);
    try testing.expect(!recs[0].winner and !recs[1].winner and recs[2].winner);
}

test "dedup: different FOIDs at distance keep their own scamin" {
    // Two distinct gate buoys 23 m apart (same class, different FOID + colour).
    var recs = [_]Rec{
        rec(-76.470000, 38.900000, 29_999, 17, 0x1111, 100, 0, 0, 25_000),
        rec(-76.470240, 38.900050, 39_999, 17, 0x2222, 200, 1, 1, 25_000),
    };
    try dedup(testing.allocator, &recs);
    try testing.expectEqual(@as(u32, 29_999), recs[0].effective);
    try testing.expectEqual(@as(u32, 39_999), recs[1].effective);
    try testing.expect(recs[0].winner and recs[1].winner);
}

test "dedup: FOID guard refuses a far-apart identity" {
    var recs = [_]Rec{
        rec(-76.0, 38.0, 29_999, 75, 0xF00D, 1, 0, 0, 25_000),
        rec(-76.1, 38.0, 499_999, 75, 0xF00D, 1, 1, 1, 380_000), // ~8.7 km away
    };
    try dedup(testing.allocator, &recs);
    try testing.expect(recs[0].winner and recs[1].winner); // two groups
    try testing.expectEqual(@as(u32, 29_999), recs[0].effective);
}

test "dedup: FOID-less fallback matches by class+key+epsilon, splits on key" {
    // Copies 10 m apart with the same discriminator key merge; a same-position
    // record with a DIFFERENT light character stays its own object.
    var recs = [_]Rec{
        rec(-76.50, 38.90, 29_999, 75, 0, 0xAA, 10, 0, 25_000),
        rec(-76.50009, 38.90, 499_999, 75, 0, 0xAA, 10, 1, 380_000), // ~8 m
        rec(-76.50, 38.90, 119_999, 75, 0, 0xBB, 10, 2, 25_000), // different key
    };
    try dedup(testing.allocator, &recs);
    try testing.expectEqual(@as(u32, 499_999), recs[0].effective);
    try testing.expectEqual(@as(u32, 499_999), recs[1].effective);
    try testing.expectEqual(@as(u32, 119_999), recs[2].effective);
    try testing.expect(recs[0].winner and !recs[1].winner and recs[2].winner);
}

test "winner tie-break is path-independent (never the cell ordinal)" {
    // Same cscl copies listed in opposite orders must elect the same winner.
    var fwd = [_]Rec{
        rec(-76.50, 38.90, 29_999, 75, 0xC0FFEE, 0, 0, 0, 25_000),
        rec(-76.50, 38.90, 39_999, 75, 0xC0FFEE, 1, 1, 1, 25_000),
    };
    var rev = [_]Rec{ fwd[1], fwd[0] };
    rev[0].cell = 0;
    rev[1].cell = 1;
    try dedup(testing.allocator, &fwd);
    try dedup(testing.allocator, &rev);
    // The larger-scamin copy wins the tie in both orders.
    try testing.expect(fwd[1].winner and !fwd[0].winner);
    try testing.expect(rev[0].winner and !rev[1].winner);
}

test "capFor: finer covering chart caps at the quantized handoff; own-finest doesn't" {
    const fine = [_]u32{260_000};
    const ladders = [_][]const u32{&fine};
    // Group's finest copy is 1:380k, but a 1:200k chart covers the point ->
    // hand off at the 260k crossing (quantized up onto the fine ladder).
    try testing.expectEqual(@as(i64, 260_000), capFor(380_000, 200_000, &ladders));
    // The group's own finest copy IS the finest covering chart: no cap.
    try testing.expectEqual(@as(i64, 0), capFor(200_000, 200_000, &ladders));
    try testing.expectEqual(@as(i64, 0), capFor(25_000, std.math.maxInt(i32), &ladders));
    // No ladder value reaches the fine scale: raw-cscl fallback (quantizeHandoff).
    try testing.expectEqual(@as(i64, 40_000), capFor(380_000, 40_000, &.{}));
}

test "eligibleAt: scamin floor and smax ceiling clamp the tile window" {
    // Window [D(z), D(z+1)) with D(z+1) = 100k, D(z) = 200k.
    const floor: f64 = 100_000;
    try testing.expect(eligibleAt(499_999, 0, floor)); // well above the floor
    try testing.expect(eligibleAt(100_000, 0, floor)); // boundary: scamin == D(z+1)
    try testing.expect(!eligibleAt(99_999, 0, floor)); // below the window
    try testing.expect(eligibleAt(499_999, 150_000, floor)); // cap inside the window: coarse part still shows
    try testing.expect(!eligibleAt(499_999, 200_000, floor)); // cap swallows the window (smax >= D(z))
    try testing.expect(!eligibleAt(499_999, 260_000, floor)); // cap above the window
}

test "buildMini: SCAMIN attr rewritten to the union; node + streams wired" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const attrs = [_]s57.Attr{
        .{ .code = 133, .value = "29999" }, // SCAMIN
        .{ .code = s57.ATTR_COLOUR, .value = "3" },
    };
    const feats = [_]s57.Feature{.{
        .rcnm = 100,
        .rcid = 4238,
        .prim = 1,
        .objl = 75,
        .foid = 0xABCD,
        .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 9 }, .ornt = 255 }},
        .attrs = &attrs,
    }};
    var src = s57.Cell{
        .params = .{ .cscl = 25_000 },
        .name = "US5MD1MC",
        .vectors = &.{},
        .features = &feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = std.AutoHashMap(u32, usize).init(a),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(a),
    };
    const streams = [_]?[]const u8{"DrawingPriority:8;PointInstruction:LIGHTS11"};

    const entries = [_]MiniEntry{.{ .feat = 0, .lon = -76.4261103, .lat = 38.9418108, .effective = 499_999, .smax = 0 }};
    const mini = try buildMini(a, &src, &entries, &streams, null);

    try testing.expectEqual(@as(usize, 1), mini.cell.features.len);
    const mf = mini.cell.features[0];
    try testing.expectEqual(@as(?i64, 499_999), scene.featureScamin(mf)); // union rewrote SCAMIN
    try testing.expectEqualStrings("3", mf.attr(s57.ATTR_COLOUR).?); // other attrs copied
    try testing.expectEqual(@as(u32, 4238), mf.rcid);
    const pg = mini.cell.pointGeometry(mf).?;
    try testing.expectApproxEqAbs(@as(f64, -76.4261103), pg.lon(), 1e-6);
    try testing.expectEqualStrings("DrawingPriority:8;PointInstruction:LIGHTS11", mini.portrayal.?[0].?);
    try testing.expectEqual(@as(i64, 0), mini.feat_smax[0]);
    try testing.expectEqualStrings("US5MD1MC", mini.cell.name);
}
