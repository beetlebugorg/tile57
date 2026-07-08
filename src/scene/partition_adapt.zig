//! S-57 → ownership-partition adapter, plus a real-ENC de-risk probe.
//!
//! Fills `geo.plane.Cell` (the pure partition input) from parsed S-57 cells: the
//! M_COVR(CATCOV=1) coverage rings — whose integer lon/lat (degrees × 10⁷) widen
//! from i32 to i64 — plus the compilation scale, the band floor, and the
//! deterministic equal-scale tie-break order.
//!
//! The probe test (gated on a real ENC district being present) answers the three
//! questions the design review flagged as unproven before we commit to building
//! the whole module on `plane.ownedAtTier`:
//!   1. SLIVERS — do independently-digitised adjacent cells produce sliver
//!      overlaps/gaps at their shared seam? Measured area-exact: Σ(face areas)
//!      vs area(union of all eligible coverage). A true partition makes them equal.
//!   2. PERFORMANCE — how long does the naive `ownedAtTier` (global-union operands,
//!      no bbox reject / no prune) take on a real district? Is a spatial index
//!      required for Step 1, or a later optimisation?
//!   3. ORACLE AGREEMENT — does the integer partition assign the same owner as
//!      the live float M_COVR oracle (`s57.coverageContains`) at sampled points?

const std = @import("std");
const s57 = @import("s57");
const geo = @import("geo");
const plane = geo.plane;
const boolean = geo.boolean;

const Pt = plane.Pt;
const Poly = plane.Poly; // []const []const Pt — one M_COVR feature's rings

// ---------------------------------------------------------------------------
// Band rules — mirror scene/bake_enc.zig bandOf/bandZooms exactly. Kept local so
// this file imports only s57+geo (fast, isolated probe build). The production
// adapter will call bake_enc directly to avoid two encodings drifting.
// ---------------------------------------------------------------------------

/// The lowest zoom at which a cell of this compilation scale participates — its
/// band floor. Matches bandZooms(bandOf(cscl)).min.
pub fn bandFloor(cscl: i32) u8 {
    const n: i64 = if (cscl <= 0) 50_000 else cscl;
    if (n <= 8_000) return 16; // berthing
    if (n <= 32_000) return 13; // harbor
    if (n <= 130_000) return 11; // approach
    if (n <= 500_000) return 9; // coastal
    if (n <= 2_300_000) return 7; // general
    return 0; // overview
}

/// Band rank 0=berthing (finest) .. 5=overview (coarsest), for labels/colour.
pub fn bandRank(cscl: i32) u8 {
    const n: i64 = if (cscl <= 0) 50_000 else cscl;
    if (n <= 8_000) return 0;
    if (n <= 32_000) return 1;
    if (n <= 130_000) return 2;
    if (n <= 500_000) return 3;
    if (n <= 2_300_000) return 4;
    return 5;
}

/// Equal-scale tie-break, identical to bake_enc.ordersBefore: newer DSID
/// issue/update date first (YYYYMMDD lexical; a dated cell before an undated one),
/// then cell name ascending — a total, deterministic order.
pub fn ordersBefore(da: []const u8, na: []const u8, db: []const u8, nb: []const u8) bool {
    if (!std.mem.eql(u8, da, db)) return std.mem.lessThan(u8, db, da); // newer first
    return std.mem.lessThan(u8, na, nb);
}

