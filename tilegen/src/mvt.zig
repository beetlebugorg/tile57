//! Mapbox Vector Tile (MVT) v2 encoder + a minimal decoder for tests.
//!
//! The encoder takes plain-data `Tile`/`Layer`/`Feature` structs (so the same
//! types cross the C ABI later) and produces protobuf bytes per the MVT spec:
//! https://github.com/mapbox/vector-tile-spec/tree/master/2.1
//!
//! Geometry coordinates are already in tile space (0..extent); the encoder does
//! the command/zigzag/delta encoding. This mirrors internal/engine/mvt in the
//! Go reference.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GeomType = enum(u32) { unknown = 0, point = 1, linestring = 2, polygon = 3 };

pub const Point = struct { x: i32, y: i32 };

/// A tag value. Strings are borrowed; the caller owns them for the encode call.
pub const Value = union(enum) {
    string: []const u8,
    float: f32,
    double: f64,
    int: i64,
    uint: u64,
    boolean: bool,

    fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => std.mem.eql(u8, a.string, b.string),
            .float => a.float == b.float,
            .double => a.double == b.double,
            .int => a.int == b.int,
            .uint => a.uint == b.uint,
            .boolean => a.boolean == b.boolean,
        };
    }
};

pub const Prop = struct { key: []const u8, value: Value };

pub const Feature = struct {
    id: ?u64 = null,
    geom_type: GeomType,
    /// Geometry parts: one part per point (points), per line (linestrings), or
    /// per ring — exterior then holes — (polygons). Coordinates in tile space.
    parts: []const []const Point,
    properties: []const Prop = &.{},
};

pub const Layer = struct {
    name: []const u8,
    extent: u32 = 4096,
    features: []const Feature,
};

pub const Tile = struct {
    layers: []const Layer,
};

// ---- protobuf primitives ------------------------------------------------

const Buf = std.ArrayList(u8);

fn putVarint(b: *Buf, a: Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) {
        try b.append(a, @intCast((v & 0x7F) | 0x80));
    }
    try b.append(a, @intCast(v));
}

fn putTag(b: *Buf, a: Allocator, field: u32, wire: u3) !void {
    try putVarint(b, a, (@as(u64, field) << 3) | wire);
}

fn putLenDelim(b: *Buf, a: Allocator, field: u32, bytes: []const u8) !void {
    try putTag(b, a, field, 2);
    try putVarint(b, a, bytes.len);
    try b.appendSlice(a, bytes);
}

fn zigzag(n: i64) u64 {
    return @bitCast((n << 1) ^ (n >> 63));
}

// ---- geometry -----------------------------------------------------------

fn cmd(id: u32, count: u32) u32 {
    return (id & 0x7) | (count << 3);
}

fn encodeGeometry(b: *Buf, a: Allocator, gt: GeomType, parts: []const []const Point) !void {
    var cx: i32 = 0;
    var cy: i32 = 0;
    for (parts) |part| {
        if (part.len == 0) continue;
        switch (gt) {
            .point => {
                // A single MoveTo covering all points in this "part".
                try putVarint(b, a, cmd(1, @intCast(part.len)));
                for (part) |p| {
                    try putVarint(b, a, zigzag(p.x - cx));
                    try putVarint(b, a, zigzag(p.y - cy));
                    cx = p.x;
                    cy = p.y;
                }
            },
            .linestring, .polygon => {
                // MoveTo first vertex.
                try putVarint(b, a, cmd(1, 1));
                try putVarint(b, a, zigzag(part[0].x - cx));
                try putVarint(b, a, zigzag(part[0].y - cy));
                cx = part[0].x;
                cy = part[0].y;
                // For polygons the ring is implicitly closed, so we don't repeat
                // the first point as the last; LineTo the remaining vertices.
                const rest = part[1..];
                if (rest.len > 0) {
                    try putVarint(b, a, cmd(2, @intCast(rest.len)));
                    for (rest) |p| {
                        try putVarint(b, a, zigzag(p.x - cx));
                        try putVarint(b, a, zigzag(p.y - cy));
                        cx = p.x;
                        cy = p.y;
                    }
                }
                if (gt == .polygon) try putVarint(b, a, cmd(7, 1)); // ClosePath
            },
            .unknown => {},
        }
    }
}

// ---- value encoding -----------------------------------------------------

