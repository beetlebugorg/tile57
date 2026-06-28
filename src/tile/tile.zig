//! Web-mercator projection + tile clipping.
//!
//! Projects lon/lat (degrees) to per-tile MVT coordinates (0..extent, y down)
//! and clips geometry to the tile box (extended by a buffer). Mirrors
//! internal/engine/tile in the Go reference. Coordinates leaving here feed
//! mvt.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mvt = @import("mvt");

pub const EXTENT: i32 = 4096;
pub const BUFFER: i32 = 64;

/// Normalised web-mercator: lon/lat (deg) -> (x,y) in [0,1], y down.
pub fn lonLatToWorld(lon: f64, lat: f64) [2]f64 {
    const wx = (lon + 180.0) / 360.0;
    const clamped = std.math.clamp(lat, -85.05112878, 85.05112878);
    const rad = clamped * std.math.pi / 180.0;
    const wy = (1.0 - std.math.log(f64, std.math.e, std.math.tan(rad) + 1.0 / std.math.cos(rad)) / std.math.pi) / 2.0;
    return .{ wx, wy };
}

/// Project lon/lat to tile-local MVT coordinates for tile (z,x,y) at `extent`.
/// Values are not clipped; they may fall outside [0,extent].
pub fn project(lon: f64, lat: f64, z: u8, tx: u32, ty: u32, extent: i32) mvt.Point {
    return worldToTile(lonLatToWorld(lon, lat), z, tx, ty, extent);
}

/// Project a normalised web-mercator world coord (`lonLatToWorld` output, [0,1])
/// to tile-local MVT coordinates — the cheap part of `project` (no transcendentals),
/// so a baker can compute world once per point and reproject it across tiles fast.
pub fn worldToTile(w: [2]f64, z: u8, tx: u32, ty: u32, extent: i32) mvt.Point {
    const scale = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    const ext: f64 = @floatFromInt(extent);
    const px = (w[0] * scale - @as(f64, @floatFromInt(tx))) * ext;
    const py = (w[1] * scale - @as(f64, @floatFromInt(ty))) * ext;
    return .{ .x = roundI32(px), .y = roundI32(py) };
}

// Round to nearest (ties away from zero, == @round) via hardware truncation
// (@intFromFloat is CVTTSD2SI) — the baseline musl target has no ROUNDSD, so
// @round compiled to a software routine that profiled at ~15% of the bake.
inline fn roundI32(v: f64) i32 {
    return @intFromFloat(if (v >= 0) v + 0.5 else v - 0.5);
}

/// Geographic bounds of tile (z,x,y): [min_lon, min_lat, max_lon, max_lat].
pub fn tileBoundsLonLat(z: u8, tx: u32, ty: u32) [4]f64 {
    const n = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    const fx: f64 = @floatFromInt(tx);
    const fy: f64 = @floatFromInt(ty);
    const lon0 = fx / n * 360.0 - 180.0;
    const lon1 = (fx + 1.0) / n * 360.0 - 180.0;
    const lat = struct {
        fn at(yy: f64, nn: f64) f64 {
            const m = std.math.pi * (1.0 - 2.0 * yy / nn);
            return std.math.atan(std.math.sinh(m)) * 180.0 / std.math.pi;
        }
    };
    const lat0 = lat.at(fy + 1.0, n); // bottom (min lat)
    const lat1 = lat.at(fy, n); // top (max lat)
    return .{ lon0, lat0, lon1, lat1 };
}

/// Inclusive tile box used for clipping (extent +/- buffer).
pub const Box = struct {
    min: i32,
    max: i32,
    pub fn default(extent: i32, buffer: i32) Box {
        return .{ .min = -buffer, .max = extent + buffer };
    }
};

// ---- polygon clip (Sutherland-Hodgman) ----------------------------------

const Edge = enum { left, right, top, bottom };

fn inside(p: mvt.Point, edge: Edge, b: Box) bool {
    return switch (edge) {
        .left => p.x >= b.min,
        .right => p.x <= b.max,
        .top => p.y >= b.min,
        .bottom => p.y <= b.max,
    };
}

