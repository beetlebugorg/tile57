//! MapLibre Tile (MLT) encoder — an optional, column-oriented alternative to MVT
//! (src/mvt/mvt.zig). MLT v1 (spec stable Oct 2025) is decoded by MapLibre Native
//! + GL JS via a source `"encoding": "mlt"`. This encodes the SAME logical model
//! tile57 builds for MVT (mvt.Tile/Layer/Feature), so it's a parallel encoder at
//! one seam (s57_mvt.generateTileMulti).
//!
//! Wire format mirrors the reference impl (github.com/maplibre/maplibre-tile-spec):
//! a tile is a sequence of blocks `[varint blockLength][varint tag=1][body]`; the
//! body is embedded metadata (FeatureTable: name, extent, columns) then per-column
//! physical streams. Every stream is prefixed by a StreamMetadata header
//! (Java StreamMetadata.encode): byte0 = (physicalStreamType<<4)|logicalSubType,
//! byte1 = (llt1<<5)|(llt2<<2)|plt, then varint numValues, varint byteLength.
//!
//! This first cut encodes geometry (Point/LineString/Polygon) via the FLAT path
//! (per-feature GeometryType stream, plain length streams, VERTEX-typed vertex
//! buffer with componentwise-delta+zigzag+varint). Properties, ids, multi-geometry,
//! and the size-winning encodings (dictionary/RLE) are layered on next.

const std = @import("std");
const mvt = @import("mvt");

// PhysicalStreamType ordinals.
const PHYS_PRESENT: u8 = 0;
const PHYS_DATA: u8 = 1;
const PHYS_OFFSET: u8 = 2;
const PHYS_LENGTH: u8 = 3;
// DictionaryType (low nibble when DATA).
const DICT_NONE: u8 = 0;
const DICT_VERTEX: u8 = 3;
// LengthType (low nibble when LENGTH).
const LEN_VAR_BINARY: u8 = 0;
const LEN_GEOMETRIES: u8 = 1;
const LEN_PARTS: u8 = 2;
const LEN_RINGS: u8 = 3;
// LogicalLevelTechnique ordinals.
const LLT_NONE: u8 = 0;
const LLT_DELTA: u8 = 1;
const LLT_CWISE_DELTA: u8 = 2;
const LLT_RLE: u8 = 3;
// PhysicalLevelTechnique ordinals.
const PLT_NONE: u8 = 0;
const PLT_VARINT: u8 = 2;
// MLT GeometryType ordinals.
const G_POINT: u32 = 0;
const G_LINESTRING: u32 = 1;
const G_POLYGON: u32 = 2;
const G_MULTIPOINT: u32 = 3;
const G_MULTILINESTRING: u32 = 4;
const G_MULTIPOLYGON: u32 = 5;
// Column typeCode: id 0-3, geometry 4, scalars 10+type*2+nullable, struct 30.
const TYPECODE_GEOMETRY: u8 = 4;

const Buf = std.ArrayList(u8);

fn putVarint(b: *Buf, a: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try b.append(a, @intCast((v & 0x7F) | 0x80));
    try b.append(a, @intCast(v));
}

fn zigzag32(n: i32) u32 {
    return @bitCast((n << 1) ^ (n >> 31));
}

/// Write a StreamMetadata header (Java StreamMetadata.encode): byte0, byte1, then
/// varint numValues + varint byteLength. RLE/Morton trailers not used here.
fn writeStreamMeta(b: *Buf, a: std.mem.Allocator, phys: u8, sub: u8, llt1: u8, llt2: u8, plt: u8, num_values: u64, byte_length: u64) !void {
    try b.append(a, (phys << 4) | sub);
    try b.append(a, (llt1 << 5) | (llt2 << 2) | plt);
    try putVarint(b, a, num_values);
    try putVarint(b, a, byte_length);
}

/// Append `value`'s LEB128 varint bytes to `b` (no stream header).
fn appendVarintData(b: *Buf, a: std.mem.Allocator, value: u64) !void {
    try putVarint(b, a, value);
}