fn encodeValue(b: *Buf, a: Allocator, v: Value) !void {
    var inner = Buf.empty;
    defer inner.deinit(a);
    switch (v) {
        .string => |s| try putLenDelim(&inner, a, 1, s),
        .float => |f| {
            try putTag(&inner, a, 2, 5);
            const bits: u32 = @bitCast(f);
            try inner.appendSlice(a, std.mem.asBytes(&std.mem.nativeToLittle(u32, bits)));
        },
        .double => |d| {
            try putTag(&inner, a, 3, 1);
            const bits: u64 = @bitCast(d);
            try inner.appendSlice(a, std.mem.asBytes(&std.mem.nativeToLittle(u64, bits)));
        },
        .int => |i| {
            try putTag(&inner, a, 4, 0);
            try putVarint(&inner, a, @bitCast(i));
        },
        .uint => |u| {
            try putTag(&inner, a, 5, 0);
            try putVarint(&inner, a, u);
        },
        .boolean => |x| {
            try putTag(&inner, a, 7, 0);
            try putVarint(&inner, a, @intFromBool(x));
        },
    }
    try putLenDelim(b, a, 4, inner.items); // Layer.values (field 4)
}

// ---- encode -------------------------------------------------------------

/// Encode a tile to MVT protobuf bytes. Caller owns the returned slice.
pub fn encode(gpa: Allocator, tile: Tile) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out = Buf.empty;
    errdefer out.deinit(gpa);

    for (tile.layers) |layer| {
        var lb = Buf.empty; // layer message body

        // Intern keys and values across this layer's features.
        var keys = std.ArrayList([]const u8).empty;
        var values = std.ArrayList(Value).empty;
        var key_idx = std.StringHashMap(u32).init(a);

        // Pre-compute per-feature tag arrays.
        var feat_tags = std.ArrayList([]u32).empty;
        for (layer.features) |f| {
            var tags = std.ArrayList(u32).empty;
            for (f.properties) |p| {
                const ki = key_idx.get(p.key) orelse blk: {
                    const idx: u32 = @intCast(keys.items.len);
                    try keys.append(a, p.key);
                    try key_idx.put(p.key, idx);
                    break :blk idx;
                };
                // Find or add the value (linear; value sets are small per layer).
                var vi: u32 = 0;
                const found = for (values.items, 0..) |vv, i| {
                    if (vv.eql(p.value)) break @as(u32, @intCast(i));
                } else null;
                if (found) |fi| {
                    vi = fi;
                } else {
                    vi = @intCast(values.items.len);
                    try values.append(a, p.value);
                }
                try tags.append(a, ki);
                try tags.append(a, vi);
            }
            try feat_tags.append(a, tags.items);
        }

        // version = 15 (field 15, varint)
        try putTag(&lb, a, 15, 0);
        try putVarint(&lb, a, 2);
        // name = 1
        try putLenDelim(&lb, a, 1, layer.name);

        // features = 2
        for (layer.features, 0..) |f, fi| {
            var fb = Buf.empty;
            if (f.id) |id| {
                try putTag(&fb, a, 1, 0);
                try putVarint(&fb, a, id);
            }
            // tags = 2 (packed)
            const tags = feat_tags.items[fi];
            if (tags.len > 0) {
                var tb = Buf.empty;
                for (tags) |t| try putVarint(&tb, a, t);
                try putLenDelim(&fb, a, 2, tb.items);
            }
            // type = 3
            try putTag(&fb, a, 3, 0);
            try putVarint(&fb, a, @intFromEnum(f.geom_type));
            // geometry = 4 (packed)
            var gb = Buf.empty;
            try encodeGeometry(&gb, a, f.geom_type, f.parts);
            try putLenDelim(&fb, a, 4, gb.items);

            try putLenDelim(&lb, a, 2, fb.items);
        }

        // keys = 3
        for (keys.items) |k| try putLenDelim(&lb, a, 3, k);
        // values = 4
        for (values.items) |v| try encodeValue(&lb, a, v);
        // extent = 5
        if (layer.extent != 4096) {
            try putTag(&lb, a, 5, 0);
            try putVarint(&lb, a, layer.extent);
        }

        // Tile.layers = 3
        try putLenDelim(&out, gpa, 3, lb.items);
    }

    return out.toOwnedSlice(gpa);
}

// ---- minimal decoder (for tests) ---------------------------------------

