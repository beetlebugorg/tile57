//! S-57 model (geometry foundation). Interprets ISO 8211 records into dataset
//! parameters, vector (spatial) records with real lon/lat, and feature record
//! metadata. Port of the core of internal/s57/parser.
//!
//! This is the M6b foundation: DSPM coordinate factors, VRID/SG2D/SG3D
//! coordinates, and FRID feature headers (object class). Topological assembly
//! (features -> edges -> rings) and attributes come next.
//!
//! Spec: IHO S-57 Part 3 (31Main.pdf).

const std = @import("std");
const Allocator = std.mem.Allocator;
const iso = @import("iso8211");

// Geographic coordinate stored in S-57's native integer ×1e7 units (lon ±1.8e9,
// lat ±9e8 both fit i32) — 8 bytes/point vs 16 for an f64 pair, lossless for the
// standard comf=1e7. Degrees are derived on access via lon()/lat().
pub const E7: f64 = 1e7;
pub const LonLat = struct {
    lon_e7: i32,
    lat_e7: i32,

    pub inline fn lon(self: LonLat) f64 {
        return @as(f64, @floatFromInt(self.lon_e7)) / E7;
    }
    pub inline fn lat(self: LonLat) f64 {
        return @as(f64, @floatFromInt(self.lat_e7)) / E7;
    }
    /// From degrees.
    pub inline fn init(lon_deg: f64, lat_deg: f64) LonLat {
        return .{ .lon_e7 = degToE7(lon_deg), .lat_e7 = degToE7(lat_deg) };
    }
};
pub const Sounding = struct {
    lon_e7: i32,
    lat_e7: i32,
    depth: f64,

    pub inline fn lon(self: Sounding) f64 {
        return @as(f64, @floatFromInt(self.lon_e7)) / E7;
    }
    pub inline fn lat(self: Sounding) f64 {
        return @as(f64, @floatFromInt(self.lat_e7)) / E7;
    }
    pub inline fn init(lon_deg: f64, lat_deg: f64, depth: f64) Sounding {
        return .{ .lon_e7 = degToE7(lon_deg), .lat_e7 = degToE7(lat_deg), .depth = depth };
    }
};
/// Degrees → ×1e7 integer, clamped to i32 (defends against corrupt out-of-range coords).
pub inline fn degToE7(deg: f64) i32 {
    const v = @round(deg * E7);
    if (v >= 2147483647.0) return 2147483647;
    if (v <= -2147483648.0) return -2147483648;
    return @intFromFloat(v);
}

/// Even-odd ray-cast: is (lon,lat) inside the polygon defined by `rings` (one
/// outer ring plus any holes, all in lon/lat)? A point inside a hole counts as
/// outside (the rings share one even-odd accumulator). Used for M_COVR
/// data-coverage containment in best-band suppression (mirrors Go pointInRings).
pub fn pointInRings(rings: []const []const LonLat, lon: f64, lat: f64) bool {
    var inside = false;
    for (rings) |ring| {
        if (ring.len < 3) continue;
        var j: usize = ring.len - 1;
        for (ring, 0..) |p, i| {
            const q = ring[j];
            if ((p.lat() > lat) != (q.lat() > lat) and
                lon < (q.lon() - p.lon()) * (lat - p.lat()) / (q.lat() - p.lat()) + p.lon())
            {
                inside = !inside;
            }
            j = i;
        }
    }
    return inside;
}

// --- Polygon geometry helpers (shared by MVT emission + portrayal) ----------

/// Area centroid (centre of gravity) of a single ring via the shoelace formula;
/// null for a degenerate (zero-area) ring. Raw lon/lat — the cos(lat) skew is
/// immaterial for a centring point over a chart-sized area. Edges wrap, so the
/// ring may be open or closed.
pub fn ringCentroid(ring: []const LonLat) ?LonLat {
    if (ring.len < 3) return null;
    var area2: f64 = 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    var i: usize = 0;
    while (i < ring.len) : (i += 1) {
        const j = (i + 1) % ring.len;
        const cross = ring[i].lon() * ring[j].lat() - ring[j].lon() * ring[i].lat();
        area2 += cross;
        cx += (ring[i].lon() + ring[j].lon()) * cross;
        cy += (ring[i].lat() + ring[j].lat()) * cross;
    }
    if (@abs(area2) < 1e-12) return null;
    const a6 = 3.0 * area2; // 6 * (signed area = area2 / 2)
    return LonLat.init(cx / a6, cy / a6);
}

/// Even-odd point-in-polygon over the union of rings (exterior boundary + holes):
/// inside the exterior AND outside every hole.
pub fn pointInRingsEvenOdd(lon: f64, lat: f64, rings: []const []LonLat) bool {
    var inside = false;
    for (rings) |ring| {
        if (ring.len < 2) continue;
        var j: usize = ring.len - 1;
        var i: usize = 0;
        while (i < ring.len) : (i += 1) {
            const a = ring[i];
            const b = ring[j];
            if ((a.lat() > lat) != (b.lat() > lat) and
                lon < (b.lon() - a.lon()) * (lat - a.lat()) / (b.lat() - a.lat()) + a.lon())
            {
                inside = !inside;
            }
            j = i;
        }
    }
    return inside;
}

// The pole-of-inaccessibility search below (areaRepresentativePoint and its PlCell
// quad-tree refinement) is a port of the Mapbox "polylabel" algorithm
// (https://github.com/mapbox/polylabel), ISC-licensed — see THIRD_PARTY_LICENSES.md.

/// One square candidate region in the polylabel search (longitude pre-scaled by kx).
const PlCell = struct {
    x: f64,
    y: f64,
    half: f64,
    d: f64, // signed distance from centre to the polygon (+ inside)
    max: f64, // upper bound on d anywhere in the cell (d + half*√2)
};

/// Max-heap order on PlCell.max — the most-promising cell pops first.
fn plCellOrder(_: void, a: PlCell, b: PlCell) std.math.Order {
    return std.math.order(b.max, a.max);
}

/// Euclidean distance from point (px,py) to segment a–b.
fn segDist(px: f64, py: f64, ax0: f64, ay0: f64, bx: f64, by: f64) f64 {
    var ax = ax0;
    var ay = ay0;
    const ex = bx - ax;
    const ey = by - ay;
    if (ex != 0 or ey != 0) {
        const t = ((px - ax) * ex + (py - ay) * ey) / (ex * ex + ey * ey);
        if (t > 1) {
            ax = bx;
            ay = by;
        } else if (t > 0) {
            ax += ex * t;
            ay += ey * t;
        }
    }
    const dx = px - ax;
    const dy = py - ay;
    return @sqrt(dx * dx + dy * dy);
}

/// Signed distance (positive inside) from scaled point (px,py) to the polygon: the
/// min distance to any edge of any ring, with the sign from even-odd inclusion.
/// Longitudes are pre-scaled by kx so distances are in roughly equal ground units.
fn polySignedDist(rings: []const []LonLat, kx: f64, px: f64, py: f64) f64 {
    var inside = false;
    var best: f64 = std.math.inf(f64);
    for (rings) |ring| {
        const n = ring.len;
        if (n == 0) continue;
        var j: usize = n - 1;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ax = ring[i].lon() * kx;
            const ay = ring[i].lat();
            const bx = ring[j].lon() * kx;
            const by = ring[j].lat();
            if ((ay > py) != (by > py) and px < (bx - ax) * (py - ay) / (by - ay) + ax) {
                inside = !inside;
            }
            const d = segDist(px, py, ax, ay, bx, by);
            if (d < best) best = d;
            j = i;
        }
    }
    return if (inside) best else -best;
}

fn plMkCell(rings: []const []LonLat, kx: f64, x: f64, y: f64, half: f64) PlCell {
    const SQRT2: f64 = 1.4142135623730951;
    const d = polySignedDist(rings, kx, x, y);
    return .{ .x = x, .y = y, .half = half, .d = d, .max = d + half * SQRT2 };
}