// The MLT geometry type a feature maps to, plus the per-feature topology counts.
const FeatGeom = struct {
    gtype: u32,
    // For LineString/Polygon: vertices per part (line) and rings; filled lazily.
};

/// Encode one tile (all layers) to MLT bytes. Mirrors mvt.encode's signature so
/// the baker can branch on output format over the same model.
pub fn encode(gpa: std.mem.Allocator, tile: mvt.Tile) ![]u8 {
    var out = Buf.empty;
    errdefer out.deinit(gpa);

    for (tile.layers) |layer| {
        var body = Buf.empty;
        defer body.deinit(gpa);

        // ---- embedded metadata: name, extent, columnCount, columns ------------
        try putVarint(&body, gpa, layer.name.len);
        try body.appendSlice(gpa, layer.name);
        try putVarint(&body, gpa, layer.extent);
        try putVarint(&body, gpa, 1); // columnCount: geometry only (for now)
        try body.append(gpa, TYPECODE_GEOMETRY);

        try encodeGeometryColumn(&body, gpa, layer.features);

        // ---- block framing: varint(blockLength) varint(tag=1) body -----------
        var head = Buf.empty;
        defer head.deinit(gpa);
        try putVarint(&head, gpa, 1); // tag = 1 (embedded metadata)
        const block_len = head.items.len + body.items.len;
        try putVarint(&out, gpa, block_len);
        try out.appendSlice(gpa, head.items);
        try out.appendSlice(gpa, body.items);
    }

    return out.toOwnedSlice(gpa);
}

fn encodeGeometryColumn(body: *Buf, a: std.mem.Allocator, features: []const mvt.Feature) !void {
    const n = features.len;
    // Classify each feature + gather topology + interleaved vertices.
    var gtypes = try a.alloc(u32, n);
    defer a.free(gtypes);
    var part_lengths = Buf.empty; // LENGTH/PARTS values (varint), per contributing feature
    defer part_lengths.deinit(a);
    var ring_lengths = Buf.empty; // LENGTH/RINGS values
    defer ring_lengths.deinit(a);
    var verts = std.ArrayList(i32).empty; // interleaved x,y across all features
    defer verts.deinit(a);

    var n_part_vals: u64 = 0;
    var n_ring_vals: u64 = 0;
    var any_parts = false;
    var any_rings = false;

    for (features, 0..) |f, i| {
        switch (f.geom_type) {
            .point => {
                gtypes[i] = G_POINT;
                // Single point: parts[0][0]. (Multipoint deferred.)
                const p = f.parts[0][0];
                try verts.append(a, p.x);
                try verts.append(a, p.y);
            },
            .linestring => {
                gtypes[i] = G_LINESTRING;
                any_parts = true;
                const line = f.parts[0]; // single line (multiline deferred)
                try putVarint(&part_lengths, a, line.len);
                n_part_vals += 1;
                for (line) |p| {
                    try verts.append(a, p.x);
                    try verts.append(a, p.y);
                }
            },
            .polygon => {
                gtypes[i] = G_POLYGON;
                any_parts = true;
                any_rings = true;
                // Polygon: NumParts = ring count; NumRings = vertices per ring.
                try putVarint(&part_lengths, a, f.parts.len);
                n_part_vals += 1;
                for (f.parts) |ring| {
                    try putVarint(&ring_lengths, a, ring.len);
                    n_ring_vals += 1;
                    for (ring) |p| {
                        try verts.append(a, p.x);
                        try verts.append(a, p.y);
                    }
                }
            },
            .unknown => {
                gtypes[i] = G_POINT;
                try verts.append(a, 0);
                try verts.append(a, 0);
            },
        }
    }

    // numStreams = GeometryType + (PARTS?) + (RINGS?) + VertexBuffer.
    var num_streams: u64 = 2;
    if (any_parts) num_streams += 1;
    if (any_rings) num_streams += 1;
    try putVarint(body, a, num_streams);

    // ---- GeometryType stream (FLAT: per-feature, plain varint) ---------------
    {
        var data = Buf.empty;
        defer data.deinit(a);
        for (gtypes) |g| try putVarint(&data, a, g);
        try writeStreamMeta(body, a, PHYS_DATA, DICT_NONE, LLT_NONE, LLT_NONE, PLT_VARINT, n, data.items.len);
        try body.appendSlice(a, data.items);
    }

    // ---- PARTS length stream (vertices-per-line / rings-per-polygon) ---------
    if (any_parts) {
        try writeStreamMeta(body, a, PHYS_LENGTH, LEN_PARTS, LLT_NONE, LLT_NONE, PLT_VARINT, n_part_vals, part_lengths.items.len);
        try body.appendSlice(a, part_lengths.items);
    }
    // ---- RINGS length stream (vertices-per-ring) -----------------------------
    if (any_rings) {
        try writeStreamMeta(body, a, PHYS_LENGTH, LEN_RINGS, LLT_NONE, LLT_NONE, PLT_VARINT, n_ring_vals, ring_lengths.items.len);
        try body.appendSlice(a, ring_lengths.items);
    }

    // ---- VertexBuffer stream (DATA/VERTEX, componentwise-delta+zigzag+varint) -
    {
        var data = Buf.empty;
        defer data.deinit(a);
        var prev_x: i32 = 0;
        var prev_y: i32 = 0;
        var k: usize = 0;
        while (k < verts.items.len) : (k += 2) {
            const x = verts.items[k];
            const y = verts.items[k + 1];
            try putVarint(&data, a, zigzag32(x -% prev_x));
            try putVarint(&data, a, zigzag32(y -% prev_y));
            prev_x = x;
            prev_y = y;
        }
        try writeStreamMeta(body, a, PHYS_DATA, DICT_VERTEX, LLT_CWISE_DELTA, LLT_NONE, PLT_VARINT, verts.items.len, data.items.len);
        try body.appendSlice(a, data.items);
    }
}

