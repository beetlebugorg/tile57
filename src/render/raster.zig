//! RasterCanvas: a scanline anti-aliased software rasterizer over an RGBA8
//! buffer, implementing the Canvas primitive seam. Nonzero-winding polygon
//! fill with 4x vertical subsampling + fractional horizontal coverage
//! (nanosvgrast is the prior art); strokes flatten to polygons (a quad per
//! segment + a disc per vertex = round joins AND round caps) and go through
//! the same fill, so one code path owns all coverage math.
//!
//! Pure std — no libc; testable everywhere.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cv = @import("canvas.zig");

const SUBSAMPLES = 4;
const SUB_WEIGHT: f32 = 1.0 / @as(f32, SUBSAMPLES);

// One polygon edge, normalized so y0 < y1; `dir` keeps the original
// orientation (+1 downward, -1 upward) for the winding count. Horizontal
// edges contribute nothing to scanline crossings and are dropped at build.
const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, dir: i32 };

const Crossing = struct { x: f32, dir: i32 };

pub const RasterCanvas = struct {
    a: Allocator,
    w: u32,
    h: u32,
    /// Straight-alpha RGBA8, row-major, y down. init() leaves it transparent
    /// black; clear() floods an opaque background (NODTA for chart scenes).
    px: []u8,

    // Per-draw scratch, reused across calls.
    edges: std.ArrayList(Edge) = .empty,
    active: std.ArrayList(Edge) = .empty,
    crossings: std.ArrayList(Crossing) = .empty,
    cov: []f32,

    const vtable = cv.Canvas.VTable{
        .fillPath = fillPathImpl,
        .strokePath = strokePathImpl,
    };

    pub fn init(a: Allocator, w: u32, h: u32) !RasterCanvas {
        const px = try a.alloc(u8, @as(usize, w) * h * 4);
        errdefer a.free(px);
        @memset(px, 0);
        const cov = try a.alloc(f32, w);
        return .{ .a = a, .w = w, .h = h, .px = px, .cov = cov };
    }

    pub fn deinit(self: *RasterCanvas) void {
        self.a.free(self.px);
        self.a.free(self.cov);
        self.edges.deinit(self.a);
        self.active.deinit(self.a);
        self.crossings.deinit(self.a);
    }

    pub fn asCanvas(self: *RasterCanvas) cv.Canvas {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Flood the whole buffer with an opaque color (the scene background).
    pub fn clear(self: *RasterCanvas, color: cv.Color) void {
        var i: usize = 0;
        while (i < self.px.len) : (i += 4) {
            self.px[i] = color.r;
            self.px[i + 1] = color.g;
            self.px[i + 2] = color.b;
            self.px[i + 3] = 255;
        }
    }

    fn sp(ctx: *anyopaque) *RasterCanvas {
        return @ptrCast(@alignCast(ctx));
    }

    // ---- Canvas impl --------------------------------------------------------

    fn fillPathImpl(ctx: *anyopaque, rings: []const []const cv.Point, color: cv.Color) anyerror!void {
        const self = sp(ctx);
        self.edges.clearRetainingCapacity();
        for (rings) |ring| try self.addRing(ring);
        try self.rasterize(color);
    }

    fn strokePathImpl(ctx: *anyopaque, lines: []const []const cv.Point, width_px: f32, dash: ?[2]f32, color: cv.Color) anyerror!void {
        const self = sp(ctx);
        if (!(width_px > 0)) return;
        self.edges.clearRetainingCapacity();
        for (lines) |line| {
            if (dash) |d| {
                try self.strokeDashed(line, width_px, d);
            } else {
                try self.strokeRun(line, width_px);
            }
        }
        try self.rasterize(color);
    }

    // ---- edge building ------------------------------------------------------

    fn addEdge(self: *RasterCanvas, p: cv.Point, q: cv.Point) !void {
        if (p.y == q.y) return; // horizontal: no crossings
        if (p.y < q.y) {
            try self.edges.append(self.a, .{ .x0 = p.x, .y0 = p.y, .x1 = q.x, .y1 = q.y, .dir = 1 });
        } else {
            try self.edges.append(self.a, .{ .x0 = q.x, .y0 = q.y, .x1 = p.x, .y1 = p.y, .dir = -1 });
        }
    }

    // A closed ring (last->first edge added implicitly if not explicit).
    fn addRing(self: *RasterCanvas, ring: []const cv.Point) !void {
        if (ring.len < 3) return;
        var i: usize = 0;
        while (i + 1 < ring.len) : (i += 1) try self.addEdge(ring[i], ring[i + 1]);
        const first = ring[0];
        const last = ring[ring.len - 1];
        if (first.x != last.x or first.y != last.y) try self.addEdge(last, first);
    }

    // ---- stroke flattening ----------------------------------------------------

    // One solid run: a quad per segment + a disc per vertex (round joins/caps).
    // Both are emitted CLOCKWISE (negative shoelace, y down) so overlapping
    // pieces reinforce under nonzero winding instead of cancelling.
    fn strokeRun(self: *RasterCanvas, line: []const cv.Point, width_px: f32) !void {
        if (line.len == 0) return;
        const r = width_px / 2;
        var any = false;
        for (0..line.len - 1) |i| {
            const p = line[i];
            const q = line[i + 1];
            const dx = q.x - p.x;
            const dy = q.y - p.y;
            const len = @sqrt(dx * dx + dy * dy);
            if (len < 1e-6) continue;
            any = true;
            // Unit normal r-scaled; ring p+n, q+n, q-n, p-n is CW for any
            // segment direction (n is d rotated by a fixed 90°).
            const nx = -dy / len * r;
            const ny = dx / len * r;
            try self.addEdge(.{ .x = p.x + nx, .y = p.y + ny }, .{ .x = q.x + nx, .y = q.y + ny });
            try self.addEdge(.{ .x = q.x + nx, .y = q.y + ny }, .{ .x = q.x - nx, .y = q.y - ny });
            try self.addEdge(.{ .x = q.x - nx, .y = q.y - ny }, .{ .x = p.x - nx, .y = p.y - ny });
            try self.addEdge(.{ .x = p.x - nx, .y = p.y - ny }, .{ .x = p.x + nx, .y = p.y + ny });
        }
        if (!any) return;
        for (line) |v| try self.addDisc(v, r);
    }

    // Clockwise (y-down) disc approximation; segment count scales with radius
    // (deterministic formula) so joins stay round at chart line widths.
    fn addDisc(self: *RasterCanvas, c: cv.Point, r: f32) !void {
        const n: usize = @intFromFloat(@max(8, @min(64, @ceil(r * 4))));
        var prev = cv.Point{ .x = c.x + r, .y = c.y };
        for (1..n + 1) |i| {
            const t = -2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const pt = cv.Point{ .x = c.x + r * @cos(t), .y = c.y + r * @sin(t) };
            try self.addEdge(prev, pt);
            prev = pt;
        }
    }

    // Cut a polyline into on-runs of the [on, off] dash pattern (anchored at
    // the line start, starting ON) and stroke each run.
    fn strokeDashed(self: *RasterCanvas, line: []const cv.Point, width_px: f32, dash: [2]f32) !void {
        const on = dash[0];
        const off = dash[1];
        if (!(on > 0) or !(off > 0)) return self.strokeRun(line, width_px);
        var run = std.ArrayList(cv.Point).empty;
        defer run.deinit(self.a);
        var drawing = true;
        var remain = on; // distance left in the current on/off phase
        if (line.len > 0) try run.append(self.a, line[0]);
        for (0..line.len -| 1) |i| {
            var p = line[i];
            const q = line[i + 1];
            var seg = std.math.hypot(q.x - p.x, q.y - p.y);
            while (seg >= remain and seg > 1e-6) {
                const t = remain / seg;
                const m = cv.Point{ .x = p.x + (q.x - p.x) * t, .y = p.y + (q.y - p.y) * t };
                if (drawing) {
                    try run.append(self.a, m);
                    try self.strokeRun(run.items, width_px);
                    run.clearRetainingCapacity();
                } else {
                    try run.append(self.a, m);
                }
                drawing = !drawing;
                if (!drawing) run.clearRetainingCapacity();
                p = m;
                seg -= remain;
                remain = if (drawing) on else off;
            }
            remain -= seg;
            if (drawing) try run.append(self.a, q);
        }
        if (drawing and run.items.len >= 2) try self.strokeRun(run.items, width_px);
    }

    // ---- scanline rasterization ----------------------------------------------

    fn rasterize(self: *RasterCanvas, color: cv.Color) !void {
        if (self.edges.items.len == 0 or color.a == 0) return;
        const wf: f32 = @floatFromInt(self.w);
        const hf: f32 = @floatFromInt(self.h);

        // Cull + find the y range touched.
        var ymin: f32 = hf;
        var ymax: f32 = 0;
        for (self.edges.items) |e| {
            ymin = @min(ymin, e.y0);
            ymax = @max(ymax, e.y1);
        }
        if (ymax <= 0 or ymin >= hf) return;
        const y_start: u32 = @intFromFloat(@max(0, @floor(ymin)));
        const y_end: u32 = @intFromFloat(@min(hf, @ceil(ymax)));

        // Active-edge sweep: edges sorted by top; add as the scanline reaches
        // them, drop when passed.
        std.mem.sort(Edge, self.edges.items, {}, struct {
            fn lt(_: void, l: Edge, r: Edge) bool {
                return l.y0 < r.y0;
            }
        }.lt);
        self.active.clearRetainingCapacity();
        var next: usize = 0;

        var y = y_start;
        while (y < y_end) : (y += 1) {
            const row_top: f32 = @floatFromInt(y);
            const row_bot = row_top + 1;
            while (next < self.edges.items.len and self.edges.items[next].y0 < row_bot) : (next += 1) {
                try self.active.append(self.a, self.edges.items[next]);
            }
            // Prune edges fully above this row.
            var k: usize = 0;
            while (k < self.active.items.len) {
                if (self.active.items[k].y1 <= row_top) {
                    _ = self.active.swapRemove(k);
                } else k += 1;
            }
            if (self.active.items.len == 0) continue;

            @memset(self.cov, 0);
            var s: u32 = 0;
            while (s < SUBSAMPLES) : (s += 1) {
                const sy = row_top + (@as(f32, @floatFromInt(s)) + 0.5) * SUB_WEIGHT;
                self.crossings.clearRetainingCapacity();
                for (self.active.items) |e| {
                    if (sy < e.y0 or sy >= e.y1) continue;
                    const x = e.x0 + (sy - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0);
                    try self.crossings.append(self.a, .{ .x = x, .dir = e.dir });
                }
                if (self.crossings.items.len < 2) continue;
                std.mem.sort(Crossing, self.crossings.items, {}, struct {
                    fn lt(_: void, l: Crossing, r: Crossing) bool {
                        return l.x < r.x;
                    }
                }.lt);
                var winding: i32 = 0;
                var span_start: f32 = 0;
                for (self.crossings.items) |c| {
                    const prev = winding;
                    winding += c.dir;
                    if (prev == 0 and winding != 0) {
                        span_start = c.x;
                    } else if (prev != 0 and winding == 0) {
                        self.addSpan(span_start, c.x, wf);
                    }
                }
            }
            self.compositeRow(y, color);
        }
    }

    // Accumulate one subsample span [xa, xb) into the row coverage with
    // fractional end pixels.
    fn addSpan(self: *RasterCanvas, xa_in: f32, xb_in: f32, wf: f32) void {
        var xa = xa_in;
        var xb = xb_in;
        if (xb <= 0 or xa >= wf) return;
        xa = @max(xa, 0);
        xb = @min(xb, wf);
        if (xb <= xa) return;
        const first: usize = @intFromFloat(@floor(xa));
        const last: usize = @intFromFloat(@floor(xb));
        if (first == last) {
            self.cov[first] += (xb - xa) * SUB_WEIGHT;
            return;
        }
        self.cov[first] += (@as(f32, @floatFromInt(first + 1)) - xa) * SUB_WEIGHT;
        var i = first + 1;
        while (i < last) : (i += 1) self.cov[i] += SUB_WEIGHT;
        if (last < self.w) self.cov[last] += (xb - @as(f32, @floatFromInt(last))) * SUB_WEIGHT;
    }

    // Straight-alpha src-over of the row's accumulated coverage.
    fn compositeRow(self: *RasterCanvas, y: u32, color: cv.Color) void {
        const row = self.px[@as(usize, y) * self.w * 4 ..];
        const sa: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
        for (self.cov, 0..) |c, i| {
            if (c <= 0) continue;
            const ca = @min(c, 1) * sa;
            if (ca <= 0) continue;
            const p = row[i * 4 ..][0..4];
            const da: f32 = @as(f32, @floatFromInt(p[3])) / 255.0;
            const oa = ca + da * (1 - ca);
            if (oa <= 0) continue;
            inline for (0..3) |ch| {
                const sc: f32 = @floatFromInt(@field(color, switch (ch) {
                    0 => "r",
                    1 => "g",
                    else => "b",
                }));
                const dc: f32 = @floatFromInt(p[ch]);
                p[ch] = @intFromFloat(@round((sc * ca + dc * da * (1 - ca)) / oa));
            }
            p[3] = @intFromFloat(@round(oa * 255));
        }
    }
};

// ---- tests -------------------------------------------------------------------

fn pxAt(rc: *const RasterCanvas, x: u32, y: u32) [4]u8 {
    const i = (@as(usize, y) * rc.w + x) * 4;
    return rc.px[i..][0..4].*;
}

test "fill: axis-aligned rect covers fully, half-pixel edge blends ~50%" {
    const a = std.testing.allocator;
    var rc = try RasterCanvas.init(a, 16, 16);
    defer rc.deinit();
    rc.clear(.{ .r = 0, .g = 0, .b = 0 });
    const ring = [_]cv.Point{ .{ .x = 2, .y = 2 }, .{ .x = 10.5, .y = 2 }, .{ .x = 10.5, .y = 10 }, .{ .x = 2, .y = 10 } };
    const rings = [_][]const cv.Point{&ring};
    try rc.asCanvas().fillPath(&rings, .{ .r = 255, .g = 255, .b = 255 });
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pxAt(&rc, 5, 5)); // interior
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pxAt(&rc, 12, 5)); // outside
    const edge = pxAt(&rc, 10, 5); // x in [10,10.5): half covered
    try std.testing.expect(edge[0] > 100 and edge[0] < 155);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pxAt(&rc, 5, 12)); // below
}