/// Widen a cell's M_COVR rings — integer lon/lat in degrees × 10⁷ (i32) — to the
/// boolean i64 point type. One output Poly per M_COVR feature (its rings).
/// Allocated in `a`.
pub fn widenCoverage(a: std.mem.Allocator, cov: []const []const []const s57.LonLat) ![]Poly {
    var out = try a.alloc(Poly, cov.len);
    for (cov, 0..) |feat, fi| {
        const rings = try a.alloc([]const Pt, feat.len);
        for (feat, 0..) |ring, ri| {
            const pts = try a.alloc(Pt, ring.len);
            for (ring, 0..) |p, pi| pts[pi] = .{ .x = p.lon_e7, .y = p.lat_e7 };
            rings[ri] = pts;
        }
        out[fi] = rings;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Area (shoelace, exact i128 → f64) — for the sliver conservation check.
// ---------------------------------------------------------------------------

fn ringArea2(ring: []const Pt) i128 {
    if (ring.len < 3) return 0;
    var acc: i128 = 0;
    var j = ring.len - 1;
    for (ring, 0..) |p, i| {
        const q = ring[j];
        j = i;
        acc += (@as(i128, q.x) * p.y) - (@as(i128, p.x) * q.y);
    }
    return acc; // 2*signed area
}

/// Net area of one even-odd polygon (exterior CCW +, holes CW −, disjoint pieces
/// add) as f64. `rings` is a single polygon's ring set ([][]Pt from a face or a
/// boolean result).
fn polyArea(rings: []const []const Pt) f64 {
    var acc: i128 = 0;
    for (rings) |ring| acc += ringArea2(ring);
    const a: f64 = @floatFromInt(if (acc < 0) -acc else acc);
    return a / 2.0;
}

// ===========================================================================
// De-risk probe — real ENC district. Skipped unless the district dir exists.
// ===========================================================================

const testing = std.testing;

// A real ENC district to validate against. Override with TILE57_PROBE_ROOT; the
// default is a NOAA District 1 tree on the dev box (the old ~/.local corpus moved).
const PROBE_ROOT_DEFAULT = "/home/jcollins/Charts/enc-src/d01/ENC_ROOT";
// Which scale bands to load, by cell-name prefix. US2=overview, US3=coastal,
// US4=approach, US5=harbor. Start coarse (few, fast) — includes cross-band
// overlap (US2 under US3) AND same-band adjacency (US3↔US3).
const PROBE_PREFIXES = [_][]const u8{"US5"}; // harbor: densest same-band adjacency
const PROBE_CAP: usize = 250; // bound the parse cost; also stresses the O(cells^2) build
const PROBE_TIER: u8 = 13; // harbor floor — all loaded US5 eligible

const ProbeCell = struct {
    name: []const u8,
    cscl: i32,
    date: []const u8,
    cov_ll: []const []const []const s57.LonLat, // float rings, for the oracle
    bbox: [4]f64, // w,s,e,n degrees
};

fn hasPrefix(name: []const u8) bool {
    for (PROBE_PREFIXES) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

test "PROBE: ownership partition on a real ENC district (slivers, perf, oracle)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = PROBE_ROOT_DEFAULT;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
        std.debug.print("\n[probe] district {s} not present — skipping\n", .{root});
        return;
    };
    defer dir.close(io);

    // --- Load matching cells: parse .000, extract M_COVR, keep float rings + bbox.
    var pcells = std.ArrayList(ProbeCell).empty;
    var walker = dir.walk(a) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (pcells.items.len >= PROBE_CAP) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".000")) continue;
        const base = std.fs.path.basename(entry.path);
        const name = base[0 .. base.len - 4];
        if (!hasPrefix(name)) continue;

        const bytes = dir.readFileAlloc(io, entry.path, a, .unlimited) catch continue;
        var cell = s57.parseCell(a, bytes) catch continue;
        defer cell.deinit();
        const cov = cell.mcovrCoverage(a); // copied into `a`; survives deinit
        if (cov.len == 0) continue; // no-M_COVR cell: separate case, skip in probe

        var b = [4]f64{ 1e9, 1e9, -1e9, -1e9 };
        for (cov) |rings| for (rings) |ring| for (ring) |p| {
            b[0] = @min(b[0], p.lon());
            b[1] = @min(b[1], p.lat());
            b[2] = @max(b[2], p.lon());
            b[3] = @max(b[3], p.lat());
        };
        pcells.append(a, .{
            .name = try a.dupe(u8, name),
            .cscl = cell.params.cscl,
            .date = try a.dupe(u8, cell.dsid.isdt),
            .cov_ll = cov,
            .bbox = b,
        }) catch {};
    }

    const n = pcells.items.len;
    if (n == 0) {
        std.debug.print("\n[probe] no matching cells with M_COVR — skipping\n", .{});
        return;
    }

    // --- Deterministic `order`: rank cells by ordersBefore (newer/name).
    const idx = try a.alloc(usize, n);
    for (idx, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, idx, pcells.items, struct {
        fn lt(cs: []const ProbeCell, x: usize, y: usize) bool {
            return ordersBefore(cs[x].date, cs[x].name, cs[y].date, cs[y].name);
        }
    }.lt);
    const order = try a.alloc(u64, n);
    for (idx, 0..) |ci, rank| order[ci] = rank;

    // --- Build geo.plane.Cell[] (widen M_COVR coverage to i64 points).
    const cells = try a.alloc(plane.Cell, n);
    for (pcells.items, 0..) |pc, i| {
        cells[i] = .{
            .cscl = pc.cscl,
            .band_floor = bandFloor(pc.cscl),
            .order = order[i],
            .cov1 = try widenCoverage(a, pc.cov_ll),
        };
    }

    // Eligible set at the probe tier (matches ownedAtTier's rule).
    var n_elig: usize = 0;
    for (cells) |c| if (c.band_floor <= PROBE_TIER) {
        n_elig += 1;
    };

    // --- BUILD (timed). Naive global-union kernel: no bbox reject, no prune.
    const t0 = std.Io.Clock.now(.awake, io);
    const faces = try plane.ownedAtTier(a, cells, PROBE_TIER);
    const build_ms: f64 = @as(f64, @floatFromInt((std.Io.Clock.now(.awake, io).nanoseconds - t0.nanoseconds))) / 1e6;

    // --- SLIVER check: Σ(face area) vs area(union of all eligible coverage).
    var sum_faces: f64 = 0;
    for (faces) |f| sum_faces += polyArea(f.owned);

    var elig_polys = std.ArrayList(Poly).empty;
    for (cells) |c| if (c.band_floor <= PROBE_TIER) {
        for (c.cov1) |feat| try elig_polys.append(a, feat);
    };
    const uni = try boolean.unionAll(a, elig_polys.items);
    const union_area = polyArea(uni);
    const conservation = if (union_area > 0) sum_faces / union_area else 0;

    // Definitive area-exact check (robust to shoelace/winding): symmetric
    // difference of (∪ faces) vs (∪ eligible coverage). A perfect partition has
    // ZERO symdiff; nonzero = real lost/gained area (slivers) invisible to points.
    var face_polys = std.ArrayList(plane.Poly).empty;
    for (faces) |f| if (f.owned.len > 0) {
        try face_polys.append(a, f.owned);
    };
    const uni_faces = try boolean.unionAll(a, face_polys.items);
    const sd = try boolean.compute(a, uni_faces, uni, .sym_diff);
    const symdiff_area = polyArea(sd);
    const symdiff_ppm = if (union_area > 0) 1e6 * symdiff_area / union_area else 0;

    // --- ORACLE agreement: sample the union bbox; compare partition owner (integer
    // even-odd over faces) to the float finest-cscl-covering oracle.
    var wb = [4]f64{ 1e9, 1e9, -1e9, -1e9 };
    for (pcells.items) |pc| {
        wb[0] = @min(wb[0], pc.bbox[0]);
        wb[1] = @min(wb[1], pc.bbox[1]);
        wb[2] = @max(wb[2], pc.bbox[2]);
        wb[3] = @max(wb[3], pc.bbox[3]);
    }
    const GRID = 120;
    var samples: usize = 0;
    var overlaps: usize = 0;
    var matches: usize = 0;
    var mismatches: usize = 0;
    var mismatch_same_scale: usize = 0; // seam tiebreak / edge-proximity (benign)
    var mismatch_diff_scale: usize = 0; // real overlap-resolution divergence
    var part_gap_oracle_owns: usize = 0; // oracle owns, partition says gap
    var gy: usize = 0;
    while (gy < GRID) : (gy += 1) {
        var gx: usize = 0;
        while (gx < GRID) : (gx += 1) {
            const lon = wb[0] + (wb[2] - wb[0]) * (@as(f64, @floatFromInt(gx)) + 0.5) / GRID;
            const lat = wb[1] + (wb[3] - wb[1]) * (@as(f64, @floatFromInt(gy)) + 0.5) / GRID;
            const xe: i64 = @intFromFloat(@round(lon * 1e7));
            const ye: i64 = @intFromFloat(@round(lat * 1e7));

            // Partition owner (integer): faces containing the point.
            var pj_owner: ?usize = null;
            var pj_count: usize = 0;
            for (faces) |f| {
                if (boolean.pointInEvenOdd(f.owned, xe, ye)) {
                    pj_count += 1;
                    pj_owner = f.index;
                }
            }
            // Oracle owner (float): finest eligible covering cell, broken by the
            // SAME (cscl, then DSID order) rule the partition uses — so a same-scale
            // adjacency seam is not a spurious mismatch, isolating true divergence.
            var or_owner: ?usize = null;
            for (pcells.items, 0..) |pc, i| {
                if (cells[i].band_floor > PROBE_TIER) continue;
                if (!s57.coverageContains(pc.cov_ll, lon, lat)) continue;
                if (or_owner) |cur| {
                    const finer = pc.cscl < pcells.items[cur].cscl or
                        (pc.cscl == pcells.items[cur].cscl and order[i] < order[cur]);
                    if (finer) or_owner = i;
                } else or_owner = i;
            }

            if (or_owner == null and pj_owner == null) continue; // both agree: gap
            samples += 1;
            if (pj_count > 1) overlaps += 1;
            if (or_owner != null and pj_owner == null) {
                part_gap_oracle_owns += 1;
            } else if (pj_owner == or_owner) {
                matches += 1;
            } else {
                mismatches += 1;
                // Same-scale mismatch = a seam tiebreak/edge-proximity artifact;
                // different-scale = a real overlap-resolution divergence to chase.
                if (pj_owner != null and or_owner != null and
                    pcells.items[pj_owner.?].cscl == pcells.items[or_owner.?].cscl)
                    mismatch_same_scale += 1
                else
                    mismatch_diff_scale += 1;
            }
        }
    }

    // --- Report.
    std.debug.print(
        \\
        \\========== ownership-partition PROBE ({s}) ==========
        \\ cells loaded ....... {d}   eligible@z{d} ... {d}
        \\ faces (owners) ..... {d}
        \\ BUILD (naive kernel)  {d:.1} ms   ({d:.2} ms/eligible-cell)
        \\ SLIVER check:
        \\   Σ face area ...... {e:.3}
        \\   union area ....... {e:.3}
        \\   conservation ..... {d:.6}   (shoelace Σ/union — UNRELIABLE for multi-piece faces; see symdiff)
        \\   symdiff (faces△cov) {d:.1} ppm of union area   (AUTHORITATIVE: 0 == exact partition, >0 == real slivers)
        \\ ORACLE agreement (float M_COVR, {d} owned samples):
        \\   matches .......... {d}
        \\   mismatches ....... {d}   (same-scale {d} = seam tiebreak/edge; diff-scale {d} = real divergence)
        \\   partition-overlap  {d}   (>1 owner at a point — MUST be 0)
        \\   partition-gap ..... {d}   (oracle owns, partition empty)
        \\====================================================
        \\
    , .{
        root,       n,          PROBE_TIER,          n_elig,
        faces.len,  build_ms,   build_ms / @as(f64, @floatFromInt(@max(1, n_elig))),
        sum_faces,  union_area, conservation,        symdiff_ppm,
        samples,    matches,    mismatches,          mismatch_same_scale,
        mismatch_diff_scale,    overlaps,            part_gap_oracle_owns,
    });

    // Guardrails: the partition must never double-own a point, and the union of
    // owned faces must equal the union of coverage (area-exact — the gate point
    // sampling cannot provide). Adjacent cells' shared borders round to the same
    // integers, so the boolean set algebra is exact and slivers must stay below a
    // tiny fraction of a percent.
    try testing.expectEqual(@as(usize, 0), overlaps);
    try testing.expectEqual(@as(usize, 0), part_gap_oracle_owns);
    try testing.expect(symdiff_ppm < 100.0); // < 0.01% of union area
}
