//! Web-mercator projection + tile clipping.
//!
//! Projects lon/lat (degrees) to per-tile MVT coordinates (0..extent, y down)
//! and clips geometry to the tile box (extended by a buffer). Mirrors
//! internal/engine/tile in the Go reference. Coordinates leaving here feed
//! mvt.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mvt = @import("mvt.zig");

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

/// Inverse of `project`: tile-local coordinates (float pixels of tile z/tx/ty at
/// `extent`) back to lon/lat degrees. Used by the coverage line clip, which cuts
/// strokes in integer tile space and hands the kept runs back to the geo-space
/// complex-linestyle tessellator.
pub fn tileToLonLat(px: f64, py: f64, z: u8, tx: u32, ty: u32, extent: i32) [2]f64 {
    const scale = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    const ext: f64 = @floatFromInt(extent);
    const wx = (@as(f64, @floatFromInt(tx)) + px / ext) / scale;
    const wy = (@as(f64, @floatFromInt(ty)) + py / ext) / scale;
    const lon = wx * 360.0 - 180.0;
    const lat = std.math.atan(std.math.sinh(std.math.pi * (1.0 - 2.0 * wy))) * 180.0 / std.math.pi;
    return .{ lon, lat };
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

// Round to nearest, ties away from zero == Go math.Round (Quantize, tile.go:116).
// Truncate toward zero with the always-available CVTTSD2SI (@intFromFloat — the
// baseline musl target has no ROUNDSD, so @round/@trunc compile to a slow libm call
// that profiled at ~15% of the bake), then bump by the fractional part. This avoids
// the `v ± 0.5` edge where adding 0.5 to a value just below x.5 rounds UP to x+1 in
// double precision (half-even on the ADD), diverging from math.Round for that
// measure-zero case — all ALU ops, no software round.
inline fn roundI32(v: f64) i32 {
    const ti: i64 = @intFromFloat(v);
    const frac = v - @as(f64, @floatFromInt(ti));
    if (frac >= 0.5) return @intCast(ti + 1);
    if (frac <= -0.5) return @intCast(ti - 1);
    return @intCast(ti);
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

// ---- light sector-figure reach --------------------------------------------
// A LIGHTS feature's constructed sector legs/arcs are FIXED display-size
// figures around the light (plus ground-length directional legs), so they can
// cross into tiles the light's cell owns no ground in. Both the baker's tile
// addressing (bake_enc buildTileMap) and the runtime compositor's reach ring
// (compose.tile) widen by the same bound so the figures survive there.

const EARTH_CIRCUM_M: f64 = 40075016.686;

/// Worst-case reach of a light's display-mm sector figures as a fraction of a
/// tile — ~constant at every zoom (offset_tiles = mm * PX_PER_MM / 512, the
/// 512-CSS-px tile the figures are sized against; S-52 legs ~25 mm / arcs
/// ~20 mm ≈ 0.2 tile; 1.0 is generous headroom).
pub const LIGHT_AUG_REACH_TILES: f64 = 1.0;

/// Worst-case tile-unit reach of sector figures at zoom z, latitude `lat`:
/// display-mm figures reach a ~constant LIGHT_AUG_REACH_TILES, ground-length
/// legs (directional lights) reach range_m metres = range_m·2^z/(cosφ·C) tiles.
/// Never below the mm bound — a cell with figures always reaches at least the
/// display-sized ones.
pub fn lightReachTiles(range_m: f64, z: u8, lat: f64) f64 {
    if (range_m <= 0) return LIGHT_AUG_REACH_TILES;
    const cos_lat = @max(@cos(lat * std.math.pi / 180.0), 1e-6);
    const scale: f64 = @floatFromInt(@as(u64, 1) << @intCast(z));
    return @max(LIGHT_AUG_REACH_TILES, range_m * scale / (cos_lat * EARTH_CIRCUM_M));
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
    // Sutherland-Hodgman emits at most two vertices per input vertex (a crossing
    // intersection plus the vertex itself), so reserve the worst case once and
    // append without a per-vertex capacity check — append was ~13% of the bake.
    try out.ensureTotalCapacity(a, ring.len * 2);
    var prev = ring[ring.len - 1];
    for (ring) |cur| {
        const cur_in = inside(cur, edge, b);
        const prev_in = inside(prev, edge, b);
        if (cur_in) {
            if (!prev_in) out.appendAssumeCapacity(intersect(prev, cur, edge, b));
            out.appendAssumeCapacity(cur);
        } else if (prev_in) {
            out.appendAssumeCapacity(intersect(prev, cur, edge, b));
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
                try cur.append(a, s.a);
                try cur.append(a, s.b);
            } else if (eqPt(cur.items[cur.items.len - 1], s.a)) {
                try cur.append(a, s.b);
            } else {
                try parts.append(a, cur.items);
                cur = std.ArrayList(mvt.Point).empty;
                try cur.append(a, s.a);
                try cur.append(a, s.b);
            }
            // A segment clipped at its far end leaves the box here; close the run so a
            // poke-out/re-entry near the same boundary point isn't bridged into one run
            // (matches Go tile.ClipLine seg.exited and our own clipLinePhased).
            if (s.exited) {
                try parts.append(a, cur.items);
                cur = std.ArrayList(mvt.Point).empty;
            }
        } else if (cur.items.len > 0) {
            try parts.append(a, cur.items);
            cur = std.ArrayList(mvt.Point).empty;
        }
    }
    if (cur.items.len > 0) try parts.append(a, cur.items);
    return parts.items;
}

/// Clip a projected line to a tile box and simplify each surviving run (dropping
/// runs shorter than 2 points). The common "clip a line for this tile" composite.
pub fn clipSimplifyLine(a: Allocator, proj: []const mvt.Point, box: Box) ![]const []const mvt.Point {
    const sub = try clipLine(a, proj, box);
    var out = std.ArrayList([]const mvt.Point).empty;
    for (sub) |run| {
        const s = try simplifyRing(a, run);
        if (s.len >= 2) try out.append(a, s);
    }
    return out.items;
}

fn eqPt(a: mvt.Point, b: mvt.Point) bool {
    return a.x == b.x and a.y == b.y;
}

const ClippedSeg = struct { a: mvt.Point, b: mvt.Point, exited: bool };

fn clipSegment(p0: mvt.Point, p1: mvt.Point, b: Box) ?ClippedSeg {
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
        .a = .{ .x = roundI32(nx0), .y = roundI32(ny0) },
        .b = .{ .x = roundI32(nx1), .y = roundI32(ny1) },
        .exited = t1 < 1.0, // far end was clipped -> the polyline leaves the box here
    };
}