fn intersect(a: mvt.Point, c: mvt.Point, edge: Edge, b: Box) mvt.Point {
    const ax: f64 = @floatFromInt(a.x);
    const ay: f64 = @floatFromInt(a.y);
    const cx: f64 = @floatFromInt(c.x);
    const cy: f64 = @floatFromInt(c.y);
    // The clip boundary is an exact integer; use it directly (no round needed) and
    // hardware-round only the interpolated coordinate (see roundI32 — @round
    // compiled to a software routine on the baseline musl target).
    const bi: i32 = switch (edge) {
        .left, .top => b.min,
        .right, .bottom => b.max,
    };
    const bound: f64 = @floatFromInt(bi);
    return switch (edge) {
        .left, .right => blk: {
            const t = (bound - ax) / (cx - ax);
            break :blk .{ .x = bi, .y = roundI32(ay + t * (cy - ay)) };
        },
        .top, .bottom => blk: {
            const t = (bound - ay) / (cy - ay);
            break :blk .{ .x = roundI32(ax + t * (cx - ax)), .y = bi };
        },
    };
}

fn clipEdge(a: Allocator, ring: []const mvt.Point, edge: Edge, b: Box, out: *std.ArrayList(mvt.Point)) !void {
    out.clearRetainingCapacity();
    if (ring.len == 0) return;
    var prev = ring[ring.len - 1];
    for (ring) |cur| {
        const cur_in = inside(cur, edge, b);
        const prev_in = inside(prev, edge, b);
        if (cur_in) {
            if (!prev_in) try out.append(a, intersect(prev, cur, edge, b));
            try out.append(a, cur);
        } else if (prev_in) {
            try out.append(a, intersect(prev, cur, edge, b));
        }
        prev = cur;
    }
}

/// Clip a polygon ring to the tile box. Returns the clipped ring (may be empty).
/// Caller owns the result (allocate via an arena).
pub fn clipPolygon(a: Allocator, ring: []const mvt.Point, b: Box) ![]mvt.Point {
    var buf_a = std.ArrayList(mvt.Point).empty;
    var buf_b = std.ArrayList(mvt.Point).empty;
    // Clip the first edge straight from the caller's ring (no copy into a working
    // buffer first), then ping-pong the remaining three edges between buf_a/buf_b.
    try clipEdge(a, ring, .left, b, &buf_a);
    var src = &buf_a;
    var dst = &buf_b;
    for ([_]Edge{ .right, .top, .bottom }) |edge| {
        try clipEdge(a, src.items, edge, b, dst);
        const tmp = src;
        src = dst;
        dst = tmp;
    }
    return src.items;
}

// ---- line clip (Liang-Barsky, per segment) ------------------------------

/// Clip a polyline to the tile box, producing zero or more sub-lines.
/// Caller owns the result (allocate via an arena).
pub fn clipLine(a: Allocator, line: []const mvt.Point, b: Box) ![][]mvt.Point {
    var parts = std.ArrayList([]mvt.Point).empty;
    if (line.len < 2) return parts.items;
    var cur = std.ArrayList(mvt.Point).empty;
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        const seg = clipSegment(line[i], line[i + 1], b);
        if (seg) |s| {
            if (cur.items.len == 0) {
                try cur.append(a, s[0]);
                try cur.append(a, s[1]);
            } else if (eqPt(cur.items[cur.items.len - 1], s[0])) {
                try cur.append(a, s[1]);
            } else {
                try parts.append(a, cur.items);
                cur = std.ArrayList(mvt.Point).empty;
                try cur.append(a, s[0]);
                try cur.append(a, s[1]);
            }
        } else if (cur.items.len > 0) {
            try parts.append(a, cur.items);
            cur = std.ArrayList(mvt.Point).empty;
        }
    }
    if (cur.items.len > 0) try parts.append(a, cur.items);
    return parts.items;
}

