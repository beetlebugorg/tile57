//! Compose core (Stage 2 of the per-cell-composite bake): clip ONE cell's decoded tile
//! features to the ground it OWNS, so the compositor can merge many cells' clipped tiles
//! into one composed tile with no double-draw at a seam.
//!
//! `face` is the cell's owned rings (from `partition.ownedFace`) projected to THIS tile's
//! pixel space, i64. Areas are intersected with the face, lines clipped to inside it,
//! points kept iff their node is inside. Reuses the geometry primitives — `boolean.compute`
//! (.intersect), `plane.clipLineInsidePolys`, `boolean.pointInEvenOdd` — so there is no new
//! set algebra here, only the mvt↔integer adapters and the per-geometry-type dispatch.

const std = @import("std");
const mvt = @import("tiles").mvt;
const geo = @import("geo");
const boolean = geo.boolean;
const plane = geo.plane;

const Pt = boolean.Pt;

fn widenRing(a: std.mem.Allocator, ring: []const mvt.Point) ![]Pt {
    const out = try a.alloc(Pt, ring.len);
    for (ring, 0..) |p, i| out[i] = .{ .x = p.x, .y = p.y };
    return out;
}

fn narrowRing(a: std.mem.Allocator, ring: []const Pt) ![]mvt.Point {
    const out = try a.alloc(mvt.Point, ring.len);
    for (ring, 0..) |p, i| out[i] = .{ .x = @intCast(p.x), .y = @intCast(p.y) };
    return out;
}