// ---- phase-stable line clip (float; for along-line symbology) -------------
//
// Complex (symbolised) linestyles are tessellated per zoom by walking the line
// by arc length. To keep a dash/symbol pattern continuous across a tile boundary
// the clip must report, per in-box run, the cumulative arc length at the run's
// first vertex (arc0). This is the float counterpart of clipLine; emitComplexLine
// quantises the float results to mvt.Point at emit. Mirrors Go tile.ClipLinePhased.

/// A float tile-space point (unrounded), for the arc-length / phased-clip path.
pub const FPoint = struct { x: f64, y: f64 };

/// Quantise a float tile point to an integer mvt.Point (same rounding as project).
pub fn quantizeF(p: FPoint) mvt.Point {
    return .{ .x = roundI32(p.x), .y = roundI32(p.y) };
}

/// Project a normalised web-mercator world coord to UNROUNDED tile-local float
/// coordinates (the float counterpart of worldToTile).
pub fn worldToTileF(w: [2]f64, z: u8, tx: u32, ty: u32, extent: i32) FPoint {
    const scale = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    const ext: f64 = @floatFromInt(extent);
    return .{
        .x = (w[0] * scale - @as(f64, @floatFromInt(tx))) * ext,
        .y = (w[1] * scale - @as(f64, @floatFromInt(ty))) * ext,
    };
}

