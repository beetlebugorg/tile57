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

pub const VectorRecord = struct {
    rcnm: u8,
    rcid: u32,
    points: []LonLat, // SG2D coordinates (node = 1 point; edge = interior chain)
    soundings: []Sounding, // SG3D (sounding nodes)
};

pub const Feature = struct {
    rcnm: u8,
    rcid: u32,
    prim: u8, // 1=point, 2=line, 3=area, 255=none
    objl: u16, // S-57 object class code
};

pub const Cell = struct {
    params: DatasetParams,
    vectors: []VectorRecord,
    features: []Feature,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Cell) void {
        self.arena.deinit();
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
            try vectors.append(a, v);
        } else if (rec.field("FRID")) |frid| {
            if (frid.len < 9) continue;
            // RCNM(1) RCID(4) PRIM(1)@5 GRUP(1)@6 OBJL(2)@7
            try features.append(a, .{
                .rcnm = frid[0],
                .rcid = u32le(frid, 1),
                .prim = frid[5],
                .objl = u16le(frid, 7),
            });
        }
    }

    return .{ .params = params, .vectors = vectors.items, .features = features.items, .arena = arena };
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