/// The representative point for an area's parts. S-52 PresLib §8.5.3: the centre of
/// gravity when it lies inside the area; otherwise (concave / holed shapes) the
/// "pole of inaccessibility" — the interior point farthest from any edge (the Mapbox
/// polylabel algorithm), so a centred symbol/label never lands outside the area or on
/// a hole. rings[0] is the exterior; rings[1:] are holes (even-odd containment over
/// all). Falls back to the vertex average for a degenerate ring or on OOM. Null with
/// no usable vertices.
pub fn areaRepresentativePoint(a: std.mem.Allocator, rings: []const []LonLat) ?LonLat {
    if (rings.len == 0 or rings[0].len == 0) return null;
    const ext = rings[0];
    if (ringCentroid(ext)) |c| {
        if (pointInRingsEvenOdd(c.lon(), c.lat(), rings)) return c;
    }

    var min_lat: f64 = std.math.inf(f64);
    var min_lon: f64 = std.math.inf(f64);
    var max_lat: f64 = -std.math.inf(f64);
    var max_lon: f64 = -std.math.inf(f64);
    var sum_lat: f64 = 0;
    var sum_lon: f64 = 0;
    for (ext) |p| {
        min_lat = @min(min_lat, p.lat());
        max_lat = @max(max_lat, p.lat());
        min_lon = @min(min_lon, p.lon());
        max_lon = @max(max_lon, p.lon());
        sum_lat += p.lat();
        sum_lon += p.lon();
    }
    const nf: f64 = @floatFromInt(ext.len);
    const mean = LonLat.init(sum_lon / nf, sum_lat / nf);

    var kx = @cos((min_lat + max_lat) / 2 * std.math.pi / 180.0);
    if (kx < 1e-9) kx = 1; // near-polar guard; charts don't reach here
    const x_min = min_lon * kx;
    const x_max = max_lon * kx;
    const w = x_max - x_min;
    const h = max_lat - min_lat;
    const cell_size = @min(w, h);
    if (cell_size <= 0) return mean; // zero-area / degenerate ring

    const precision = @max(w, h) / 200.0; // ~0.5% of the span
    const half = cell_size / 2.0;

    var best = plMkCell(rings, kx, (x_min + x_max) / 2, (min_lat + max_lat) / 2, 0);
    var pq = std.PriorityQueue(PlCell, void, plCellOrder).initContext({});
    defer pq.deinit(a);
    {
        var x = x_min;
        while (x < x_max) : (x += cell_size) {
            var y = min_lat;
            while (y < max_lat) : (y += cell_size) {
                pq.push(a, plMkCell(rings, kx, x + half, y + half, half)) catch return mean;
            }
        }
    }
    const max_cells = 20000; // safety cap for very large / high-vertex rings
    var processed: usize = 0;
    while (pq.pop()) |c| : (processed += 1) {
        if (c.d > best.d) best = c;
        if (c.max - best.d <= precision or processed >= max_cells) continue;
        const hh = c.half / 2;
        pq.push(a, plMkCell(rings, kx, c.x - hh, c.y - hh, hh)) catch break;
        pq.push(a, plMkCell(rings, kx, c.x + hh, c.y - hh, hh)) catch break;
        pq.push(a, plMkCell(rings, kx, c.x - hh, c.y + hh, hh)) catch break;
        pq.push(a, plMkCell(rings, kx, c.x + hh, c.y + hh, hh)) catch break;
    }
    return LonLat.init(best.x / kx, best.y);
}

test "area representative point centres on the centroid when inside" {
    const t = std.testing;
    // A wide rectangle (0,0)-(10,2): the centre of gravity is dead-centre.
    var rect = [_]LonLat{
        LonLat.init(0, 0),  LonLat.init(10, 0),
        LonLat.init(10, 2), LonLat.init(0, 2),
    };
    var parts = [_][]LonLat{rect[0..]};
    const rp = areaRepresentativePoint(t.allocator, parts[0..]).?;
    try t.expectApproxEqAbs(@as(f64, 5), rp.lon(), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1), rp.lat(), 1e-9);

    // Even-odd containment: centre inside, far point outside.
    try t.expect(pointInRingsEvenOdd(5, 1, parts[0..]));
    try t.expect(!pointInRingsEvenOdd(20, 1, parts[0..]));

    // A triangle's centroid is the mean of its three vertices.
    var tri = [_]LonLat{ LonLat.init(0, 0), LonLat.init(6, 0), LonLat.init(0, 6) };
    const c = ringCentroid(tri[0..]).?;
    try t.expectApproxEqAbs(@as(f64, 2), c.lon(), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 2), c.lat(), 1e-9);

    // A degenerate (collinear / 2-point) ring has no centroid.
    var deg = [_]LonLat{ LonLat.init(0, 0), LonLat.init(1, 1) };
    try t.expect(ringCentroid(deg[0..]) == null);
}

test "area representative point uses polylabel when the centroid falls outside" {
    const t = std.testing;
    // A "U" / C-shaped ring: the centre of gravity sits in the notch, OUTSIDE the
    // area, so the naive centroid (and a vertex average) would place a symbol off the
    // polygon. The polylabel pole of inaccessibility must land strictly inside.
    var u = [_]LonLat{
        LonLat.init(0, 0),  LonLat.init(10, 0), LonLat.init(10, 3), LonLat.init(3, 3),
        LonLat.init(3, 7),  LonLat.init(10, 7), LonLat.init(10, 10), LonLat.init(0, 10),
    };
    var parts = [_][]LonLat{u[0..]};
    const cen = ringCentroid(u[0..]).?;
    try t.expect(!pointInRingsEvenOdd(cen.lon(), cen.lat(), parts[0..])); // centroid is outside
    const rp = areaRepresentativePoint(t.allocator, parts[0..]).?;
    try t.expect(pointInRingsEvenOdd(rp.lon(), rp.lat(), parts[0..])); // chosen point is inside

    // A square with a central hole: the point must avoid the hole.
    var outer = [_]LonLat{ LonLat.init(0, 0), LonLat.init(20, 0), LonLat.init(20, 20), LonLat.init(0, 20) };
    var hole = [_]LonLat{ LonLat.init(7, 7), LonLat.init(13, 7), LonLat.init(13, 13), LonLat.init(7, 13) };
    var holed = [_][]LonLat{ outer[0..], hole[0..] };
    const hp = areaRepresentativePoint(t.allocator, holed[0..]).?;
    try t.expect(pointInRingsEvenOdd(hp.lon(), hp.lat(), holed[0..])); // inside outer, outside hole
}

// S-57 vector record names (RCNM).
pub const RCNM_VI: u8 = 110; // isolated node
pub const RCNM_VC: u8 = 120; // connected node
pub const RCNM_VE: u8 = 130; // edge
pub const RCNM_VF: u8 = 140; // face

pub const DatasetParams = struct {
    comf: i32 = 10_000_000, // coordinate multiplication factor (1e7)
    somf: i32 = 10, // sounding multiplication factor
    cscl: i32 = 0, // compilation scale (1:N)
};

pub const Name = struct { rcnm: u8, rcid: u32 };

pub const SpatialRef = struct {
    name: Name,
    ornt: u8, // 1=forward, 2=reverse, 255=null (FSPT)
    usag: u8 = 0, // USAG masking usage: 1=exterior, 2=interior, 3=exterior boundary truncated by data limit
    mask: u8 = 0, // MASK: 1=mask (edge not drawn), 2=show, 255=null
};

/// One VRPT pointer. The full list is retained so a VRPC-controlled partial modify
/// (.001+ update) is an indexed insert/delete/modify, not a wholesale replace.
pub const VPtr = struct { rcid: u32, topi: u8 }; // TOPI 1=begin, 2=end, 3=left, 4=right

pub const VectorRecord = struct {
    rcnm: u8,
    rcid: u32,
    points: []LonLat, // SG2D coordinates (node = 1 point; edge = interior chain)
    soundings: []Sounding, // SG3D (sounding nodes)
    begin_node: u32 = 0, // VRPT TOPI=1 (edges) — connected-node RCID (derived from vptrs)
    end_node: u32 = 0, // VRPT TOPI=2 (edges)
    vptrs: []const VPtr = &.{}, // full VRPT pointer list (for VRPC indexed edits)
    quapos: i32 = 0, // QUAPOS quality of position (S-57 spatial-level ATTV); 0 if absent
};