const ClippedSegF = struct { a: FPoint, b: FPoint, t0: f64, exited: bool };

fn clipSegmentF(a: FPoint, c: FPoint, b: Box) ?ClippedSegF {
    const dx = c.x - a.x;
    const dy = c.y - a.y;
    var t0: f64 = 0;
    var t1: f64 = 1;
    const lo: f64 = @floatFromInt(b.min);
    const hi: f64 = @floatFromInt(b.max);
    const p = [4]f64{ -dx, dx, -dy, dy };
    const q = [4]f64{ a.x - lo, hi - a.x, a.y - lo, hi - a.y };
    for (p, q) |pi, qi| {
        if (pi == 0) {
            if (qi < 0) return null; // parallel & outside
            continue;
        }
        const t = qi / pi;
        if (pi < 0) {
            if (t > t1) return null;
            if (t > t0) t0 = t;
        } else {
            if (t < t0) return null;
            if (t < t1) t1 = t;
        }
    }
    return .{
        .a = .{ .x = a.x + t0 * dx, .y = a.y + t0 * dy },
        .b = .{ .x = a.x + t1 * dx, .y = a.y + t1 * dy },
        .t0 = t0,
        .exited = t1 < 1.0,
    };
}

fn approxEqF(a: FPoint, b: FPoint) bool {
    return @abs(a.x - b.x) < 1e-6 and @abs(a.y - b.y) < 1e-6;
}

/// One clipped polyline run plus the cumulative arc length at its first vertex.
pub const PhasedRun = struct { points: []FPoint, arc0: f64 };

/// Clip a polyline to the tile box, returning the in-box runs; each run carries
/// arc0 = the arc length from the polyline's first vertex to the run's first vertex
/// (so a dash/symbol period lines up across tile boundaries). `arc[i]` is the
/// cumulative arc length at `pts[i]` and must be the same length as `pts`.
pub fn clipLinePhased(alloc: Allocator, pts: []const FPoint, arc: []const f64, b: Box) ![]PhasedRun {
    var runs = std.ArrayList(PhasedRun).empty;
    if (pts.len < 2) return runs.items;
    var cur = std.ArrayList(FPoint).empty;
    var cur_arc0: f64 = 0;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const da = arc[i + 1] - arc[i];
        const seg = clipSegmentF(pts[i], pts[i + 1], b) orelse {
            if (cur.items.len > 0) {
                try runs.append(alloc, .{ .points = cur.items, .arc0 = cur_arc0 });
                cur = std.ArrayList(FPoint).empty;
            }
            continue;
        };
        const arc_a = arc[i] + seg.t0 * da;
        if (cur.items.len == 0) {
            cur_arc0 = arc_a;
            try cur.append(alloc, seg.a);
            try cur.append(alloc, seg.b);
        } else if (approxEqF(cur.items[cur.items.len - 1], seg.a)) {
            try cur.append(alloc, seg.b);
        } else {
            try runs.append(alloc, .{ .points = cur.items, .arc0 = cur_arc0 });
            cur = std.ArrayList(FPoint).empty;
            cur_arc0 = arc_a;
            try cur.append(alloc, seg.a);
            try cur.append(alloc, seg.b);
        }
        if (seg.exited) {
            try runs.append(alloc, .{ .points = cur.items, .arc0 = cur_arc0 });
            cur = std.ArrayList(FPoint).empty;
        }
    }
    if (cur.items.len > 0) try runs.append(alloc, .{ .points = cur.items, .arc0 = cur_arc0 });
    return runs.items;
}