test "fill: nonzero winding — overlapping same-direction rings fill uniformly" {
    const a = std.testing.allocator;
    var rc = try RasterCanvas.init(a, 16, 16);
    defer rc.deinit();
    rc.clear(.{ .r = 0, .g = 0, .b = 0 });
    const r1 = [_]cv.Point{ .{ .x = 2, .y = 2 }, .{ .x = 10, .y = 2 }, .{ .x = 10, .y = 10 }, .{ .x = 2, .y = 10 } };
    const r2 = [_]cv.Point{ .{ .x = 6, .y = 6 }, .{ .x = 14, .y = 6 }, .{ .x = 14, .y = 14 }, .{ .x = 6, .y = 14 } };
    const rings = [_][]const cv.Point{ &r1, &r2 };
    try rc.asCanvas().fillPath(&rings, .{ .r = 200, .g = 0, .b = 0, .a = 128 });
    // The overlap zone composites ONCE (winding 2 == winding 1 coverage).
    try std.testing.expectEqual(pxAt(&rc, 4, 4), pxAt(&rc, 8, 8));
}

test "fill: counter-oriented inner ring is a hole" {
    const a = std.testing.allocator;
    var rc = try RasterCanvas.init(a, 16, 16);
    defer rc.deinit();
    rc.clear(.{ .r = 0, .g = 0, .b = 0 });
    const outer = [_]cv.Point{ .{ .x = 2, .y = 2 }, .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 14 }, .{ .x = 2, .y = 14 } };
    const hole = [_]cv.Point{ .{ .x = 6, .y = 6 }, .{ .x = 6, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 6 } }; // reversed
    const rings = [_][]const cv.Point{ &outer, &hole };
    try rc.asCanvas().fillPath(&rings, .{ .r = 255, .g = 255, .b = 255 });
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pxAt(&rc, 4, 8)); // rim
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pxAt(&rc, 8, 8)); // hole
}