// S-57 attribute codes (Appendix A) used by portrayal.
pub const ATTR_DRVAL1: u16 = 87;
pub const ATTR_DRVAL2: u16 = 88;
pub const ATTR_VALSOU: u16 = 179;
pub const ATTR_VALDCO: u16 = 174;
pub const ATTR_OBJNAM: u16 = 116;
pub const ATTR_CATZOC: u16 = 72; // M_QUAL category of zone of confidence
pub const ATTR_QUAPOS: u16 = 402; // spatial-level quality of position (ATTV on edges/nodes)
pub const ATTR_ORIENT: u16 = 117; // orientation -> S-101 complex `orientation`
pub const ATTR_HORCLR: u16 = 98; // horizontal clearance -> horizontalClearanceFixed
pub const ATTR_VERCLR: u16 = 181; // vertical clearance -> verticalClearanceFixed
pub const ATTR_VERCCL: u16 = 182; // vertical clearance closed -> verticalClearanceClosed
pub const ATTR_VERCOP: u16 = 183; // vertical clearance open -> verticalClearanceOpen
pub const ATTR_TOPSHP: u16 = 171; // topmark/daymark shape -> topmark.topmarkDaymarkShape
pub const ATTR_COLOUR: u16 = 75; // colour -> topmark.colour (and the simple `colour`)
pub const ATTR_CATLIT: u16 = 37; // category of light -> LIGHTS class routing
pub const ATTR_CATMOR: u16 = 40; // category of mooring/warping facility -> MORFAC class routing
pub const ATTR_SECTR1: u16 = 136; // sector limit one (sectored light)
pub const ATTR_SECTR2: u16 = 137; // sector limit two (sectored light)

pub const OBJL_ADMARE: u16 = 1; // ADMARE: administration area
pub const OBJL_LIGHTS: u16 = 75; // LIGHTS: attribute-dependent class routing
pub const OBJL_MORFAC: u16 = 84; // MORFAC: mooring/warping facility (CATMOR-routed)
pub const OBJL_TOPMAR: u16 = 144; // TOPMAR: folded into its co-located buoy/beacon
pub const OBJL_TSELNE: u16 = 145; // TSELNE: traffic separation line -> SeparationZoneOrLine
pub const OBJL_TSEZNE: u16 = 150; // TSEZNE: traffic separation zone -> SeparationZoneOrLine

/// True for a QUAPOS that means "low accuracy" — S-52 draws such geometry DASHED
/// (approximate-position line style). I.e. present and not surveyed (1), precisely
/// known (10) or calculated (11). 0 means the attribute was absent.
pub fn isLowAccuracyQuapos(q: i32) bool {
    return q != 0 and q != 1 and q != 10 and q != 11;
}

/// True when any FSPT edge ref carries MASK/USAG masking info (S-52 §8.6.2). When
/// false the drawn geometry equals the full geometry, so callers keep the fast path
/// (the precomputed/full parts) instead of re-assembling a drawable subset.
pub fn hasBoundaryMaskInfo(f: Feature) bool {
    for (f.refs) |ref| {
        if (ref.name.rcnm != RCNM_VE) continue;
        if (ref.mask != 0 or ref.usag != 0) return true;
    }
    return false;
}

pub const Attr = struct { code: u16, value: []const u8 };

pub const Feature = struct {
    rcnm: u8,
    rcid: u32,
    prim: u8, // 1=point, 2=line, 3=area, 255=none
    objl: u16, // S-57 object class code
    refs: []const SpatialRef = &.{}, // FSPT spatial pointers
    attrs: []const Attr = &.{}, // ATTF attributes

    pub fn attr(self: Feature, code: u16) ?[]const u8 {
        for (self.attrs) |x| if (x.code == code) return x.value;
        return null;
    }

    pub fn attrFloat(self: Feature, code: u16) ?f64 {
        const v = self.attr(code) orelse return null;
        return std.fmt.parseFloat(f64, std.mem.trim(u8, v, " ")) catch null;
    }
};