test "roundI32 matches Go math.Round (ties away from zero, no v+0.5 FP edge)" {
    const t = std.testing;
    // Standard ties away from zero.
    try t.expectEqual(@as(i32, 1), roundI32(0.5));
    try t.expectEqual(@as(i32, -1), roundI32(-0.5));
    try t.expectEqual(@as(i32, 3), roundI32(2.5));
    try t.expectEqual(@as(i32, -3), roundI32(-2.5));
    try t.expectEqual(@as(i32, 2), roundI32(2.4));
    try t.expectEqual(@as(i32, 0), roundI32(0.0));
    try t.expectEqual(@as(i32, 7), roundI32(6.6));
    // The FP edge: the largest double below 0.5 must round to 0 (math.Round does), NOT
    // to 1 as the old `v + 0.5` trick would (0.499…94 + 0.5 ties to 1.0 in double).
    const just_below_half = std.math.nextAfter(f64, 0.5, 0.0);
    try t.expectEqual(@as(i32, 0), roundI32(just_below_half));
    try t.expectEqual(@as(i32, 0), roundI32(-just_below_half));
    // The largest double below 2.5 rounds to 2 (nearest), not 3.
    try t.expectEqual(@as(i32, 2), roundI32(std.math.nextAfter(f64, 2.5, 2.0)));
}

test "clipLinePhased keeps arc phase across the box boundary" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const box = Box{ .min = 0, .max = 100 };

    // A horizontal line from x=-50 to x=250 at y=50: enters the box at x=0 (arc 50
    // from the start) and exits at x=100. One run, arc0 = 50.
    const pts = [_]FPoint{ .{ .x = -50, .y = 50 }, .{ .x = 250, .y = 50 } };
    const arc = [_]f64{ 0, 300 };
    const runs = try clipLinePhased(a, &pts, &arc, box);
    try t.expectEqual(@as(usize, 1), runs.len);
    try t.expectApproxEqAbs(@as(f64, 50), runs[0].arc0, 1e-9);
    try t.expectEqual(@as(usize, 2), runs[0].points.len);
    try t.expectApproxEqAbs(@as(f64, 0), runs[0].points[0].x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 100), runs[0].points[1].x, 1e-9);

    // A line that exits the box and re-enters yields two runs, each with its own
    // arc0: across the top (y=-50, fully outside) then back in.
    const pts2 = [_]FPoint{
        .{ .x = 10, .y = 50 }, .{ .x = 10, .y = -50 }, // up and out
        .{ .x = 90, .y = -50 }, .{ .x = 90, .y = 50 }, // across (out) and back in
    };
    // arc: 0,100,180,280
    const arc2 = [_]f64{ 0, 100, 180, 280 };
    const runs2 = try clipLinePhased(a, &pts2, &arc2, box);
    try t.expectEqual(@as(usize, 2), runs2.len);
    try t.expectApproxEqAbs(@as(f64, 0), runs2[0].arc0, 1e-9); // first run starts at the line's start
    try t.expect(runs2[1].arc0 > 180); // second run re-enters partway along the last segment
}

// ---- per-tile simplification (Go bake.go quantizeRing/douglasPeucker) ----
//
// A dense S-57 coastline can carry 100k+ vertices into one tile and blow MapLibre's
// 65535-vertex-per-fill-segment cap, so the whole polygon silently fails to render.
// Mirror the Go baker: Douglas-Peucker (½-px tolerance) then drop exact consecutive
// duplicates + collinear midpoints. Points are already on the integer MVT grid here
// (worldToTile rounds), so the math is exact integer (no separate quantize step).

// (4.0)^2 in MVT extent units — Go's simplifyTolerance=4.0 (~½ px at extent 4096).
const SIMPLIFY_EPS2: i128 = 16;

/// Drop exact consecutive duplicates and collinear midpoints (lossless at integer
/// resolution) — Go's quantizePts. Use directly as the no-DP fallback (quantizeRingExact).
pub fn dedupCollinear(a: Allocator, pts: []const mvt.Point) ![]mvt.Point {
    var out = std.ArrayList(mvt.Point).empty;
    for (pts) |q| {
        const n = out.items.len;
        if (n > 0 and out.items[n - 1].x == q.x and out.items[n - 1].y == q.y) continue;
        if (n >= 2) {
            const aa = out.items[n - 2];
            const bb = out.items[n - 1];
            const cross = @as(i64, bb.x - aa.x) * @as(i64, q.y - aa.y) - @as(i64, bb.y - aa.y) * @as(i64, q.x - aa.x);
            if (cross == 0) { // b is collinear with a->q: replace the midpoint
                out.items[n - 1] = q;
                continue;
            }
        }
        try out.append(a, q);
    }
    return out.items;
}

