//! The compositor's clip core: clip ONE cell's decoded tile features to the ground
//! it OWNS, so the compositor can merge many cells' clipped tiles into one composed
//! tile with no double-draw at a seam.
//!
//! `face` is the cell's owned rings (from `partition.ownedFace`) projected to THIS tile's
//! pixel space, i64 — `projectFace` does that projection, mirroring EXACTLY the baker's
//! `tile.project` + `tile.clipPolygon` on the cell's features, so the face and the features
//! share one pixel space and the intersection is seam-exact. Areas are intersected with the
//! face, lines clipped to inside it, points kept iff their node is inside. Reuses the
//! geometry primitives — `boolean.compute` (.intersect), `plane.clipLineInsidePolys`,
//! `boolean.pointInEvenOdd` — so there is no new set algebra here, only the mvt↔integer
//! adapters and the per-geometry-type dispatch.

const std = @import("std");
const mvt = @import("tiles").mvt;
const tile = @import("tiles").tile;
const geometry = @import("geometry");
const boolean = geometry.boolean;
const plane = geometry.plane;

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

/// A linestring carrying class=LIGHTS is a constructed sector figure (LIGHTS is a
/// point class; its only line output is emitAugFigures legs/arcs). Public so the
/// compositor's reach-ring pass can pick figures out of a neighbouring cell's tile.
pub fn isLightFigure(feat: mvt.DecodedFeature) bool {
    for (feat.properties) |p| {
        if (std.mem.eql(u8, p.key, "class")) {
            return switch (p.value) {
                .string => |v| std.mem.eql(u8, v, "LIGHTS"),
                else => false,
            };
        }
    }
    return false;
}

/// Clip `feat` (tile-pixel space) to `face` (the cell's owned rings, tile-pixel space) and
/// append the surviving feature(s) to `out`, or nothing if the feature is entirely outside
/// the face. Geometry is freshly allocated in `a`; `properties` are borrowed from `feat`.
/// `face` must be a simple even-odd ring-set (as `partition.ownedFace` emits). One
/// exception to face ownership: LIGHTS sector figures are kept whole (see isLightFigure).
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
            // A LIGHTS line is always a constructed sector figure (legs/arcs around
            // the light — LIGHTS itself is a point class): a fixed-size decoration
            // anchored at the light, not ground. Clipping it to the owned face
            // amputates the figure at the seam, so keep it WHOLE — it draws over
            // neighbouring ground exactly as a single-chart render would.
            if (isLightFigure(feat)) {
                const parts = try a.alloc([]const mvt.Point, feat.parts.len);
                for (feat.parts, 0..) |part, i| parts[i] = try a.dupe(mvt.Point, part);
                try out.append(a, .{ .geom_type = .linestring, .parts = parts, .properties = feat.properties });
                return;
            }
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

/// Project a cell's owned face — `partition.ownedFace` rings in integer lon/lat (degrees ×
/// 10⁷) — into tile `(z, tx, ty)` pixel space and clip to the tile box, returning the even-odd
/// ring set `clipFeatureToFace` expects (boolean.Pt, i64), freshly allocated in `a`. This is
/// the SAME projection the per-cell baker applied to that tile's features (`tile.project` +
/// `tile.clipPolygon` over `Box.default(EXTENT, BUFFER)` with the same round), so the face and
/// the decoded features live in one pixel space and the clip is seam-exact. Rings collapsing
/// below a triangle are dropped; an empty result means the cell owns no pixels in this tile.
pub fn projectFace(a: std.mem.Allocator, face: []const []const Pt, z: u8, tx: u32, ty: u32) ![]const []const Pt {
    var rings = std.ArrayList([]const Pt).empty;
    for (face) |ring| {
        const proj = try a.alloc(mvt.Point, ring.len);
        for (ring, 0..) |p, i| proj[i] = tile.project(
            @as(f64, @floatFromInt(p.x)) / 1e7,
            @as(f64, @floatFromInt(p.y)) / 1e7,
            z,
            tx,
            ty,
            tile.EXTENT,
        );
        const clipped = try tile.clipPolygon(a, proj, tile.Box.default(tile.EXTENT, tile.BUFFER));
        if (clipped.len < 3) continue;
        const widened = try a.alloc(Pt, clipped.len);
        for (clipped, 0..) |cp, i| widened[i] = .{ .x = cp.x, .y = cp.y };
        try rings.append(a, widened);
    }
    return rings.toOwnedSlice(a);
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

test "projectFace: a lon/lat face box inside the tile lands vertex-for-vertex at tile.project" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Web-mercator tile z2/(1,1) spans lon [-90,0], lat [0,66.51]. A face box in integer
    // lon/lat (degrees × 1e7) fully INSIDE it, so the box clip is a no-op and every projected
    // vertex must equal tile.project of the same lon/lat (projectFace adds no transform beyond
    // E7→deg + the shared clip). SW→SE→NE→NW ring order.
    const box = [_]Pt{
        .{ .x = -600_000_000, .y = 200_000_000 }, // lon -60, lat 20
        .{ .x = -300_000_000, .y = 200_000_000 }, // lon -30, lat 20
        .{ .x = -300_000_000, .y = 500_000_000 }, // lon -30, lat 50
        .{ .x = -600_000_000, .y = 500_000_000 }, // lon -60, lat 50
    };
    const rings = [_][]const Pt{&box};

    const z: u8 = 2;
    const tx: u32 = 1;
    const ty: u32 = 1;
    const face_px = try projectFace(a, &rings, z, tx, ty);
    try testing.expectEqual(@as(usize, 1), face_px.len);
    try testing.expectEqual(@as(usize, 4), face_px[0].len);

    for (box, 0..) |p, i| {
        const want = tile.project(
            @as(f64, @floatFromInt(p.x)) / 1e7,
            @as(f64, @floatFromInt(p.y)) / 1e7,
            z,
            tx,
            ty,
            tile.EXTENT,
        );
        try testing.expectEqual(@as(i64, want.x), face_px[0][i].x);
        try testing.expectEqual(@as(i64, want.y), face_px[0][i].y);
        // Inside the tile → inside the pixel box.
        try testing.expect(face_px[0][i].x >= 0 and face_px[0][i].x <= tile.EXTENT);
        try testing.expect(face_px[0][i].y >= 0 and face_px[0][i].y <= tile.EXTENT);
    }
    // Axis sanity: east lon → larger x; north lat (larger lat) → smaller y (y grows down).
    try testing.expect(face_px[0][1].x > face_px[0][0].x); // lon -30 east of -60
    try testing.expect(face_px[0][2].y < face_px[0][1].y); // lat 50 north of lat 20
}

test "projectFace: a ring fully outside the tile box is dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A face far to the east (lon ≈ +160) cannot touch tile z2/(1,1) (lon [-90,0]).
    const east = [_]Pt{
        .{ .x = 1_600_000_000, .y = 100_000_000 },
        .{ .x = 1_700_000_000, .y = 100_000_000 },
        .{ .x = 1_700_000_000, .y = 200_000_000 },
        .{ .x = 1_600_000_000, .y = 200_000_000 },
    };
    const rings = [_][]const Pt{&east};
    const face_px = try projectFace(a, &rings, 2, 1, 1);
    try testing.expectEqual(@as(usize, 0), face_px.len);
}