pub const DecodedFeature = struct {
    geom_type: GeomType,
    parts: [][]Point,
    properties: []Prop,
};
pub const DecodedLayer = struct {
    name: []const u8,
    extent: u32,
    features: []DecodedFeature,
};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn varint(r: *Reader) u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = r.buf[r.pos];
            r.pos += 1;
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }
    fn bytes(r: *Reader, n: usize) []const u8 {
        const s = r.buf[r.pos .. r.pos + n];
        r.pos += n;
        return s;
    }
};

fn unzig(u: u64) i64 {
    const i: i64 = @bitCast(u >> 1);
    return i ^ -@as(i64, @intCast(u & 1));
}

/// Decode for tests. Everything is allocated in `a` (use an arena).
pub fn decode(a: Allocator, data: []const u8) ![]DecodedLayer {
    var layers = std.ArrayList(DecodedLayer).empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        if (field == 3 and wire == 2) {
            const len = r.varint();
            const lay = try decodeLayer(a, r.bytes(@intCast(len)));
            try layers.append(a, lay);
        } else skip(&r, wire);
    }
    return layers.items;
}

fn skip(r: *Reader, wire: u64) void {
    switch (wire) {
        0 => _ = r.varint(),
        2 => {
            const n = r.varint();
            _ = r.bytes(@intCast(n));
        },
        5 => r.pos += 4,
        1 => r.pos += 8,
        else => {},
    }
}

fn decodeLayer(a: Allocator, data: []const u8) !DecodedLayer {
    var name: []const u8 = "";
    var extent: u32 = 4096;
    var keys = std.ArrayList([]const u8).empty;
    var values = std.ArrayList(Value).empty;
    var feat_bufs = std.ArrayList([]const u8).empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        switch (field) {
            15 => _ = r.varint(),
            1 => {
                const n = r.varint();
                name = r.bytes(@intCast(n));
            },
            2 => {
                const n = r.varint();
                try feat_bufs.append(a, r.bytes(@intCast(n)));
            },
            3 => {
                const n = r.varint();
                try keys.append(a, r.bytes(@intCast(n)));
            },
            4 => {
                const n = r.varint();
                try values.append(a, try decodeValue(r.bytes(@intCast(n))));
            },
            5 => extent = @intCast(r.varint()),
            else => skip(&r, wire),
        }
    }
    var feats = std.ArrayList(DecodedFeature).empty;
    for (feat_bufs.items) |fb| {
        try feats.append(a, try decodeFeature(a, fb, keys.items, values.items));
    }
    return .{ .name = name, .extent = extent, .features = feats.items };
}

fn decodeValue(data: []const u8) !Value {
    var r = Reader{ .buf = data };
    const tag = r.varint();
    const field = tag >> 3;
    return switch (field) {
        1 => .{ .string = r.bytes(@intCast(r.varint())) },
        2 => blk: {
            const bits = std.mem.readInt(u32, data[r.pos..][0..4], .little);
            break :blk .{ .float = @bitCast(bits) };
        },
        3 => blk: {
            const bits = std.mem.readInt(u64, data[r.pos..][0..8], .little);
            break :blk .{ .double = @bitCast(bits) };
        },
        4 => .{ .int = @bitCast(r.varint()) },
        5 => .{ .uint = r.varint() },
        7 => .{ .boolean = r.varint() != 0 },
        else => .{ .int = 0 },
    };
}

fn decodeFeature(a: Allocator, data: []const u8, keys: [][]const u8, values: []Value) !DecodedFeature {
    var gt: GeomType = .unknown;
    var tags = std.ArrayList(u32).empty;
    var geom = std.ArrayList(u32).empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = r.varint();
        const field = tag >> 3;
        const wire = tag & 7;
        switch (field) {
            1 => _ = r.varint(),
            2 => {
                const n = r.varint();
                const end = r.pos + @as(usize, @intCast(n));
                while (r.pos < end) try tags.append(a, @intCast(r.varint()));
            },
            3 => gt = @enumFromInt(r.varint()),
            4 => {
                const n = r.varint();
                const end = r.pos + @as(usize, @intCast(n));
                while (r.pos < end) try geom.append(a, @intCast(r.varint()));
            },
            else => skip(&r, wire),
        }
    }
    // properties
    var props = std.ArrayList(Prop).empty;
    var i: usize = 0;
    while (i + 1 < tags.items.len) : (i += 2) {
        try props.append(a, .{ .key = keys[tags.items[i]], .value = values[tags.items[i + 1]] });
    }
    // geometry
    const parts = try decodeGeometry(a, gt, geom.items);
    return .{ .geom_type = gt, .parts = parts, .properties = props.items };
}