test "stroke: width covers, round cap extends past the endpoint, join uniform" {
    const a = std.testing.allocator;
    var rc = try RasterCanvas.init(a, 32, 32);
    defer rc.deinit();
    rc.clear(.{ .r = 0, .g = 0, .b = 0 });
    // L-shaped polyline: horizontal then vertical, width 4.
    const line = [_]cv.Point{ .{ .x = 6, .y = 8 }, .{ .x = 20, .y = 8 }, .{ .x = 20, .y = 22 } };
    const lines = [_][]const cv.Point{&line};
    try rc.asCanvas().strokePath(&lines, 4, null, .{ .r = 0, .g = 200, .b = 0, .a = 128 });
    try std.testing.expectEqual(pxAt(&rc, 12, 8)[1], pxAt(&rc, 12, 7)[1]); // 4px band around y=8
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pxAt(&rc, 12, 12)); // clear of the band
    // Round cap: the disc reaches ~2px left of the start vertex.
    try std.testing.expect(pxAt(&rc, 5, 8)[1] > 0);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pxAt(&rc, 2, 8));
    // The elbow (overlap of both segments + disc) composites exactly once:
    // same color as mid-segment despite the 50% alpha paint.
    try std.testing.expectEqual(pxAt(&rc, 12, 8), pxAt(&rc, 20, 8));
}