fn eqPt(a: mvt.Point, b: mvt.Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn clipSegment(p0: mvt.Point, p1: mvt.Point, b: Box) ?[2]mvt.Point {
    var t0: f64 = 0;
    var t1: f64 = 1;
    const dx: f64 = @floatFromInt(p1.x - p0.x);
    const dy: f64 = @floatFromInt(p1.y - p0.y);
    const x0: f64 = @floatFromInt(p0.x);
    const y0: f64 = @floatFromInt(p0.y);
    const lo: f64 = @floatFromInt(b.min);
    const hi: f64 = @floatFromInt(b.max);

    const checks = [_][2]f64{
        .{ -dx, x0 - lo }, // left:   x >= lo
        .{ dx, hi - x0 }, // right:  x <= hi
        .{ -dy, y0 - lo }, // top:    y >= lo
        .{ dy, hi - y0 }, // bottom: y <= hi
    };
    for (checks) |c| {
        const p = c[0];
        const q = c[1];
        if (p == 0) {
            if (q < 0) return null; // parallel & outside
        } else {
            const r = q / p;
            if (p < 0) {
                if (r > t1) return null;
                if (r > t0) t0 = r;
            } else {
                if (r < t0) return null;
                if (r < t1) t1 = r;
            }
        }
    }
    const nx0 = x0 + t0 * dx;
    const ny0 = y0 + t0 * dy;
    const nx1 = x0 + t1 * dx;
    const ny1 = y0 + t1 * dy;
    return .{
        .{ .x = roundI32(nx0), .y = roundI32(ny0) },
        .{ .x = roundI32(nx1), .y = roundI32(ny1) },
    };
}

// ---- tests --------------------------------------------------------------

test "project Annapolis lands in the expected z14 tile" {
    // Annapolis harbour; the reference tile we use elsewhere is z14/4711/6262.
    const z: u8 = 14;
    const w = lonLatToWorld(-76.482, 38.978);
    const scale: f64 = @floatFromInt(@as(u64, 1) << z);
    const tx: u32 = @intFromFloat(@floor(w[0] * scale));
    const ty: u32 = @intFromFloat(@floor(w[1] * scale));
    try std.testing.expectEqual(@as(u32, 4711), tx);
    try std.testing.expectEqual(@as(u32, 6262), ty);

    // Local coords land inside the tile.
    const p = project(-76.482, 38.978, z, tx, ty, EXTENT);
    try std.testing.expect(p.x >= 0 and p.x <= EXTENT);
    try std.testing.expect(p.y >= 0 and p.y <= EXTENT);
}

test "polygon clip keeps an inside square and clips an overhang" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Box.default(EXTENT, BUFFER);

    // Fully inside -> unchanged vertex count.
    const inside_sq = [_]mvt.Point{
        .{ .x = 100, .y = 100 }, .{ .x = 200, .y = 100 },
        .{ .x = 200, .y = 200 }, .{ .x = 100, .y = 200 },
    };
    const r1 = try clipPolygon(a, &inside_sq, b);
    try std.testing.expectEqual(@as(usize, 4), r1.len);

    // Spanning the right edge -> clipped to <= max+? all x within box.
    const overhang = [_]mvt.Point{
        .{ .x = 4000, .y = 100 }, .{ .x = 5000, .y = 100 },
        .{ .x = 5000, .y = 200 }, .{ .x = 4000, .y = 200 },
    };
    const r2 = try clipPolygon(a, &overhang, b);
    try std.testing.expect(r2.len >= 4);
    for (r2) |p| try std.testing.expect(p.x <= b.max);
}

test "line clip splits a line that exits and re-enters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Box.default(EXTENT, BUFFER);

    // In -> out -> in: should yield two sub-lines.
    const line = [_]mvt.Point{
        .{ .x = 100, .y = 100 },
        .{ .x = 9000, .y = 100 }, // way outside (right)
        .{ .x = 200, .y = 200 },
    };
    const parts = try clipLine(a, &line, b);
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    for (parts) |part| for (part) |p| {
        try std.testing.expect(p.x >= b.min and p.x <= b.max);
    };
}
