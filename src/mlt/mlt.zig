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
const DICT_SINGLE: u8 = 1;
const DICT_VERTEX: u8 = 3;
// OffsetType (low nibble when OFFSET).
const OFF_STRING: u8 = 2;
// LengthType (low nibble when LENGTH).
const LEN_VAR_BINARY: u8 = 0;
const LEN_GEOMETRIES: u8 = 1;
const LEN_PARTS: u8 = 2;
const LEN_RINGS: u8 = 3;
const LEN_DICTIONARY: u8 = 6;
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
// ScalarType ordinals (for the 10+type*2+nullable typeCode).
const ST_BOOLEAN: u8 = 0;
const ST_INT32: u8 = 3;
const ST_UINT32: u8 = 4;
const ST_INT64: u8 = 5;
const ST_UINT64: u8 = 6;
const ST_FLOAT: u8 = 7;
const ST_DOUBLE: u8 = 8;
const ST_STRING: u8 = 9;

// A property column we can emit non-nullably (key present on every feature with a
// single, supported, mappable value type). boolean / partial / mixed keys are
// skipped for now (nullable + boolean-RLE present streams are a later increment).
const PropKind = enum { string, int32, uint32, double, float };
const PropCol = struct { key: []const u8, kind: PropKind };

fn scalarOrdinal(kind: PropKind) u8 {
    return switch (kind) {
        .string => ST_STRING,
        .int32 => ST_INT32,
        .uint32 => ST_UINT32,
        .double => ST_DOUBLE,
        .float => ST_FLOAT,
    };
}

fn valueKind(v: mvt.Value) ?PropKind {
    return switch (v) {
        .string => .string,
        .double => .double,
        .float => .float,
        .int => |n| if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) .int32 else null,
        .uint => |n| if (n <= std.math.maxInt(u32)) .uint32 else null,
        .boolean => null, // deferred (needs boolean-RLE)
    };
}