pub const Cell = struct {
    params: DatasetParams,
    vectors: []VectorRecord,
    features: []const Feature,
    nodes: std.AutoHashMap(u64, LonLat), // (rcnm<<32|rcid) -> point (VI/VC)
    edges: std.AutoHashMap(u32, usize), // edge rcid -> index into vectors
    sounding_vecs: std.AutoHashMap(u64, usize), // (rcnm<<32|rcid) -> vector idx (SG3D nodes)
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Cell) void {
        self.nodes.deinit();
        self.edges.deinit();
        self.sounding_vecs.deinit();
        self.arena.deinit();
    }

    /// All soundings (lon/lat/depth) carried by a multipoint feature's
    /// referenced VI vector records (SG3D). Used for SOUNDG portrayal.
    pub fn soundingsFor(self: Cell, a: Allocator, f: Feature) ![]Sounding {
        var out = std.ArrayList(Sounding).empty;
        for (f.refs) |ref| {
            const key = (@as(u64, ref.name.rcnm) << 32) | ref.name.rcid;
            if (self.sounding_vecs.get(key)) |idx| {
                try out.appendSlice(a, self.vectors[idx].soundings);
            }
        }
        return out.items;
    }

    fn nodeCoord(self: Cell, rcid: u32) ?LonLat {
        const key_vc = (@as(u64, RCNM_VC) << 32) | rcid;
        if (self.nodes.get(key_vc)) |p| return p;
        const key_vi = (@as(u64, RCNM_VI) << 32) | rcid;
        return self.nodes.get(key_vi);
    }

    /// One edge's full coordinates: begin node + interior SG2D + end node,
    /// reversed if ornt==2. Returns a fresh slice (caller arena).
    fn edgeCoordsRaw(self: Cell, a: Allocator, edge_rcid: u32, ornt: u8) ![]LonLat {
        const idx = self.edges.get(edge_rcid) orelse return &.{};
        const e = self.vectors[idx];
        var tmp = std.ArrayList(LonLat).empty;
        if (e.begin_node != 0) {
            if (self.nodeCoord(e.begin_node)) |p| try tmp.append(a, p);
        }
        try tmp.appendSlice(a, e.points);
        if (e.end_node != 0) {
            if (self.nodeCoord(e.end_node)) |p| try tmp.append(a, p);
        }
        if (ornt == 2) std.mem.reverse(LonLat, tmp.items);
        return tmp.items;
    }

    /// Assemble a feature's line/area geometry into one or more connected parts.
    /// Edges are taken in FSPT order; a part is extended while each edge's start
    /// touches the current tail (the shared node is dropped), and a NEW part is
    /// started at any discontinuity. This keeps disjoint rings / multi-part
    /// geometry separate instead of joining them with a spurious straight jump
    /// across the cell (the cause of long crossing lines on areas like CTNARE).
    pub fn lineGeometryParts(self: Cell, a: Allocator, f: Feature) ![][]LonLat {
        var parts = std.ArrayList([]LonLat).empty;
        var cur = std.ArrayList(LonLat).empty;
        for (f.refs) |ref| {
            if (ref.name.rcnm != RCNM_VE) continue;
            const edge = try self.edgeCoordsRaw(a, ref.name.rcid, ref.ornt);
            if (edge.len == 0) continue;
            if (cur.items.len == 0) {
                try cur.appendSlice(a, edge);
                continue;
            }
            const tail = cur.items[cur.items.len - 1];
            const last = edge[edge.len - 1];
            if (tail.lon_e7 == edge[0].lon_e7 and tail.lat_e7 == edge[0].lat_e7) {
                try cur.appendSlice(a, edge[1..]); // connected forward: drop shared node
            } else if (tail.lon_e7 == last.lon_e7 and tail.lat_e7 == last.lat_e7) {
                // Edge connects at its far end: the stored ORNT didn't orient it
                // for this traversal. Reverse it so the ring stays continuous.
                std.mem.reverse(LonLat, edge);
                try cur.appendSlice(a, edge[1..]);
            } else {
                try parts.append(a, cur.items); // genuine discontinuity: flush + restart
                cur = std.ArrayList(LonLat).empty;
                try cur.appendSlice(a, edge);
            }
        }
        if (cur.items.len > 0) try parts.append(a, cur.items);
        return parts.items;
    }

    /// Legacy single-chain assembly (concatenate all FSPT edges). Prefer
    /// lineGeometryParts; kept for callers/tests that want one flat chain.
    pub fn lineGeometry(self: Cell, a: Allocator, f: Feature) ![]LonLat {
        var out = std.ArrayList(LonLat).empty;
        for (try self.lineGeometryParts(a, f)) |part| {
            var items = part;
            if (out.items.len > 0 and items.len > 0) {
                const tail = out.items[out.items.len - 1];
                if (tail.lon_e7 == items[0].lon_e7 and tail.lat_e7 == items[0].lat_e7) items = items[1..];
            }
            try out.appendSlice(a, items);
        }
        return out.items;
    }

    /// Like lineGeometryParts but for the DRAWN boundary/line geometry (S-52 §8.6.2):
    /// edges flagged MASK==1 (masked) or USAG==3 (exterior boundary truncated by the
    /// data limit) are dropped, so they don't stroke as spurious boundary lines. A
    /// dropped (or degenerate) edge breaks continuity, so the next drawn edge starts a
    /// fresh part. The FILL geometry (lineGeometryParts) is deliberately untouched —
    /// the fill still uses complete rings. Only meaningful when hasBoundaryMaskInfo(f).
    pub fn drawableLineParts(self: Cell, a: Allocator, f: Feature) ![][]LonLat {
        var parts = std.ArrayList([]LonLat).empty;
        var cur = std.ArrayList(LonLat).empty;
        var broken = false;
        for (f.refs) |ref| {
            if (ref.name.rcnm != RCNM_VE) continue;
            if (ref.mask == 1 or ref.usag == 3) {
                if (cur.items.len > 0) {
                    try parts.append(a, cur.items);
                    cur = std.ArrayList(LonLat).empty;
                }
                broken = true; // masked / data-limit edge: not drawn, breaks the chain
                continue;
            }
            const edge = try self.edgeCoordsRaw(a, ref.name.rcid, ref.ornt);
            if (edge.len == 0) {
                if (cur.items.len > 0) {
                    try parts.append(a, cur.items);
                    cur = std.ArrayList(LonLat).empty;
                }
                broken = true; // degenerate edge still interrupts continuity
                continue;
            }
            if (cur.items.len == 0 or broken) {
                if (cur.items.len > 0) {
                    try parts.append(a, cur.items);
                    cur = std.ArrayList(LonLat).empty;
                }
                try cur.appendSlice(a, edge);
                broken = false;
                continue;
            }
            const tail = cur.items[cur.items.len - 1];
            const last = edge[edge.len - 1];
            if (tail.lon_e7 == edge[0].lon_e7 and tail.lat_e7 == edge[0].lat_e7) {
                try cur.appendSlice(a, edge[1..]);
            } else if (tail.lon_e7 == last.lon_e7 and tail.lat_e7 == last.lat_e7) {
                std.mem.reverse(LonLat, edge);
                try cur.appendSlice(a, edge[1..]);
            } else {
                try parts.append(a, cur.items);
                cur = std.ArrayList(LonLat).empty;
                try cur.appendSlice(a, edge);
            }
        }
        if (cur.items.len > 0) try parts.append(a, cur.items);
        return parts.items;
    }

    /// A point feature's coordinate (its isolated/connected node).
    pub fn pointGeometry(self: Cell, f: Feature) ?LonLat {
        for (f.refs) |ref| {
            const key = (@as(u64, ref.name.rcnm) << 32) | ref.name.rcid;
            if (self.nodes.get(key)) |p| return p;
            if (self.nodeCoord(ref.name.rcid)) |p| return p;
        }
        return null;
    }

    /// Effective QUAPOS (quality of position) over a feature's DRAWN edges: the
    /// low-accuracy value held by the MAJORITY of its drawn VE edges, else 0.
    /// QUAPOS is an S-57 spatial-level attribute on the edge records (not a feature
    /// attribute); S-52 draws low-accuracy geometry dashed. Mirrors the Go
    /// constructLineStringGeometry / boundaryQuapos aggregate: masked (MASK==1) and
    /// truncated (USAG==3) edges are not drawn and don't count.
    pub fn featureQuapos(self: Cell, f: Feature) i32 {
        var total: usize = 0;
        var low: usize = 0;
        var low_val: i32 = 0;
        for (f.refs) |ref| {
            if (ref.name.rcnm != RCNM_VE) continue;
            if (ref.mask == 1 or ref.usag == 3) continue; // not drawn
            const idx = self.edges.get(ref.name.rcid) orelse continue;
            total += 1;
            const q = self.vectors[idx].quapos;
            if (isLowAccuracyQuapos(q)) {
                low += 1;
                low_val = q;
            }
        }
        if (total > 0 and low * 2 > total) return low_val;
        return 0;
    }

    /// Bounding box of all vector coordinates (lon/lat). Returns null if empty.
    pub fn bounds(self: Cell) ?[4]f64 {
        var min_lon: f64 = 1e9;
        var min_lat: f64 = 1e9;
        var max_lon: f64 = -1e9;
        var max_lat: f64 = -1e9;
        var any = false;
        for (self.vectors) |v| for (v.points) |p| {
            any = true;
            min_lon = @min(min_lon, p.lon());
            min_lat = @min(min_lat, p.lat());
            max_lon = @max(max_lon, p.lon());
            max_lat = @max(max_lat, p.lat());
        };
        return if (any) .{ min_lon, min_lat, max_lon, max_lat } else null;
    }
};