test "stroke: dash [4,3] alternates on/off along the run" {
    const a = std.testing.allocator;
    var rc = try RasterCanvas.init(a, 40, 8);
    defer rc.deinit();
    rc.clear(.{ .r = 0, .g = 0, .b = 0 });
    const line = [_]cv.Point{ .{ .x = 2, .y = 4 }, .{ .x = 38, .y = 4 } };
    const lines = [_][]const cv.Point{&line};
    try rc.asCanvas().strokePath(&lines, 2, .{ 4, 3 }, .{ .r = 255, .g = 255, .b = 255 });
    // on-run [2,6): x=3 painted. The round caps (radius w/2 = 1) eat 1px into
    // each 3px gap, so only the gap's middle pixel is clear: [6,9) -> x=7,
    // [13,16) -> x=14. x=10 sits inside the next on-run [9,13).
    try std.testing.expect(pxAt(&rc, 3, 4)[0] == 255);
    try std.testing.expect(pxAt(&rc, 7, 4)[0] < 30);
    try std.testing.expect(pxAt(&rc, 10, 4)[0] == 255);
    try std.testing.expect(pxAt(&rc, 14, 4)[0] < 30);
}

test "determinism: identical scene twice -> identical buffers" {
    const a = std.testing.allocator;
    var bufs: [2]u64 = undefined;
    for (0..2) |n| {
        var rc = try RasterCanvas.init(a, 64, 64);
        defer rc.deinit();
        rc.clear(.{ .r = 10, .g = 20, .b = 30 });
        const tri = [_]cv.Point{ .{ .x = 3.2, .y = 5.1 }, .{ .x = 60.7, .y = 12.9 }, .{ .x = 31.5, .y = 58.4 } };
        const rings = [_][]const cv.Point{&tri};
        try rc.asCanvas().fillPath(&rings, .{ .r = 120, .g = 40, .b = 200, .a = 180 });
        const line = [_]cv.Point{ .{ .x = 5, .y = 60 }, .{ .x = 55, .y = 30 }, .{ .x = 60, .y = 5 } };
        const lines = [_][]const cv.Point{&line};
        try rc.asCanvas().strokePath(&lines, 3, .{ 4, 3 }, .{ .r = 255, .g = 255, .b = 0, .a = 200 });
        bufs[n] = std.hash.Wyhash.hash(0, rc.px);
    }
    try std.testing.expectEqual(bufs[0], bufs[1]);
}
