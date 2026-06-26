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
const iso = @import("iso8211.zig");

pub const LonLat = struct { lon: f64, lat: f64 };
pub const Sounding = struct { lon: f64, lat: f64, depth: f64 };

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
        const cross = ring[i].lon * ring[j].lat - ring[j].lon * ring[i].lat;
        area2 += cross;
        cx += (ring[i].lon + ring[j].lon) * cross;
        cy += (ring[i].lat + ring[j].lat) * cross;
    }
    if (@abs(area2) < 1e-12) return null;
    const a6 = 3.0 * area2; // 6 * (signed area = area2 / 2)
    return .{ .lon = cx / a6, .lat = cy / a6 };
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
            if ((a.lat > lat) != (b.lat > lat) and
                lon < (b.lon - a.lon) * (lat - a.lat) / (b.lat - a.lat) + a.lon)
            {
                inside = !inside;
            }
            j = i;
        }
    }
    return inside;
}

/// The representative point for an area's parts — its centre of gravity when that
/// lies inside (S-52 PresLib §8.5.3), else the vertex average. The first part is
/// treated as the exterior ring (like the Go baker). Null with no usable vertices.
pub fn areaRepresentativePoint(rings: []const []LonLat) ?LonLat {
    if (rings.len == 0) return null;
    if (ringCentroid(rings[0])) |c| {
        if (pointInRingsEvenOdd(c.lon, c.lat, rings)) return c;
    }
    var clon: f64 = 0;
    var clat: f64 = 0;
    var n: usize = 0;
    for (rings) |ring| for (ring) |q| {
        clon += q.lon;
        clat += q.lat;
        n += 1;
    };
    if (n == 0) return null;
    return .{ .lon = clon / @as(f64, @floatFromInt(n)), .lat = clat / @as(f64, @floatFromInt(n)) };
}

test "area representative point centres on the centroid when inside" {
    const t = std.testing;
    // A wide rectangle (0,0)-(10,2): the centre of gravity is dead-centre.
    var rect = [_]LonLat{
        .{ .lon = 0, .lat = 0 },  .{ .lon = 10, .lat = 0 },
        .{ .lon = 10, .lat = 2 }, .{ .lon = 0, .lat = 2 },
    };
    var parts = [_][]LonLat{rect[0..]};
    const rp = areaRepresentativePoint(parts[0..]).?;
    try t.expectApproxEqAbs(@as(f64, 5), rp.lon, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1), rp.lat, 1e-9);

    // Even-odd containment: centre inside, far point outside.
    try t.expect(pointInRingsEvenOdd(5, 1, parts[0..]));
    try t.expect(!pointInRingsEvenOdd(20, 1, parts[0..]));

    // A triangle's centroid is the mean of its three vertices.
    var tri = [_]LonLat{ .{ .lon = 0, .lat = 0 }, .{ .lon = 6, .lat = 0 }, .{ .lon = 0, .lat = 6 } };
    const c = ringCentroid(tri[0..]).?;
    try t.expectApproxEqAbs(@as(f64, 2), c.lon, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 2), c.lat, 1e-9);

    // A degenerate (collinear / 2-point) ring has no centroid.
    var deg = [_]LonLat{ .{ .lon = 0, .lat = 0 }, .{ .lon = 1, .lat = 1 } };
    try t.expect(ringCentroid(deg[0..]) == null);
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

pub const VectorRecord = struct {
    rcnm: u8,
    rcid: u32,
    points: []LonLat, // SG2D coordinates (node = 1 point; edge = interior chain)
    soundings: []Sounding, // SG3D (sounding nodes)
    begin_node: u32 = 0, // VRPT TOPI=1 (edges) — connected-node RCID
    end_node: u32 = 0, // VRPT TOPI=2 (edges)
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

/// True for a QUAPOS that means "low accuracy" — S-52 draws such geometry DASHED
/// (approximate-position line style). I.e. present and not surveyed (1), precisely
/// known (10) or calculated (11). 0 means the attribute was absent.
pub fn isLowAccuracyQuapos(q: i32) bool {
    return q != 0 and q != 1 and q != 10 and q != 11;
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
            if (tail.lon == edge[0].lon and tail.lat == edge[0].lat) {
                try cur.appendSlice(a, edge[1..]); // connected forward: drop shared node
            } else if (tail.lon == last.lon and tail.lat == last.lat) {
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
                if (tail.lon == items[0].lon and tail.lat == items[0].lat) items = items[1..];
            }
            try out.appendSlice(a, items);
        }
        return out.items;
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
            min_lon = @min(min_lon, p.lon);
            min_lat = @min(min_lat, p.lat);
            max_lon = @max(max_lon, p.lon);
            max_lat = @max(max_lat, p.lat);
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
    if (p.comf == 0) p.comf = 10_000_000;
    if (p.somf == 0) p.somf = 10;
    return p;
}