fn i32le(b: []const u8, o: usize) i32 {
    return std.mem.readInt(i32, b[o..][0..4], .little);
}
fn u32le(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
fn u16le(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}

fn parseDSPM(data: []const u8) DatasetParams {
    var p = DatasetParams{};
    if (data.len < 24 or data[0] != 20) return p;
    // RCNM(1) RCID(4) HDAT(1) VDAT(1) SDAT(1) CSCL(4)@8 DUNI(1) HUNI(1) PUNI(1) COUN(1) COMF(4)@16 SOMF(4)@20
    p.cscl = i32le(data, 8);
    p.comf = i32le(data, 16);
    p.somf = i32le(data, 20);
    // §7.3.2.1 requires a positive multiplier; a zero OR NEGATIVE factor falls back
    // to the standard default (matches the oracle's `<= 0` guard, not just `== 0`).
    if (p.comf <= 0) p.comf = 10_000_000;
    if (p.somf <= 0) p.somf = 10;
    return p;
}

fn parseSG2D(a: Allocator, data: []const u8, comf: f64) ![]LonLat {
    const n = data.len / 8;
    const pts = try a.alloc(LonLat, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const y = i32le(data, i * 8); // YCOO = latitude
        const x = i32le(data, i * 8 + 4); // XCOO = longitude
        pts[i] = LonLat.init(@as(f64, @floatFromInt(x)) / comf, @as(f64, @floatFromInt(y)) / comf);
    }
    return pts;
}

/// Set begin/end connected-node RCIDs from the VRPT pointer list (TOPI 1=begin,
/// 2=end). Re-run after any VRPC edit so the edge's endpoints track the list.
fn deriveEndpoints(v: *VectorRecord) void {
    v.begin_node = 0;
    v.end_node = 0;
    for (v.vptrs) |p| {
        if (p.topi == 1) v.begin_node = p.rcid else if (p.topi == 2) v.end_node = p.rcid;
    }
}

/// VRPT: repeated 9-byte entries NAME(5)+ORNT(1)+USAG(1)+TOPI(1)+MASK(1). Retains
/// the full pointer list (for VRPC indexed modifies) and derives begin/end nodes.
fn parseVRPT(a: Allocator, v: *VectorRecord, data: []const u8) void {
    const list = a.alloc(VPtr, data.len / 9) catch return;
    var cnt: usize = 0;
    var off: usize = 0;
    while (off + 9 <= data.len) : (off += 9) {
        list[cnt] = .{ .rcid = u32le(data, off + 1), .topi = data[off + 7] };
        cnt += 1;
    }
    v.vptrs = list[0..cnt];
    deriveEndpoints(v);
}

/// ATTF/NATF: repeated [ATTL(2 LE), ATVL(ASCII, UT-terminated)]. Values are
/// copied into `a` (the source field bytes are not retained).
fn parseATTF(a: Allocator, data: []const u8) ![]Attr {
    var list = std.ArrayList(Attr).empty;
    var off: usize = 0;
    while (off + 2 <= data.len) {
        const code = u16le(data, off);
        off += 2;
        var end = off;
        while (end < data.len and data[end] != iso.UT) end += 1;
        try list.append(a, .{ .code = code, .value = try a.dupe(u8, data[off..end]) });
        off = end + 1; // skip UT
    }
    return list.items;
}

/// ATTV (spatial-level attributes) carry QUAPOS — quality of position lives on the
/// edge/node records, not on the feature. ATTV shares the ATTL(2)+ATVL layout of a
/// feature's ATTF, so reuse parseATTF and pull out QUAPOS. Returns 0 if absent.
fn quaposFromAttv(a: Allocator, data: []const u8) i32 {
    const attrs = parseATTF(a, data) catch return 0;
    for (attrs) |at| {
        if (at.code == ATTR_QUAPOS)
            return std.fmt.parseInt(i32, std.mem.trim(u8, at.value, " "), 10) catch 0;
    }
    return 0;
}

/// FSPT: repeated 8-byte entries NAME(5)+ORNT(1)+USAG(1)+MASK(1).
fn parseFSPT(a: Allocator, data: []const u8) ![]SpatialRef {
    const n = data.len / 8;
    const refs = try a.alloc(SpatialRef, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const o = i * 8;
        refs[i] = .{ .name = .{ .rcnm = data[o], .rcid = u32le(data, o + 1) }, .ornt = data[o + 5], .usag = data[o + 6], .mask = data[o + 7] };
    }
    return refs;
}

fn parseSG3D(a: Allocator, data: []const u8, comf: f64, somf: f64) ![]Sounding {
    const n = data.len / 12;
    const out = try a.alloc(Sounding, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const y = i32le(data, i * 12);
        const x = i32le(data, i * 12 + 4);
        const z = i32le(data, i * 12 + 8);
        out[i] = Sounding.init(
            @as(f64, @floatFromInt(x)) / comf,
            @as(f64, @floatFromInt(y)) / comf,
            @as(f64, @floatFromInt(z)) / somf,
        );
    }
    return out;
}

/// Parse an S-57 cell from raw bytes (does the ISO 8211 decode internally).
/// Parse a single S-57 base cell (no updates).
pub fn parseCell(gpa: Allocator, bytes: []const u8) !Cell {
    return parseCellWithUpdates(gpa, bytes, &.{});
}

/// Cheaply read a cell's compilation scale (CSCL, 1:N) without assembling any
/// geometry — just the ISO-8211 records and the DSPM field. Used to band cells for
/// the streaming baker so it can group them before the expensive full parse +
/// portrayal. Returns null if the scale is absent/unparseable.
pub fn peekScale(gpa: Allocator, bytes: []const u8) ?i32 {
    var file = iso.parse(gpa, bytes) catch return null;
    defer file.deinit();
    for (file.records) |rec| {
        if (rec.field("DSPM")) |dspm| {
            const p = parseDSPM(dspm);
            if (p.cscl != 0) return p.cscl;
        }
    }
    return null;
}

pub const CellMeta = struct { cscl: i32 = 0, bounds: ?[4]f64 = null };

/// Cheaply read a cell's compilation scale + coordinate bounding box
/// ([west, south, east, north]) WITHOUT assembling topology — just the ISO-8211
/// records, DSPM, and the raw SG2D coordinates. For the lazy ENC_ROOT index
/// (band + bbox per cell), so the source can decide which cells a tile needs
/// before paying for a full parse + portrayal. Returns null if unparseable.
pub fn peekMeta(gpa: Allocator, bytes: []const u8) ?CellMeta {
    var file = iso.parse(gpa, bytes) catch return null;
    defer file.deinit();
    var m = CellMeta{};
    var comf: f64 = 10_000_000;
    for (file.records) |rec| {
        if (rec.field("DSPM")) |dspm| {
            const p = parseDSPM(dspm);
            m.cscl = p.cscl;
            comf = @floatFromInt(p.comf);
            break;
        }
    }
    var w: f64 = 1e18;
    var s: f64 = 1e18;
    var e: f64 = -1e18;
    var n: f64 = -1e18;
    var have = false;
    for (file.records) |rec| {
        const sg = rec.field("SG2D") orelse continue;
        const cnt = sg.len / 8;
        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            const lat = @as(f64, @floatFromInt(i32le(sg, i * 8))) / comf;
            const lon = @as(f64, @floatFromInt(i32le(sg, i * 8 + 4))) / comf;
            w = @min(w, lon);
            e = @max(e, lon);
            s = @min(s, lat);
            n = @max(n, lat);
            have = true;
        }
    }
    if (have) m.bounds = .{ w, s, e, n };
    return m;
}

/// One CATD (catalogue-directory) record from an exchange-set catalogue.
pub const CatalogEntry = struct {
    stem: []const u8, // cell name without extension (e.g. "US5MD1MC"); allocator-owned
    path: []const u8, // ENC_ROOT-relative path, '/'-normalised; allocator-owned
    bbox: ?[4]f64, // [west, south, east, north]; null for non-cell / no coverage
    is_cell: bool, // BIN .000 base cell
};