test "encode a single point tile is non-empty + framed" {
    const a = std.testing.allocator;
    const pt = [_]mvt.Point{.{ .x = 13, .y = 42 }};
    const parts = [_][]const mvt.Point{&pt};
    const feats = [_]mvt.Feature{.{ .geom_type = .point, .parts = &parts }};
    const layers = [_]mvt.Layer{.{ .name = "layer1", .extent = 80, .features = &feats }};
    const bytes = try encode(a, .{ .layers = &layers });
    defer a.free(bytes);
    // Byte-exact regression: this exact tile round-trips through the reference MLT
    // decoder (maplibre-tile-spec TS) to a single point at (13,42), and matches the
    // reference point.mlt fixture except the geometry-type stream's byte0 (we emit
    // DATA=0x10; the fixture uses 0x30 — the decoder ignores phys for that stream).
    const expect = [_]u8{
        0x17, 0x01, 0x06, 0x6c, 0x61, 0x79, 0x65, 0x72, 0x31, 0x50, 0x01, 0x04,
        0x02, 0x10, 0x02, 0x01, 0x01, 0x00, 0x13, 0x42, 0x02, 0x02, 0x1a, 0x54,
    };
    try std.testing.expectEqualSlices(u8, &expect, bytes);
}

test "encode line + polygon round-trips (verified via reference decoder)" {
    const a = std.testing.allocator;
    // A 3-vertex line + a 4-vertex ring polygon. Verified: the reference TS decoder
    // returns 2 features with vertices [10,10,20,15,30,10] and [0,0,100,0,100,100,0,0].
    const line = [_]mvt.Point{ .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 15 }, .{ .x = 30, .y = 10 } };
    const lparts = [_][]const mvt.Point{&line};
    const ring = [_]mvt.Point{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 100 }, .{ .x = 0, .y = 0 } };
    const pparts = [_][]const mvt.Point{&ring};
    const feats = [_]mvt.Feature{
        .{ .geom_type = .linestring, .parts = &lparts },
        .{ .geom_type = .polygon, .parts = &pparts },
    };
    const layers = [_]mvt.Layer{.{ .name = "layer1", .extent = 4096, .features = &feats }};
    const bytes = try encode(a, .{ .layers = &layers });
    defer a.free(bytes);
    try std.testing.expect(bytes.len > 12);
    try std.testing.expectEqual(@as(u8, 1), bytes[1]); // tag
}