/// Douglas-Peucker on integer tile coords (perp dist^2 vs SIMPLIFY_EPS2), keeping
/// the first/last vertex. Iterative (explicit stack). Returns kept points.
fn douglasPeucker(a: Allocator, pts: []const mvt.Point) ![]mvt.Point {
    const n = pts.len;
    if (n < 3) return a.dupe(mvt.Point, pts);
    const keep = try a.alloc(bool, n);
    @memset(keep, false);
    keep[0] = true;
    keep[n - 1] = true;
    var stack = std.ArrayList([2]usize).empty;
    defer stack.deinit(a);
    try stack.append(a, .{ 0, n - 1 });
    while (stack.pop()) |seg| {
        const s = seg[0];
        const e = seg[1];
        if (e <= s + 1) continue;
        const ax: i64 = pts[s].x;
        const ay: i64 = pts[s].y;
        const dx: i64 = @as(i64, pts[e].x) - ax;
        const dy: i64 = @as(i64, pts[e].y) - ay;
        const den: i128 = @as(i128, dx) * dx + @as(i128, dy) * dy; // segment length^2
        var best: i128 = -1;
        var besti: usize = s;
        var i = s + 1;
        while (i < e) : (i += 1) {
            const ex: i64 = @as(i64, pts[i].x) - ax;
            const ey: i64 = @as(i64, pts[i].y) - ay;
            // den constant within this segment, so argmax(perp dist) = argmax(num^2)
            // for den>0, or argmax(ex^2+ey^2) for a degenerate segment.
            const metric: i128 = if (den == 0)
                @as(i128, ex) * ex + @as(i128, ey) * ey
            else blk: {
                const num: i128 = @as(i128, ex) * dy - @as(i128, ey) * dx;
                break :blk num * num;
            };
            if (metric > best) {
                best = metric;
                besti = i;
            }
        }
        const exceeds = if (den == 0) best > SIMPLIFY_EPS2 else best > SIMPLIFY_EPS2 * den;
        if (exceeds) {
            keep[besti] = true;
            try stack.append(a, .{ s, besti });
            try stack.append(a, .{ besti, e });
        }
    }
    var out = std.ArrayList(mvt.Point).empty;
    for (pts, 0..) |p, k| if (keep[k]) try out.append(a, p);
    return out.items;
}

/// Simplify a clipped ring/line (Go quantizeRing): Douglas-Peucker then collinear/
/// duplicate removal. Caller falls back to dedupCollinear (quantizeRingExact) when
/// this collapses a ring below its minimum vertex count.
pub fn simplifyRing(a: Allocator, pts: []const mvt.Point) ![]mvt.Point {
    return dedupCollinear(a, try douglasPeucker(a, pts));
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

test "line clip exit-split: retrace out and back yields two runs (Go ClipLine parity)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Box.default(EXTENT, BUFFER);

    // In -> out -> back in along the SAME line: the exit and re-entry hit the box at
    // the identical boundary point, so without the exit-split the run would merge into
    // one [in, boundary, in] polyline. Go tile.ClipLine (and our clipLinePhased)
    // finalize the run on exit -> two runs. The clipped span is [in, boundary] both ways.
    const line = [_]mvt.Point{
        .{ .x = 100, .y = 2048 },
        .{ .x = 9000, .y = 2048 }, // out the right edge
        .{ .x = 100, .y = 2048 }, // retrace back in along the same line
    };
    const parts = try clipLine(a, &line, b);
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqual(@as(usize, 2), parts[0].len);
    try std.testing.expectEqual(@as(usize, 2), parts[1].len);
    for (parts) |part| for (part) |p| {
        try std.testing.expect(p.x >= b.min and p.x <= b.max);
    };
}