fn parseFloatOpt(s_in: []const u8) ?f64 {
    const s = std.mem.trim(u8, s_in, " ");
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

// Decode one CATD field (S-57 App. B.1). ASCII, unit-terminator (0x1f) delimited:
//   [0] RCNM(2 "CD") + RCID(digits) + FILE   [1] LFIL  [2] VOLM
//   [3] IMPL(3 BIN/ASC/TXT) + SLAT  [4] WLON  [5] NLAT  [6] ELON  [7] CRCS  [8] COMT
fn decodeCATD(a: Allocator, raw_in: []const u8) ?CatalogEntry {
    var end = raw_in.len;
    while (end > 0 and raw_in[end - 1] == 0x1e) end -= 1; // drop trailing field terminator(s)
    const raw = raw_in[0..end];
    var parts: [9][]const u8 = .{""} ** 9;
    var np: usize = 0;
    var it = std.mem.splitScalar(u8, raw, 0x1f);
    while (it.next()) |p| : (np += 1) {
        if (np >= parts.len) break;
        parts[np] = p;
    }
    if (np < 4) return null;
    const head = parts[0];
    if (head.len < 2) return null;
    var i: usize = 2; // drop RCNM ("CD")
    while (i < head.len and head[i] >= '0' and head[i] <= '9') : (i += 1) {} // RCID digits
    if (i >= head.len) return null;
    const norm = a.dupe(u8, head[i..]) catch return null; // FILE
    for (norm) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    const base = std.fs.path.basename(norm);
    const ext = std.fs.path.extension(base);
    const stem = a.dupe(u8, base[0 .. base.len - ext.len]) catch return null;

    var bbox: ?[4]f64 = null;
    var is_cell = false;
    if (parts[3].len >= 3) {
        is_cell = std.mem.eql(u8, parts[3][0..3], "BIN") and std.mem.endsWith(u8, base, ".000");
        if (parseFloatOpt(parts[3][3..])) |s|
            if (parseFloatOpt(parts[4])) |w|
                if (parseFloatOpt(parts[5])) |n|
                    if (parseFloatOpt(parts[6])) |e2| {
                        bbox = .{ w, s, e2, n };
                    };
    }
    return .{ .stem = stem, .path = norm, .bbox = bbox, .is_cell = is_cell };
}

/// Parse an S-57 exchange-set catalogue (CATALOG.031): one CATD record per file,
/// giving its path and — for base cells — coverage bbox. Lets a baker learn the
/// whole set's inventory + per-cell extents from this ONE file instead of parsing
/// every cell. Entries + their strings are allocated in `a`; null if unparseable.
pub fn parseCatalog(a: Allocator, bytes: []const u8) ?[]CatalogEntry {
    var file = iso.parse(a, bytes) catch return null;
    defer file.deinit();
    var out = std.ArrayList(CatalogEntry).empty;
    for (file.records) |rec| {
        const raw = rec.field("CATD") orelse continue;
        if (decodeCATD(a, raw)) |e| out.append(a, e) catch {};
    }
    return out.toOwnedSlice(a) catch null;
}

const vkey = struct {
    fn of(rcnm: u8, rcid: u32) u64 {
        return (@as(u64, rcnm) << 32) | rcid;
    }
};

// FOID composite key (AGEN, FIDN, FIDS) — the stable feature identity across
// updates (RCID alone is not unique; S-57 §7.6.2). FOID = AGEN(2) FIDN(4) FIDS(2).
fn foidKey(fo: []const u8) u64 {
    if (fo.len < 8) return 0;
    return (@as(u64, u16le(fo, 0)) << 48) | (@as(u64, u32le(fo, 2)) << 16) | u16le(fo, 6);
}

// Apply an S-57 update-control field (SGCC for coordinates §8.4.3.2, FSPC for
// feature-spatial pointers §8.4.2.2 — identical structure) to `existing`. The
// control is repeating 5-byte entries: UI(1) (1=insert,2=delete,3=modify),
// IX(2, 1-based), NC(2, count). Insert/modify consume items from `upd` in order;
// delete consumes none. Applied in sequence so a small edit touches only its
// indexed entries and keeps the rest of the base list intact. Allocates in `a`.
fn applyControl(a: Allocator, comptime T: type, existing: []const T, upd: []const T, ctrl: []const u8) ![]T {
    var out = std.ArrayList(T).empty;
    try out.appendSlice(a, existing);
    var ui: usize = 0;
    var off: usize = 0;
    while (off + 5 <= ctrl.len) : (off += 5) {
        const instr = ctrl[off];
        const raw = u16le(ctrl, off + 1);
        var idx: usize = if (raw == 0) 0 else raw - 1;
        const nc: usize = u16le(ctrl, off + 3);
        switch (instr) {
            1 => { // insert nc items before idx
                const end = @min(ui + nc, upd.len);
                const ins = upd[ui..end];
                ui = end;
                if (idx > out.items.len) idx = out.items.len;
                try out.insertSlice(a, idx, ins);
            },
            2 => { // delete nc items starting at idx
                const endd = @min(idx + nc, out.items.len);
                if (idx < out.items.len and idx < endd) try out.replaceRange(a, idx, endd - idx, &.{});
            },
            3 => { // modify nc items starting at idx (replace with new ones)
                const end = @min(ui + nc, upd.len);
                const repl = upd[ui..end];
                ui = end;
                var k: usize = 0;
                while (k < repl.len and idx + k < out.items.len) : (k += 1) out.items[idx + k] = repl[k];
            },
            else => {},
        }
    }
    return out.items;
}

// Merge one ISO 8211 file (base or update) into the record lists, keyed by FOID
// (features) / (RCNM,RCID) (vectors). Insertion order is preserved (deterministic
// output); deletes tombstone the slot (null). For the base, every record inserts.
fn mergeFile(
    gpa: Allocator,
    a: Allocator,
    feats: *std.ArrayList(?Feature),
    fidx: *std.AutoHashMap(u64, usize),
    vecs: *std.ArrayList(?VectorRecord),
    vidx: *std.AutoHashMap(u64, usize),
    bytes: []const u8,
    comf: f64,
    somf: f64,
    is_update: bool,
) !void {
    var file = try iso.parse(gpa, bytes);
    defer file.deinit(); // kept data is copied into arena `a`

    for (file.records) |rec| {
        if (rec.field("VRID")) |vrid| {
            if (vrid.len < 8) continue;
            const rcnm = vrid[0];
            const rcid = u32le(vrid, 1);
            const ruin: u8 = if (is_update) vrid[7] else 1;
            const key = vkey.of(rcnm, rcid);

            if (ruin == 2) { // delete
                // Drop the index entry too (not just tombstone the slot): the oracle
                // removes the record from its map, so a later re-INSERT of the same key
                // appends a fresh record at the end (rather than reviving this slot in
                // place) and a MODIFY-after-delete finds nothing.
                if (vidx.fetchRemove(key)) |kv| vecs.items[kv.value] = null;
                continue;
            }
            var v = VectorRecord{ .rcnm = rcnm, .rcid = rcid, .points = &.{}, .soundings = &.{} };
            if (rec.field("SG2D")) |sg| v.points = try parseSG2D(a, sg, comf);
            if (rec.field("SG3D")) |sg| v.soundings = try parseSG3D(a, sg, comf, somf);
            if (rec.field("VRPT")) |vp| parseVRPT(a, &v, vp);
            if (rec.field("ATTV")) |av| v.quapos = quaposFromAttv(a, av);

            if (ruin == 3) { // modify in place
                // The oracle errors on a MODIFY whose target is absent (updates.go:291),
                // which drops the whole cell via the baker's parse-error skip. Match it.
                const i = vidx.get(key) orelse return error.ModifyMissingSpatial;
                if (vecs.items[i]) |*ex| {
                    // SGCC (coordinate control) edits whichever coordinate list this
                    // record carries. The oracle keeps both 2D and 3D in one
                    // `Coordinates` slice, so SGCC applies to either; here they're split
                    // into `points` (SG2D edges/nodes) and `soundings` (SG3D sounding
                    // nodes), so route the control to the SG3D list for a sounding record
                    // and the SG2D list otherwise (a coordinate DELETE ships SGCC with no
                    // SG2D/SG3D, so fall back to whichever existing list is populated). A
                    // bare SG2D/SG3D with no SGCC is a full replacement.
                    const sgcc = rec.field("SGCC");
                    if (sgcc != null and sgcc.?.len >= 5) {
                        if (rec.field("SG3D") != null or (rec.field("SG2D") == null and ex.soundings.len > 0)) {
                            ex.soundings = try applyControl(a, Sounding, ex.soundings, v.soundings, sgcc.?);
                        } else {
                            ex.points = try applyControl(a, LonLat, ex.points, v.points, sgcc.?);
                        }
                    } else if (rec.field("SG2D") != null) {
                        ex.points = v.points;
                    } else if (rec.field("SG3D") != null) {
                        ex.soundings = v.soundings;
                    }
                    // VRPC = indexed insert/delete/modify of the VRPT list (§8.4.3.2):
                    // a single-endpoint modify ships VRPC{modify,idx,count=1} + ONE
                    // VRPT, so editing the list (not replacing it) preserves the other
                    // endpoint. A bare VRPT with no VRPC is a full replace.
                    const vrpc = rec.field("VRPC");
                    if (vrpc != null and vrpc.?.len >= 5) {
                        ex.vptrs = try applyControl(a, VPtr, ex.vptrs, v.vptrs, vrpc.?);
                        deriveEndpoints(ex);
                    } else if (rec.field("VRPT") != null) {
                        ex.vptrs = v.vptrs;
                        deriveEndpoints(ex);
                    }
                    // The oracle's spatial MODIFY (updates.go:288-348) updates only
                    // coordinates and vector pointers — it never re-reads ATTV, so a
                    // modified record keeps its base QUAPOS. Match that for byte-parity
                    // (don't refresh ex.quapos from the update's ATTV here).
                } else return error.ModifyMissingSpatial;
                continue;
            }
            // insert (1) — upsert
            if (vidx.get(key)) |i| {
                vecs.items[i] = v;
            } else {
                try vecs.append(a, v);
                try vidx.put(key, vecs.items.len - 1);
            }
        } else if (rec.field("FRID")) |frid| {
            if (frid.len < 12) continue;
            // RCNM(1) RCID(4) PRIM(1)@5 GRUP(1)@6 OBJL(2)@7 RVER(2)@9 RUIN(1)@11
            const ruin: u8 = if (is_update) frid[11] else 1;
            var f = Feature{ .rcnm = frid[0], .rcid = u32le(frid, 1), .prim = frid[5], .objl = u16le(frid, 7) };
            const key = if (rec.field("FOID")) |fo| foidKey(fo) else vkey.of(f.rcnm, f.rcid);

            if (ruin == 2) {
                // See the spatial-delete note: drop the index entry so re-INSERT
                // appends and MODIFY-after-delete is treated as missing.
                if (fidx.fetchRemove(key)) |kv| feats.items[kv.value] = null;
                continue;
            }
            if (rec.field("FSPT")) |fp| f.refs = try parseFSPT(a, fp);
            if (rec.field("ATTF")) |at| f.attrs = try parseATTF(a, at);

            if (ruin == 3) {
                // MODIFY of an absent feature errors (updates.go:202) -> cell dropped.
                const i = fidx.get(key) orelse return error.ModifyMissingFeature;
                if (feats.items[i]) |*ex| {
                    const fspc = rec.field("FSPC");
                    if (fspc != null and fspc.?.len >= 5) {
                        ex.refs = try applyControl(a, SpatialRef, ex.refs, f.refs, fspc.?);
                    } else if (rec.field("FSPT") != null) {
                        ex.refs = f.refs;
                    }
                    // Gate on the PARSED attribute count, not ATTF field presence: the
                    // oracle (updates.go:228) replaces attributes only when the update
                    // carries at least one, so a present-but-empty ATTF preserves the
                    // existing set instead of clobbering it.
                    if (f.attrs.len > 0) ex.attrs = f.attrs;
                } else return error.ModifyMissingFeature;
                continue;
            }
            if (fidx.get(key)) |i| {
                feats.items[i] = f;
            } else {
                try feats.append(a, f);
                try fidx.put(key, feats.items.len - 1);
            }
        }
    }
}

/// Parse an S-57 base cell and apply its sequential update files (.001, .002, …
/// in order). Updates are merged at the record level (S-57 §8.4): insert / delete
/// / modify by FOID (features) or (RCNM,RCID) (vectors), with SGCC/FSPC control
/// fields for indexed coordinate/pointer edits. Pass an empty `updates` for a
/// plain base cell.
pub fn parseCellWithUpdates(gpa: Allocator, base_bytes: []const u8, updates: []const []const u8) !Cell {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // DSPM (coordinate factors) from the base cell.
    var params = DatasetParams{};
    {
        var bf = try iso.parse(gpa, base_bytes);
        defer bf.deinit();
        for (bf.records) |rec| if (rec.field("DSPM")) |d| {
            params = parseDSPM(d);
        };
    }
    const comf: f64 = @floatFromInt(params.comf);
    const somf: f64 = @floatFromInt(params.somf);

    // Record lists (insertion order) + FOID/(RCNM,RCID) indices for the merge.
    var feats = std.ArrayList(?Feature).empty;
    var vecs = std.ArrayList(?VectorRecord).empty;
    var fidx = std.AutoHashMap(u64, usize).init(gpa);
    defer fidx.deinit();
    var vidx = std.AutoHashMap(u64, usize).init(gpa);
    defer vidx.deinit();

    try mergeFile(gpa, a, &feats, &fidx, &vecs, &vidx, base_bytes, comf, somf, false);
    for (updates) |u| try mergeFile(gpa, a, &feats, &fidx, &vecs, &vidx, u, comf, somf, true);

    // Flatten the surviving records (skip tombstones) into the final arrays.
    var vectors = std.ArrayList(VectorRecord).empty;
    for (vecs.items) |mv| if (mv) |v| try vectors.append(a, v);
    var features = std.ArrayList(Feature).empty;
    for (feats.items) |mf| if (mf) |f| try features.append(a, f);

    // Build node + edge indices for topology assembly, plus an index of the
    // VI records that carry SG3D soundings (multipoint geometry for SOUNDG).
    var nodes = std.AutoHashMap(u64, LonLat).init(gpa);
    var edges = std.AutoHashMap(u32, usize).init(gpa);
    var sounding_vecs = std.AutoHashMap(u64, usize).init(gpa);
    for (vectors.items, 0..) |v, i| {
        if ((v.rcnm == RCNM_VI or v.rcnm == RCNM_VC) and v.points.len > 0) {
            try nodes.put(vkey.of(v.rcnm, v.rcid), v.points[0]);
        } else if (v.rcnm == RCNM_VE) {
            try edges.put(v.rcid, i);
        }
        if (v.soundings.len > 0) {
            try sounding_vecs.put(vkey.of(v.rcnm, v.rcid), i);
        }
    }

    return .{ .params = params, .vectors = vectors.items, .features = features.items, .nodes = nodes, .edges = edges, .sounding_vecs = sounding_vecs, .arena = arena };
}

// ---- tests --------------------------------------------------------------

test "parse DSPM coordinate factors" {
    var data: [24]u8 = undefined;
    @memset(&data, 0);
    data[0] = 20; // RCNM = DSPM
    std.mem.writeInt(i32, data[8..12], 25000, .little); // CSCL 1:25000
    std.mem.writeInt(i32, data[16..20], 10_000_000, .little); // COMF
    std.mem.writeInt(i32, data[20..24], 10, .little); // SOMF
    const p = parseDSPM(&data);
    try std.testing.expectEqual(@as(i32, 10_000_000), p.comf);
    try std.testing.expectEqual(@as(i32, 10), p.somf);
    try std.testing.expectEqual(@as(i32, 25000), p.cscl);

    // Zero OR negative COMF/SOMF both fall back to the standard defaults (§7.3.2.1).
    std.mem.writeInt(i32, data[16..20], -5, .little);
    std.mem.writeInt(i32, data[20..24], 0, .little);
    const pn = parseDSPM(&data);
    try std.testing.expectEqual(@as(i32, 10_000_000), pn.comf);
    try std.testing.expectEqual(@as(i32, 10), pn.somf);
}

test "VRPC partial VRPT modify preserves the unmodified endpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // edge with begin=100 (TOPI 1), end=200 (TOPI 2)
    var v = VectorRecord{ .rcnm = RCNM_VE, .rcid = 1, .points = &.{}, .soundings = &.{} };
    v.vptrs = &.{ .{ .rcid = 100, .topi = 1 }, .{ .rcid = 200, .topi = 2 } };
    deriveEndpoints(&v);
    try std.testing.expectEqual(@as(u32, 100), v.begin_node);
    try std.testing.expectEqual(@as(u32, 200), v.end_node);
    // an update that modifies ONLY the end pointer: VRPC{modify, idx=2 (1-based), count=1}
    // + one new VRPT (TOPI 2). The begin pointer must survive (was clobbered to 0 before).
    const upd = [_]VPtr{.{ .rcid = 300, .topi = 2 }};
    const ctrl = [_]u8{ 3, 2, 0, 1, 0 }; // instr=modify, IX=2 LE, NC=1 LE
    v.vptrs = try applyControl(a, VPtr, v.vptrs, &upd, &ctrl);
    deriveEndpoints(&v);
    try std.testing.expectEqual(@as(u32, 100), v.begin_node); // preserved
    try std.testing.expectEqual(@as(u32, 300), v.end_node); // updated
}