/// Clip `feat` (tile-pixel space) to `face` (the cell's owned rings, tile-pixel space) and
/// append the surviving feature(s) to `out`, or nothing if the feature is entirely outside
/// the face. Geometry is freshly allocated in `a`; `properties` are borrowed from `feat`.
/// `face` must be a simple even-odd ring-set (as `partition.ownedFace` emits).
pub fn clipFeatureToFace(a: std.mem.Allocator, out: *std.ArrayList(mvt.Feature), feat: mvt.DecodedFeature, face: []const []const Pt) !void {
    switch (feat.geom_type) {
        .polygon => {
            const poly = try a.alloc([]const Pt, feat.parts.len);
            for (feat.parts, 0..) |ring, i| poly[i] = try widenRing(a, ring);
            const clipped = try boolean.compute(a, poly, face, .intersect);
            if (clipped.len == 0) return;
            const parts = try a.alloc([]const mvt.Point, clipped.len);
            for (clipped, 0..) |ring, i| parts[i] = try narrowRing(a, ring);
            try out.append(a, .{ .geom_type = .polygon, .parts = parts, .properties = feat.properties });
        },
        .linestring => {
            var parts = std.ArrayList([]const mvt.Point).empty;
            for (feat.parts) |part| {
                const runs = try plane.clipLineInsidePolys(a, try widenRing(a, part), face);
                for (runs) |run| {
                    if (run.len >= 2) try parts.append(a, try narrowRing(a, run));
                }
            }
            if (parts.items.len == 0) return;
            try out.append(a, .{ .geom_type = .linestring, .parts = try parts.toOwnedSlice(a), .properties = feat.properties });
        },
        .point => {
            // MVT points: one part per point. Keep the parts whose node is inside the face.
            var parts = std.ArrayList([]const mvt.Point).empty;
            for (feat.parts) |part| {
                if (part.len == 0) continue;
                if (boolean.pointInEvenOdd(face, part[0].x, part[0].y)) {
                    try parts.append(a, try a.dupe(mvt.Point, part));
                }
            }
            if (parts.items.len == 0) return;
            try out.append(a, .{ .geom_type = .point, .parts = try parts.toOwnedSlice(a), .properties = feat.properties });
        },
        .unknown => {},
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn boxRing(a: std.mem.Allocator, x0: i32, y0: i32, x1: i32, y1: i32) ![]mvt.Point {
    const r = try a.alloc(mvt.Point, 4);
    r[0] = .{ .x = x0, .y = y0 };
    r[1] = .{ .x = x1, .y = y0 };
    r[2] = .{ .x = x1, .y = y1 };
    r[3] = .{ .x = x0, .y = y1 };
    return r;
}

// One decoded feature over the given parts (DecodedFeature.parts is mutable [][]Point).
fn decoded(a: std.mem.Allocator, gt: mvt.GeomType, parts: []const []mvt.Point) !mvt.DecodedFeature {
    const p = try a.alloc([]mvt.Point, parts.len);
    for (parts, 0..) |part, i| p[i] = part;
    return .{ .geom_type = gt, .parts = p, .properties = &.{} };
}

fn boxFace(a: std.mem.Allocator, x0: i64, y0: i64, x1: i64, y1: i64) ![]const []const Pt {
    const r = try a.alloc(Pt, 4);
    r[0] = .{ .x = x0, .y = y0 };
    r[1] = .{ .x = x1, .y = y0 };
    r[2] = .{ .x = x1, .y = y1 };
    r[3] = .{ .x = x0, .y = y1 };
    const rings = try a.alloc([]const Pt, 1);
    rings[0] = r;
    return rings;
}

test "clipFeatureToFace: area is intersected with the face" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A whole-tile area, clipped to the face box [1000,1000]..[3000,3000].
    const ring = try boxRing(a, 0, 0, 4096, 4096);
    const feat = try decoded(a, .polygon, &.{ring});
    const face = try boxFace(a, 1000, 1000, 3000, 3000);

    var out = std.ArrayList(mvt.Feature).empty;
    try clipFeatureToFace(a, &out, feat, face);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // Widen the output back and check: (2000,2000) inside, (500,500) outside.
    const of = out.items[0];
    const wrings = try a.alloc([]const Pt, of.parts.len);
    for (of.parts, 0..) |r, i| wrings[i] = try widenRing(a, r);
    try testing.expect(boolean.pointInEvenOdd(wrings, 2000, 2000));
    try testing.expect(!boolean.pointInEvenOdd(wrings, 500, 500));
}

test "clipFeatureToFace: point kept iff inside the face" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inside = try a.alloc(mvt.Point, 1);
    inside[0] = .{ .x = 2000, .y = 2000 };
    const outside = try a.alloc(mvt.Point, 1);
    outside[0] = .{ .x = 500, .y = 500 };
    const feat = try decoded(a, .point, &.{ inside, outside });
    const face = try boxFace(a, 1000, 1000, 3000, 3000);

    var out = std.ArrayList(mvt.Feature).empty;
    try clipFeatureToFace(a, &out, feat, face);
    try testing.expectEqual(@as(usize, 1), out.items.len); // the feature survives
    try testing.expectEqual(@as(usize, 1), out.items[0].parts.len); // only the inside point
    try testing.expectEqual(@as(i32, 2000), out.items[0].parts[0][0].x);
}

test "clipFeatureToFace: line clipped to the part inside the face" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A horizontal line across the tile at y=2000, clipped to face x∈[1000,3000].
    const line = try a.alloc(mvt.Point, 2);
    line[0] = .{ .x = 0, .y = 2000 };
    line[1] = .{ .x = 4096, .y = 2000 };
    const feat = try decoded(a, .linestring, &.{line});
    const face = try boxFace(a, 1000, 1000, 3000, 3000);

    var out = std.ArrayList(mvt.Feature).empty;
    try clipFeatureToFace(a, &out, feat, face);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const kept = out.items[0].parts[0];
    try testing.expectEqual(@as(i32, 1000), @min(kept[0].x, kept[kept.len - 1].x));
    try testing.expectEqual(@as(i32, 3000), @max(kept[0].x, kept[kept.len - 1].x));
}

test "clipFeatureToFace: feature entirely outside the face is dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ring = try boxRing(a, 0, 0, 500, 500);
    const feat = try decoded(a, .polygon, &.{ring});
    const face = try boxFace(a, 1000, 1000, 3000, 3000);

    var out = std.ArrayList(mvt.Feature).empty;
    try clipFeatureToFace(a, &out, feat, face);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