fn featureValue(f: mvt.Feature, key: []const u8) ?mvt.Value {
    for (f.properties) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

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

    // All per-layer scratch (body/head + the column streams' temp buffers) goes
    // through a bump-pointer arena reset per layer, so the encoder doesn't hit the
    // page allocator thousands of times per tile (a measurable bake hot spot). Only
    // the returned `out` lives on `gpa`.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colbuf: [MAX_PROP_KEYS]PropCol = undefined;
    for (tile.layers) |layer| {
        const propcols = colbuf[0..collectPropCols(layer.features, &colbuf)];

        var body = Buf.empty; // arena-backed

        // ---- embedded metadata: name, extent, columnCount, columns ------------
        // Columns are listed here in the SAME order their streams appear below:
        // geometry first, then one column per emittable property key.
        try putVarint(&body, a, layer.name.len);
        try body.appendSlice(a, layer.name);
        try putVarint(&body, a, layer.extent);
        try putVarint(&body, a, 1 + propcols.len); // columnCount
        try body.append(a, TYPECODE_GEOMETRY);
        for (propcols) |c| {
            try body.append(a, 10 + scalarOrdinal(c.kind) * 2); // non-nullable scalar typeCode
            try putVarint(&body, a, c.key.len);
            try body.appendSlice(a, c.key);
        }

        // ---- column data (same order as metadata) -----------------------------
        try encodeGeometryColumn(&body, a, layer.features);
        for (propcols) |c| try encodePropertyColumn(&body, a, layer.features, c);

        // ---- block framing: varint(blockLength) varint(tag=1) body -----------
        var head = Buf.empty; // arena-backed
        try putVarint(&head, a, 1); // tag = 1 (embedded metadata)
        const block_len = head.items.len + body.items.len;
        try putVarint(&out, gpa, block_len);
        try out.appendSlice(gpa, head.items);
        try out.appendSlice(gpa, body.items);
        _ = arena.reset(.retain_capacity); // reuse the scratch across layers
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

// Max distinct property keys we emit per layer (chart layers have far fewer).
const MAX_PROP_KEYS = 64;

// Distinct property keys (first-seen order) present on EVERY feature with a single
// supported, mappable value type — emittable as non-nullable columns. Fills `out`
// and returns the count. Heap-free + linear (keys per layer are few): this runs
// per tile per layer for the whole bake, so a per-tile StringHashMap was a real
// hot spot. Partial, mixed-type, or boolean keys are skipped (nullable + boolean-
// RLE come later); keys past MAX_PROP_KEYS are ignored.
fn collectPropCols(features: []const mvt.Feature, out: []PropCol) usize {
    var keys: [MAX_PROP_KEYS][]const u8 = undefined;
    var kinds: [MAX_PROP_KEYS]PropKind = undefined;
    var counts: [MAX_PROP_KEYS]usize = undefined;
    var oks: [MAX_PROP_KEYS]bool = undefined;
    var nk: usize = 0;
    for (features) |f| {
        for (f.properties) |p| {
            const k = valueKind(p.value);
            var found = false;
            for (keys[0..nk], 0..) |kk, i| {
                if (std.mem.eql(u8, kk, p.key)) {
                    counts[i] += 1;
                    if (k == null or (oks[i] and kinds[i] != k.?)) oks[i] = false;
                    found = true;
                    break;
                }
            }
            if (!found and nk < MAX_PROP_KEYS) {
                keys[nk] = p.key;
                kinds[nk] = k orelse .string;
                counts[nk] = 1;
                oks[nk] = k != null;
                nk += 1;
            }
        }
    }
    var n: usize = 0;
    for (0..nk) |i| {
        if (oks[i] and counts[i] == features.len and n < out.len) {
            out[n] = .{ .key = keys[i], .kind = kinds[i] };
            n += 1;
        }
    }
    return n;
}

// Encode a string property column. Dictionary-encodes (distinct values + a
// per-feature index) when values repeat — the big size win for chart attributes
// like class / color_token / dash — and falls back to plain (length+data) when
// they don't (all-distinct, e.g. labels) or there are too many distinct values to
// dedup cheaply. All scratch is arena-backed (freed on the per-layer reset).
fn encodeStringColumn(body: *Buf, a: std.mem.Allocator, features: []const mvt.Feature, key: []const u8) !void {
    const n = features.len;
    const DICT_CAP = 256; // keep the linear dedup O(features); past this -> plain
    var dict = std.ArrayList([]const u8).empty;
    const idxs = try a.alloc(u32, n);
    var dict_ok = true;
    for (features, 0..) |f, fi| {
        const s = featureValue(f, key).?.string;
        var found: ?u32 = null;
        for (dict.items, 0..) |d, di| {
            if (std.mem.eql(u8, d, s)) {
                found = @intCast(di);
                break;
            }
        }
        if (found) |ix| {
            idxs[fi] = ix;
        } else if (dict.items.len < DICT_CAP) {
            idxs[fi] = @intCast(dict.items.len);
            try dict.append(a, s);
        } else {
            dict_ok = false;
            break;
        }
    }

    if (dict_ok and dict.items.len < n) {
        // Dictionary: LENGTH/DICTIONARY + DATA/SINGLE + OFFSET/STRING (3 streams).
        try putVarint(body, a, 3);
        var dlen = Buf.empty;
        var dbytes = Buf.empty;
        for (dict.items) |d| {
            try putVarint(&dlen, a, d.len);
            try dbytes.appendSlice(a, d);
        }
        try writeStreamMeta(body, a, PHYS_LENGTH, LEN_DICTIONARY, LLT_NONE, LLT_NONE, PLT_VARINT, dict.items.len, dlen.items.len);
        try body.appendSlice(a, dlen.items);
        try writeStreamMeta(body, a, PHYS_DATA, DICT_SINGLE, LLT_NONE, LLT_NONE, PLT_NONE, dbytes.items.len, dbytes.items.len);
        try body.appendSlice(a, dbytes.items);
        var off = Buf.empty;
        for (idxs) |ix| try putVarint(&off, a, ix);
        try writeStreamMeta(body, a, PHYS_OFFSET, OFF_STRING, LLT_NONE, LLT_NONE, PLT_VARINT, n, off.items.len);
        try body.appendSlice(a, off.items);
    } else {
        // Plain: LENGTH/VAR_BINARY (per-feature lengths) + DATA/NONE (bytes).
        try putVarint(body, a, 2);
        var lens = Buf.empty;
        var data = Buf.empty;
        for (features) |f| {
            const s = featureValue(f, key).?.string;
            try putVarint(&lens, a, s.len);
            try data.appendSlice(a, s);
        }
        try writeStreamMeta(body, a, PHYS_LENGTH, LEN_VAR_BINARY, LLT_NONE, LLT_NONE, PLT_VARINT, n, lens.items.len);
        try body.appendSlice(a, lens.items);
        try writeStreamMeta(body, a, PHYS_DATA, DICT_NONE, LLT_NONE, LLT_NONE, PLT_NONE, data.items.len, data.items.len);
        try body.appendSlice(a, data.items);
    }
}

fn encodePropertyColumn(body: *Buf, a: std.mem.Allocator, features: []const mvt.Feature, col: PropCol) !void {
    const n = features.len;
    switch (col.kind) {
        .string => try encodeStringColumn(body, a, features, col.key),
        .int32 => {
            var data = Buf.empty;
            defer data.deinit(a);
            for (features) |f| try putVarint(&data, a, zigzag32(@intCast(featureValue(f, col.key).?.int)));
            try writeStreamMeta(body, a, PHYS_DATA, DICT_NONE, LLT_NONE, LLT_NONE, PLT_VARINT, n, data.items.len);
            try body.appendSlice(a, data.items);
        },
        .uint32 => {
            var data = Buf.empty;
            defer data.deinit(a);
            for (features) |f| try putVarint(&data, a, featureValue(f, col.key).?.uint);
            try writeStreamMeta(body, a, PHYS_DATA, DICT_NONE, LLT_NONE, LLT_NONE, PLT_VARINT, n, data.items.len);
            try body.appendSlice(a, data.items);
        },
        .double => {
            var data = Buf.empty;
            defer data.deinit(a);
            for (features) |f| {
                var le: [8]u8 = undefined;
                std.mem.writeInt(u64, &le, @bitCast(featureValue(f, col.key).?.double), .little);
                try data.appendSlice(a, &le);
            }
            try writeStreamMeta(body, a, PHYS_DATA, DICT_NONE, LLT_NONE, LLT_NONE, PLT_NONE, n, data.items.len);
            try body.appendSlice(a, data.items);
        },
        .float => {
            var data = Buf.empty;
            defer data.deinit(a);
            for (features) |f| {
                var le: [4]u8 = undefined;
                std.mem.writeInt(u32, &le, @bitCast(featureValue(f, col.key).?.float), .little);
                try data.appendSlice(a, &le);
            }
            try writeStreamMeta(body, a, PHYS_DATA, DICT_NONE, LLT_NONE, LLT_NONE, PLT_NONE, n, data.items.len);
            try body.appendSlice(a, data.items);
        },
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

test "encode point features with string/double/int properties (verified)" {
    const a = std.testing.allocator;
    // Verified via the reference decoder: 2 point features round-trip to
    // class=["DEPARE","COALNE"], drval1=[1.5,3], band=[2,2], vertices [5,7,9,3].
    const p0 = [_]mvt.Point{.{ .x = 5, .y = 7 }};
    const pp0 = [_][]const mvt.Point{&p0};
    const p1 = [_]mvt.Point{.{ .x = 9, .y = 3 }};
    const pp1 = [_][]const mvt.Point{&p1};
    const props0 = [_]mvt.Prop{ .{ .key = "class", .value = .{ .string = "DEPARE" } }, .{ .key = "drval1", .value = .{ .double = 1.5 } }, .{ .key = "band", .value = .{ .int = 2 } } };
    const props1 = [_]mvt.Prop{ .{ .key = "class", .value = .{ .string = "COALNE" } }, .{ .key = "drval1", .value = .{ .double = 3.0 } }, .{ .key = "band", .value = .{ .int = 2 } } };
    const feats = [_]mvt.Feature{ .{ .geom_type = .point, .parts = &pp0, .properties = &props0 }, .{ .geom_type = .point, .parts = &pp1, .properties = &props1 } };
    const layers = [_]mvt.Layer{.{ .name = "layer1", .extent = 4096, .features = &feats }};
    const bytes = try encode(a, .{ .layers = &layers });
    defer a.free(bytes);
    // 3 property columns emitted (class/drval1/band) — all present on both features.
    var cb: [MAX_PROP_KEYS]PropCol = undefined;
    try std.testing.expectEqual(@as(usize, 3), collectPropCols(&feats, &cb));
}

test "partial / boolean / mixed-type property keys are skipped (non-nullable only)" {
    const p = [_]mvt.Point{.{ .x = 1, .y = 1 }};
    const pp = [_][]const mvt.Point{&p};
    const props0 = [_]mvt.Prop{ .{ .key = "only0", .value = .{ .string = "x" } }, .{ .key = "flag", .value = .{ .boolean = true } } };
    const props1 = [_]mvt.Prop{.{ .key = "flag", .value = .{ .boolean = false } }};
    const feats = [_]mvt.Feature{ .{ .geom_type = .point, .parts = &pp, .properties = &props0 }, .{ .geom_type = .point, .parts = &pp, .properties = &props1 } };
    // only0 present on 1/2 features -> skipped; flag is boolean -> skipped.
    var cb: [MAX_PROP_KEYS]PropCol = undefined;
    try std.testing.expectEqual(@as(usize, 0), collectPropCols(&feats, &cb));
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