test "SGCC modify of one sounding preserves the rest (SG3D list)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A 3-point sounding node; an SGCC{modify, idx=2 (1-based), count=1} edit ships
    // ONE replacement sounding. The other two must survive (a wholesale replace would
    // collapse the node to a single point — the SG2D bug this routing fix mirrors).
    const base = [_]Sounding{ Sounding.init(0, 0, 1), Sounding.init(1, 1, 2), Sounding.init(2, 2, 3) };
    const upd = [_]Sounding{Sounding.init(5, 5, 9)};
    const ctrl = [_]u8{ 3, 2, 0, 1, 0 }; // modify, IX=2 LE, NC=1 LE
    const out = try applyControl(a, Sounding, &base, &upd, &ctrl);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqual(@as(f64, 1), out[0].depth); // preserved
    try std.testing.expectEqual(@as(f64, 9), out[1].depth); // modified
    try std.testing.expectEqual(@as(f64, 3), out[2].depth); // preserved
}

test "featureQuapos majority-of-drawn-edges aggregate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Three edges: two low-accuracy (QUAPOS 4 = approximate), one surveyed (1).
    const vectors = try a.alloc(VectorRecord, 3);
    vectors[0] = .{ .rcnm = RCNM_VE, .rcid = 10, .points = &.{}, .soundings = &.{}, .quapos = 4 };
    vectors[1] = .{ .rcnm = RCNM_VE, .rcid = 11, .points = &.{}, .soundings = &.{}, .quapos = 1 };
    vectors[2] = .{ .rcnm = RCNM_VE, .rcid = 12, .points = &.{}, .soundings = &.{}, .quapos = 4 };

    var edges = std.AutoHashMap(u32, usize).init(a);
    try edges.put(10, 0);
    try edges.put(11, 1);
    try edges.put(12, 2);

    var cell = Cell{
        .params = .{},
        .vectors = vectors,
        .features = &.{},
        .nodes = std.AutoHashMap(u64, LonLat).init(a),
        .edges = edges,
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer cell.arena.deinit();

    // 2 of 3 drawn edges low-accuracy -> majority -> returns the low value.
    const refs = [_]SpatialRef{
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 10 }, .ornt = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 11 }, .ornt = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 12 }, .ornt = 1 },
    };
    const f = Feature{ .rcnm = 100, .rcid = 1, .prim = 2, .objl = 30, .refs = &refs };
    try std.testing.expectEqual(@as(i32, 4), cell.featureQuapos(f));

    // Masking the low-accuracy edge 10 drops it: drawn edges 11(q=1),12(q=4) ->
    // 1 of 2 low -> not a majority -> 0 (drawn solid).
    const refs2 = [_]SpatialRef{
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 10 }, .ornt = 1, .mask = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 11 }, .ornt = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 12 }, .ornt = 1 },
    };
    const f2 = Feature{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = 30, .refs = &refs2 };
    try std.testing.expectEqual(@as(i32, 0), cell.featureQuapos(f2));
}

