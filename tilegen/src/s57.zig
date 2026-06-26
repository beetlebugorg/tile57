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
};

pub const VectorRecord = struct {
    rcnm: u8,
    rcid: u32,
    points: []LonLat, // SG2D coordinates (node = 1 point; edge = interior chain)
    soundings: []Sounding, // SG3D (sounding nodes)
    begin_node: u32 = 0, // VRPT TOPI=1 (edges) — connected-node RCID
    end_node: u32 = 0, // VRPT TOPI=2 (edges)
};

// S-57 attribute codes (Appendix A) used by portrayal.
pub const ATTR_DRVAL1: u16 = 87;
pub const ATTR_DRVAL2: u16 = 88;
pub const ATTR_VALSOU: u16 = 179;
pub const ATTR_VALDCO: u16 = 174;
pub const ATTR_OBJNAM: u16 = 116;

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

/// FSPT: repeated 8-byte entries NAME(5)+ORNT(1)+USAG(1)+MASK(1).
fn parseFSPT(a: Allocator, data: []const u8) ![]SpatialRef {
    const n = data.len / 8;
    const refs = try a.alloc(SpatialRef, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const o = i * 8;
        refs[i] = .{ .name = .{ .rcnm = data[o], .rcid = u32le(data, o + 1) }, .ornt = data[o + 5] };
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
pub fn parseCell(gpa: Allocator, bytes: []const u8) !Cell {
    var file = try iso.parse(gpa, bytes);
    defer file.deinit(); // we copy what we keep into our own arena

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var params = DatasetParams{};
    var vectors = std.ArrayList(VectorRecord).empty;
    var features = std.ArrayList(Feature).empty;

    for (file.records) |rec| {
        if (rec.field("DSPM")) |d| {
            params = parseDSPM(d);
        }
    }
    const comf: f64 = @floatFromInt(params.comf);
    const somf: f64 = @floatFromInt(params.somf);

    for (file.records) |rec| {
        if (rec.field("VRID")) |vrid| {
            if (vrid.len < 5) continue;
            var v = VectorRecord{ .rcnm = vrid[0], .rcid = u32le(vrid, 1), .points = &.{}, .soundings = &.{} };
            if (rec.field("SG2D")) |sg| v.points = try parseSG2D(a, sg, comf);
            if (rec.field("SG3D")) |sg| v.soundings = try parseSG3D(a, sg, comf, somf);
            if (rec.field("VRPT")) |vp| parseVRPT(&v, vp);
            try vectors.append(a, v);
        } else if (rec.field("FRID")) |frid| {
            if (frid.len < 9) continue;
            // RCNM(1) RCID(4) PRIM(1)@5 GRUP(1)@6 OBJL(2)@7
            var f = Feature{ .rcnm = frid[0], .rcid = u32le(frid, 1), .prim = frid[5], .objl = u16le(frid, 7) };
            if (rec.field("FSPT")) |fp| f.refs = try parseFSPT(a, fp);
            if (rec.field("ATTF")) |at| f.attrs = try parseATTF(a, at);
            try features.append(a, f);
        }
    }

    // Build node + edge indices for topology assembly, plus an index of the
    // VI records that carry SG3D soundings (multipoint geometry for SOUNDG).
    var nodes = std.AutoHashMap(u64, LonLat).init(gpa);
    var edges = std.AutoHashMap(u32, usize).init(gpa);
    var sounding_vecs = std.AutoHashMap(u64, usize).init(gpa);
    for (vectors.items, 0..) |v, i| {
        if ((v.rcnm == RCNM_VI or v.rcnm == RCNM_VC) and v.points.len > 0) {
            try nodes.put((@as(u64, v.rcnm) << 32) | v.rcid, v.points[0]);
        } else if (v.rcnm == RCNM_VE) {
            try edges.put(v.rcid, i);
        }
        if (v.soundings.len > 0) {
            try sounding_vecs.put((@as(u64, v.rcnm) << 32) | v.rcid, i);
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