fn parseSG2D(a: Allocator, data: []const u8, comf: f64) ![]LonLat {
    const n = data.len / 8;
    const pts = try a.alloc(LonLat, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const y = i32le(data, i * 8); // YCOO = latitude
        const x = i32le(data, i * 8 + 4); // XCOO = longitude
        pts[i] = .{ .lat = @as(f64, @floatFromInt(y)) / comf, .lon = @as(f64, @floatFromInt(x)) / comf };
    }
    return pts;
}

/// VRPT: repeated 9-byte entries NAME(5)+ORNT(1)+USAG(1)+TOPI(1)+MASK(1).
/// Sets begin/end connected-node RCIDs on the edge (TOPI 1=begin, 2=end).
fn parseVRPT(v: *VectorRecord, data: []const u8) void {
    var off: usize = 0;
    while (off + 9 <= data.len) : (off += 9) {
        const rcid = u32le(data, off + 1);
        const topi = data[off + 7];
        if (topi == 1) v.begin_node = rcid else if (topi == 2) v.end_node = rcid;
    }
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
        out[i] = .{
            .lat = @as(f64, @floatFromInt(y)) / comf,
            .lon = @as(f64, @floatFromInt(x)) / comf,
            .depth = @as(f64, @floatFromInt(z)) / somf,
        };
    }
    return out;
}

/// Parse an S-57 cell from raw bytes (does the ISO 8211 decode internally).
/// Parse a single S-57 base cell (no updates).
pub fn parseCell(gpa: Allocator, bytes: []const u8) !Cell {
    return parseCellWithUpdates(gpa, bytes, &.{});
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
                if (vidx.get(key)) |i| vecs.items[i] = null;
                continue;
            }
            var v = VectorRecord{ .rcnm = rcnm, .rcid = rcid, .points = &.{}, .soundings = &.{} };
            if (rec.field("SG2D")) |sg| v.points = try parseSG2D(a, sg, comf);
            if (rec.field("SG3D")) |sg| v.soundings = try parseSG3D(a, sg, comf, somf);
            if (rec.field("VRPT")) |vp| parseVRPT(&v, vp);
            if (rec.field("ATTV")) |av| v.quapos = quaposFromAttv(a, av);

            if (ruin == 3) { // modify in place
                if (vidx.get(key)) |i| if (vecs.items[i]) |*ex| {
                    if (rec.field("SGCC")) |sgcc| {
                        ex.points = try applyControl(a, LonLat, ex.points, v.points, sgcc);
                    } else if (rec.field("SG2D") != null) {
                        ex.points = v.points;
                    }
                    if (rec.field("SG3D") != null) ex.soundings = v.soundings;
                    if (rec.field("VRPT") != null) { // begin/end full-replace (VRPC indexing not modelled)
                        ex.begin_node = v.begin_node;
                        ex.end_node = v.end_node;
                    }
                    if (rec.field("ATTV") != null) ex.quapos = v.quapos;
                };
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
                if (fidx.get(key)) |i| feats.items[i] = null;
                continue;
            }
            if (rec.field("FSPT")) |fp| f.refs = try parseFSPT(a, fp);
            if (rec.field("ATTF")) |at| f.attrs = try parseATTF(a, at);

            if (ruin == 3) {
                if (fidx.get(key)) |i| if (feats.items[i]) |*ex| {
                    if (rec.field("FSPC")) |fspc| {
                        ex.refs = try applyControl(a, SpatialRef, ex.refs, f.refs, fspc);
                    } else if (rec.field("FSPT") != null) {
                        ex.refs = f.refs;
                    }
                    if (rec.field("ATTF") != null) ex.attrs = f.attrs;
                };
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
    try std.testing.expectApproxEqAbs(@as(f64, 38.9784), pts[0].lat, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -76.4820), pts[0].lon, 1e-6);
}