test "drawableLineParts drops MASK/USAG edges and breaks the chain" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // Three collinear edges that join tail-to-head into one chain (0,0)->(3,0).
    const vectors = try aa.alloc(VectorRecord, 3);
    vectors[0] = .{ .rcnm = RCNM_VE, .rcid = 10, .points = try aa.dupe(LonLat, &.{ LonLat.init(0, 0), LonLat.init(1, 0) }), .soundings = &.{} };
    vectors[1] = .{ .rcnm = RCNM_VE, .rcid = 11, .points = try aa.dupe(LonLat, &.{ LonLat.init(1, 0), LonLat.init(2, 0) }), .soundings = &.{} };
    vectors[2] = .{ .rcnm = RCNM_VE, .rcid = 12, .points = try aa.dupe(LonLat, &.{ LonLat.init(2, 0), LonLat.init(3, 0) }), .soundings = &.{} };

    var edges = std.AutoHashMap(u32, usize).init(aa);
    try edges.put(10, 0);
    try edges.put(11, 1);
    try edges.put(12, 2);

    var cell = Cell{
        .params = .{},
        .vectors = vectors,
        .features = &.{},
        .nodes = std.AutoHashMap(u64, LonLat).init(aa),
        .edges = edges,
        .sounding_vecs = std.AutoHashMap(u64, usize).init(aa),
        .arena = std.heap.ArenaAllocator.init(a),
    };
    defer cell.arena.deinit();

    // No mask info -> full geometry; gate is false, drawable == full (one chain).
    const refs_full = [_]SpatialRef{
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 10 }, .ornt = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 11 }, .ornt = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 12 }, .ornt = 1 },
    };
    const f_full = Feature{ .rcnm = 100, .rcid = 1, .prim = 2, .objl = 30, .refs = &refs_full };
    try std.testing.expect(!hasBoundaryMaskInfo(f_full));
    try std.testing.expectEqual(@as(usize, 1), (try cell.lineGeometryParts(aa, f_full)).len);
    try std.testing.expectEqual(@as(usize, 1), (try cell.drawableLineParts(aa, f_full)).len);

    // Mask the middle edge: fill still one ring, drawn boundary splits into two parts
    // with the masked segment removed.
    const refs_masked = [_]SpatialRef{
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 10 }, .ornt = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 11 }, .ornt = 1, .mask = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 12 }, .ornt = 1 },
    };
    const f_masked = Feature{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = 30, .refs = &refs_masked };
    try std.testing.expect(hasBoundaryMaskInfo(f_masked));
    try std.testing.expectEqual(@as(usize, 1), (try cell.lineGeometryParts(aa, f_masked)).len); // fill untouched
    const drawn = try cell.drawableLineParts(aa, f_masked);
    try std.testing.expectEqual(@as(usize, 2), drawn.len);
    try std.testing.expectEqual(@as(usize, 2), drawn[0].len); // (0,0)-(1,0)
    try std.testing.expectEqual(@as(usize, 2), drawn[1].len); // (2,0)-(3,0)

    // USAG==3 (data-limit) is dropped the same way.
    const refs_usag = [_]SpatialRef{
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 10 }, .ornt = 1 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 11 }, .ornt = 1, .usag = 3 },
        .{ .name = .{ .rcnm = RCNM_VE, .rcid = 12 }, .ornt = 1 },
    };
    const f_usag = Feature{ .rcnm = 100, .rcid = 3, .prim = 2, .objl = 30, .refs = &refs_usag };
    try std.testing.expectEqual(@as(usize, 2), (try cell.drawableLineParts(aa, f_usag)).len);
}

test "parse SG2D coordinates to lon/lat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Two points: (lat 38.9784000, lon -76.4820000) at COMF 1e7.
    var data: [16]u8 = undefined;
    std.mem.writeInt(i32, data[0..4], @as(i32, @intFromFloat(38.9784 * 1e7)), .little);
    std.mem.writeInt(i32, data[4..8], @as(i32, @intFromFloat(-76.4820 * 1e7)), .little);
    std.mem.writeInt(i32, data[8..12], @as(i32, @intFromFloat(39.0 * 1e7)), .little);
    std.mem.writeInt(i32, data[12..16], @as(i32, @intFromFloat(-76.5 * 1e7)), .little);
    const pts = try parseSG2D(arena.allocator(), &data, 1e7);
    try std.testing.expectEqual(@as(usize, 2), pts.len);
    try std.testing.expectApproxEqAbs(@as(f64, 38.9784), pts[0].lat(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -76.4820), pts[0].lon(), 1e-6);
}

test "pointInRings: inside, outside, and inside a hole" {
    // A 0..10 square (outer) with a 4..6 square hole.
    const outer = [_]LonLat{ LonLat.init(0, 0), LonLat.init(10, 0), LonLat.init(10, 10), LonLat.init(0, 10) };
    const hole = [_]LonLat{ LonLat.init(4, 4), LonLat.init(6, 4), LonLat.init(6, 6), LonLat.init(4, 6) };
    const rings = [_][]const LonLat{ outer[0..], hole[0..] };
    try std.testing.expect(pointInRings(&rings, 1, 1)); // inside outer, outside hole
    try std.testing.expect(!pointInRings(&rings, 5, 5)); // inside the hole -> outside
    try std.testing.expect(!pointInRings(&rings, 20, 20)); // far outside
    // A lone ring with no hole.
    const just_outer = [_][]const LonLat{outer[0..]};
    try std.testing.expect(pointInRings(&just_outer, 5, 5));
}