fn decodeGeometry(a: Allocator, gt: GeomType, g: []const u32) ![][]Point {
    var parts = std.ArrayList([]Point).empty;
    var cur = std.ArrayList(Point).empty;
    var cx: i32 = 0;
    var cy: i32 = 0;
    var i: usize = 0;
    while (i < g.len) {
        const command = g[i] & 0x7;
        const count = g[i] >> 3;
        i += 1;
        switch (command) {
            1 => { // MoveTo
                var k: u32 = 0;
                while (k < count) : (k += 1) {
                    if (gt != .point and cur.items.len > 0) {
                        try parts.append(a, cur.items);
                        cur = std.ArrayList(Point).empty;
                    }
                    cx += @intCast(unzig(g[i]));
                    cy += @intCast(unzig(g[i + 1]));
                    i += 2;
                    try cur.append(a, .{ .x = cx, .y = cy });
                }
            },
            2 => { // LineTo
                var k: u32 = 0;
                while (k < count) : (k += 1) {
                    cx += @intCast(unzig(g[i]));
                    cy += @intCast(unzig(g[i + 1]));
                    i += 2;
                    try cur.append(a, .{ .x = cx, .y = cy });
                }
            },
            7 => {}, // ClosePath: ring implicitly closed
            else => {},
        }
    }
    if (cur.items.len > 0) try parts.append(a, cur.items);
    return parts.items;
}

// ---- tests --------------------------------------------------------------

test "round-trip point + polygon with properties" {
    const a = std.testing.allocator;

    const pt_parts = [_][]const Point{&.{.{ .x = 100, .y = 200 }}};
    const poly_parts = [_][]const Point{&.{
        .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 },
    }};
    const feats = [_]Feature{
        .{ .geom_type = .point, .parts = &pt_parts, .properties = &.{
            .{ .key = "class", .value = .{ .string = "BOYLAT" } },
            .{ .key = "scale", .value = .{ .double = 0.5 } },
        } },
        .{ .geom_type = .polygon, .parts = &poly_parts, .properties = &.{
            .{ .key = "class", .value = .{ .string = "DEPARE" } },
            .{ .key = "drval1", .value = .{ .int = 5 } },
        } },
    };
    const layers = [_]Layer{.{ .name = "test", .features = &feats }};
    const tile = Tile{ .layers = &layers };

    const bytes = try encode(a, tile);
    defer a.free(bytes);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const dec = try decode(arena.allocator(), bytes);

    try std.testing.expectEqual(@as(usize, 1), dec.len);
    try std.testing.expectEqualStrings("test", dec[0].name);
    try std.testing.expectEqual(@as(u32, 4096), dec[0].extent);
    try std.testing.expectEqual(@as(usize, 2), dec[0].features.len);

    const p = dec[0].features[0];
    try std.testing.expectEqual(GeomType.point, p.geom_type);
    try std.testing.expectEqual(@as(i32, 100), p.parts[0][0].x);
    try std.testing.expectEqual(@as(i32, 200), p.parts[0][0].y);

    const poly = dec[0].features[1];
    try std.testing.expectEqual(GeomType.polygon, poly.geom_type);
    try std.testing.expectEqual(@as(usize, 4), poly.parts[0].len);
    try std.testing.expectEqual(@as(i32, 10), poly.parts[0][2].x);

    // property round-trip
    try std.testing.expectEqualStrings("class", poly.properties[0].key);
    try std.testing.expectEqualStrings("DEPARE", poly.properties[0].value.string);
    try std.testing.expectEqual(@as(i64, 5), poly.properties[1].value.int);
}

test "zigzag" {
    try std.testing.expectEqual(@as(u64, 0), zigzag(0));
    try std.testing.expectEqual(@as(u64, 1), zigzag(-1));
    try std.testing.expectEqual(@as(u64, 2), zigzag(1));
    try std.testing.expectEqual(@as(i64, -1), unzig(zigzag(-1)));
    try std.testing.expectEqual(@as(i64, 12345), unzig(zigzag(12345)));
}
