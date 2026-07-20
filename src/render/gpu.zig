//! GpuSurface: the Surface implementation that emits DRAW-READY BUFFERS — the
//! fourth output alongside pixel (raster/PDF), ascii and vector (callbacks).
//!
//!   Surface calls ─► resolver (token->RGB @ palette, display gates @ zoom)
//!                ─► op buffer ─► endScene: sort by paint order, tessellate,
//!                                pack ─► {vertices, indices, ranges}
//!
//! WHY THIS EXISTS. A GPU host must batch by pipeline, which destroys the order
//! the engine emitted in, so it has to rebuild paint order itself. Handing it
//! only the callback stream meant every host also grew: a tessellator, a vertex
//! packer, a copy of the class taxonomy, and a copy of the S-52 ordering rule.
//! That is a scene — a second one, drifting from this one. The same spec bug
//! (applying OVERRADAR precedence with no radar overlay) had to be found and
//! fixed twice because of it.
//!
//! So the engine hands over geometry that is already triangulated, already in
//! paint order, and already split into ranges a host can draw one pipeline at a
//! time. The host uploads and draws. It owns no scene and knows no S-52.
//!
//! WHAT THE HOST STILL OWNS: the camera, the shaders, and the decision of what
//! to do with `local` offsets and `scamin` — those are per-frame, and baking
//! them here would force a rebuild on every zoom.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("surface.zig");
const resolve = @import("resolve.zig");
const tess = @import("tess.zig");
const sym = @import("symbols.zig");
const cv = @import("canvas.zig");
const paint = @import("paint.zig");

/// What a range draws — the host picks a pipeline from this, nothing more. It is
/// NOT a paint-order key: ordering is `paint_key` and only `paint_key`. Shared
/// with every other surface so the four outputs cannot disagree about classes.
pub const Kind = paint.Layer;

/// One vertex. `x,y` is world position (web-mercator, [0,1], y down) and is what
/// the camera transforms. `ox,oy` is an offset in REFERENCE PIXELS the host adds
/// in screen space after projection — zero for area interiors, ±half-width for
/// line edges, and the glyph/symbol outline for marks. Keeping the two separate
/// is what lets a symbol stay a constant size on screen while its anchor moves
/// with the chart, without re-tessellating on zoom.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    ox: f32,
    oy: f32,
    /// SCAMIN 1:N denominator, 0 = always visible. The host drops the vertex
    /// when its display scale is finer; it is per-vertex so a host can gate in
    /// the shader rather than rebuilding the scene per zoom.
    scamin: f32,
    /// S-52 display category (0 base, 1 standard, 2 other) — the host's category
    /// switches gate on it live, again to avoid a rebuild.
    disp_cat: u8,
    /// Non-zero when the mark is chart-relative (ORIENT symbols, linestyle
    /// bricks): a rotated view must turn it. Zero means screen-upright.
    map_align: u8,
    _pad: [2]u8 = .{ 0, 0 },
};

/// A contiguous slice of the index buffer that draws with one pipeline and one
/// colour. Ranges come out sorted by `paint_key`; draw them in order and the
/// chart is correct.
pub const Range = extern struct {
    first_index: u32,
    index_count: u32,
    /// The engine's paint-order key. Ranges are already sorted by it; it is
    /// exposed so a host batching ACROSS scenes (tiles) can interleave them.
    /// Opaque — compare, never decode.
    paint_key: u32,
    kind: Kind,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Resolved RGBA for the palette this scene was built with.
    color: [4]u8,
};

/// A finished scene. Everything borrows the arena passed to `endScene` and dies
/// with it.
pub const Scene = struct {
    vertices: []const Vertex,
    indices: []const u32,
    ranges: []const Range,
};

/// A buffered draw call, held until endScene can order the whole scene. Geometry
/// is kept as the caller's rings (arena-owned) and only tessellated once the
/// order is known, so a call that turns out to be invisible costs no triangles.
const Op = struct {
    paint_key: u32,
    seq: usize,
    kind: Kind,
    color: [4]u8,
    scamin: f32,
    disp_cat: u8,
    map_align: u8,
    geom: Geom,
};

const Geom = union(enum) {
    /// World-space rings, tessellated under `rule`.
    fill: struct { rings: []const []const rs.TilePoint, rule: tess.Rule },
    /// World-space polylines expanded to quads `half_w` reference px either side.
    stroke: struct { lines: []const []const rs.TilePoint, half_w: f32, dash: rs.Dash },
    /// A symbol: world anchor plus local outline rings in reference px.
    mark: struct { anchor: rs.TilePoint, rings: []const []const [2]f32, rule: tess.Rule },
};

pub const GpuSurface = struct {
    a: Allocator,
    colors: *const resolve.Colors,
    palette: resolve.PaletteId,
    settings: *const resolve.Settings,
    zoom: f64,
    /// Tile extent -> world [0,1]: the engine hands geometry in tile units and a
    /// GPU host wants world space, so fold the tile origin in here rather than
    /// making every host redo it.
    tile_scale: f64 = 1.0,
    tile_ox: f64 = 0,
    tile_oy: f64 = 0,

    ops: std.ArrayList(Op) = .empty,
    cur: rs.FeatureMeta = .{},
    store: ?sym.SymbolStore = null,
    tessellator: tess.Tessellator,

    const vtable = rs.Surface.VTable{
        .beginScene = beginScene,
        .beginFeature = beginFeature,
        .fillArea = fillArea,
        .fillPattern = fillPattern,
        .strokeLine = strokeLine,
        .drawSymbol = drawSymbol,
        .drawSounding = drawSounding,
        .drawText = drawText,
        .endFeature = endFeature,
        .endScene = endScene,
    };

    pub fn init(a: Allocator, colors: *const resolve.Colors, palette: resolve.PaletteId, settings: *const resolve.Settings, zoom: f64) !GpuSurface {
        return .{
            .a = a,
            .colors = colors,
            .palette = palette,
            .settings = settings,
            .zoom = zoom,
            .tessellator = try tess.Tessellator.init(a),
        };
    }

    pub fn deinit(self: *GpuSurface) void {
        self.tessellator.deinit();
        self.ops.deinit(self.a);
    }

    pub fn asSurface(self: *GpuSurface) rs.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn sp(ctx: *anyopaque) *GpuSurface {
        return @ptrCast(@alignCast(ctx));
    }

    fn worldOf(self: *const GpuSurface, p: rs.TilePoint) [2]f32 {
        return .{
            @floatCast(self.tile_ox + @as(f64, @floatFromInt(p.x)) * self.tile_scale),
            @floatCast(self.tile_oy + @as(f64, @floatFromInt(p.y)) * self.tile_scale),
        };
    }

    fn rgba(self: *const GpuSurface, token: rs.ColorToken) [4]u8 {
        const split = rs.fillToken(token);
        // Unmapped tokens paint magenta, same as the other surfaces — visible,
        // never silent.
        const c = self.colors.get(self.palette, split.name) orelse resolve.Rgb{ .r = 255, .g = 0, .b = 255 };
        return .{ c.r, c.g, c.b, split.alpha };
    }

    fn push(self: *GpuSurface, kind: Kind, color: [4]u8, geom: Geom) !void {
        try self.ops.append(self.a, .{
            .paint_key = paint.key(kind, self.cur.display_priority, self.cur.display_plane, self.settings.radar_overlay),
            .seq = self.ops.items.len,
            .kind = kind,
            .color = color,
            .scamin = if (self.cur.scamin) |s| @floatFromInt(s) else 0,
            .disp_cat = @intCast(std.math.clamp(self.cur.display_category, 0, 2)),
            .map_align = 0,
            .geom = geom,
        });
    }

    // ---- Surface impl -------------------------------------------------------

    fn beginScene(_: *anyopaque, _: u8) anyerror!void {}

    fn beginFeature(ctx: *anyopaque, meta: *const rs.FeatureMeta) anyerror!void {
        sp(ctx).cur = meta.*;
    }

    fn endFeature(_: *anyopaque) anyerror!void {}

    fn fillArea(ctx: *anyopaque, token: rs.ColorToken, rings: []const []const rs.TilePoint, _: ?rs.DepthRange) anyerror!void {
        const self = sp(ctx);
        if (!resolve.visible(&self.cur, "", self.zoom, self.settings)) return;
        try self.push(.area, self.rgba(token), .{ .fill = .{ .rings = rings, .rule = .nonzero } });
    }

    fn fillPattern(_: *anyopaque, _: rs.SymbolName, _: []const []const rs.TilePoint) anyerror!void {
        // Area-fill patterns tile an atlas cell in screen space, which is a host
        // shader concern, not geometry. They need their own range kind + cell
        // metadata; until that is designed they are simply not emitted (the fill
        // beneath them still is), rather than emitted wrong.
    }

    fn strokeLine(ctx: *anyopaque, token: rs.ColorToken, width_px: f64, dash: rs.Dash, lines: []const []const rs.TilePoint, _: ?f64) anyerror!void {
        const self = sp(ctx);
        if (!resolve.visible(&self.cur, "", self.zoom, self.settings)) return;
        try self.push(.line, self.rgba(token), .{ .stroke = .{
            .lines = lines,
            .half_w = @floatCast(@max(width_px, 0.5) * 0.5),
            .dash = dash,
        } });
    }

    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool, _: rs.SymbolPlacement, danger_depth: ?f64) anyerror!void {
        const self = sp(ctx);
        const store = self.store orelse return;
        if (!resolve.visible(&self.cur, name, self.zoom, self.settings)) return;
        var eff = name;
        if (danger_depth) |dd| eff = if (dd > self.settings.safety_contour) "DANGER02" else "DANGER01";
        const s = store.get(eff) orelse return;
        try self.emitMark(.symbol, s, at, rot_deg, scale, rot_north);
    }

    fn drawSounding(_: *anyopaque, _: f64, _: bool, _: bool, _: rs.TilePoint) anyerror!void {
        // Soundings compose digit glyphs through SNDFRM; they arrive here only
        // when the engine cannot render them itself. Not yet emitted.
    }

    fn drawText(_: *anyopaque, _: []const u8, _: *const rs.TextStyle, _: rs.TilePoint) anyerror!void {
        // Text needs the shaped glyph run and the declutter pool, which resolve
        // at endScene. Not yet emitted.
    }

    /// Flatten a symbol's paths into local reference-px rings, rotated.
    fn emitMark(self: *GpuSurface, kind: Kind, s: *const sym.Symbol, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool) !void {
        const rad = rot_deg * std.math.pi / 180.0;
        const cs: f32 = @floatCast(@cos(rad));
        const sn: f32 = @floatCast(@sin(rad));
        const k: f32 = @floatCast(scale);
        var rings = std.ArrayList([]const [2]f32).empty;
        var color: [4]u8 = .{ 0, 0, 0, 255 };
        for (s.paths) |path| {
            // A path with no fill is stroke-only in the catalogue; it still
            // contributes its outline, so keep the last colour we saw.
            if (path.fill) |f| color = .{ f.r, f.g, f.b, 255 };
            for (path.contours) |contour| {
                const pts = try self.a.alloc([2]f32, contour.len);
                for (contour, 0..) |p, i| {
                    const lx = (@as(f32, @floatCast(p.x)) - @as(f32, @floatCast(s.pivot.x))) * k;
                    const ly = (@as(f32, @floatCast(p.y)) - @as(f32, @floatCast(s.pivot.y))) * k;
                    pts[i] = .{ lx * cs - ly * sn, lx * sn + ly * cs };
                }
                try rings.append(self.a, pts);
            }
        }
        if (rings.items.len == 0) return;
        try self.push(kind, color, .{ .mark = .{
            .anchor = at,
            .rings = try rings.toOwnedSlice(self.a),
            // Compound symbols carry counters; even-odd is what makes them holes.
            .rule = .even_odd,
        } });
        if (rot_north) self.ops.items[self.ops.items.len - 1].map_align = 1;
    }

    // ---- endScene: order, tessellate, pack ----------------------------------

    fn endScene(ctx: *anyopaque, out: Allocator) anyerror![]u8 {
        _ = sp(ctx);
        _ = out;
        // The byte-stream endScene is for the tile/pixel surfaces. A GPU host
        // wants structured buffers, so it calls `build` instead.
        return error.UseBuildInstead;
    }

    /// Order the scene and pack it into draw-ready buffers. Everything returned
    /// is allocated from `arena`.
    pub fn build(self: *GpuSurface, arena: Allocator) !Scene {
        std.mem.sort(Op, self.ops.items, {}, opLt);

        var verts = std.ArrayList(Vertex).empty;
        var indices = std.ArrayList(u32).empty;
        var ranges = std.ArrayList(Range).empty;

        for (self.ops.items) |op| {
            const first = indices.items.len;
            switch (op.geom) {
                .fill => |f| try self.emitFill(arena, &verts, &indices, op, f.rings, f.rule),
                .stroke => |s| try self.emitStroke(arena, &verts, &indices, op, s.lines, s.half_w),
                .mark => |m| try self.emitMarkGeom(arena, &verts, &indices, op, m.anchor, m.rings, m.rule),
            }
            const count = indices.items.len - first;
            if (count == 0) continue;
            // Coalesce with the previous range when it draws identically — a
            // feature emitting many rings at one priority is one draw, not many.
            if (ranges.items.len > 0) {
                const prev = &ranges.items[ranges.items.len - 1];
                if (prev.paint_key == op.paint_key and prev.kind == op.kind and
                    std.mem.eql(u8, &prev.color, &op.color) and
                    prev.first_index + prev.index_count == first)
                {
                    prev.index_count += @intCast(count);
                    continue;
                }
            }
            try ranges.append(arena, .{
                .first_index = @intCast(first),
                .index_count = @intCast(count),
                .paint_key = op.paint_key,
                .kind = op.kind,
                .color = op.color,
            });
        }
        return .{
            .vertices = try verts.toOwnedSlice(arena),
            .indices = try indices.toOwnedSlice(arena),
            .ranges = try ranges.toOwnedSlice(arena),
        };
    }

    fn opLt(_: void, l: Op, r: Op) bool {
        if (l.paint_key != r.paint_key) return l.paint_key < r.paint_key;
        return l.seq < r.seq;
    }

    fn vertexOf(op: Op, world: [2]f32, local: [2]f32) Vertex {
        return .{
            .x = world[0],
            .y = world[1],
            .ox = local[0],
            .oy = local[1],
            .scamin = op.scamin,
            .disp_cat = op.disp_cat,
            .map_align = op.map_align,
        };
    }

    fn emitFill(self: *GpuSurface, arena: Allocator, verts: *std.ArrayList(Vertex), indices: *std.ArrayList(u32), op: Op, rings: []const []const rs.TilePoint, rule: tess.Rule) !void {
        var contours = std.ArrayList([]const [2]f32).empty;
        defer contours.deinit(self.a);
        for (rings) |ring| {
            if (ring.len < 3) continue;
            const pts = try self.a.alloc([2]f32, ring.len);
            for (ring, 0..) |p, i| pts[i] = self.worldOf(p);
            try contours.append(self.a, pts);
        }
        defer for (contours.items) |c| self.a.free(c);
        const tri = (try self.tessellator.run(contours.items, rule)) orelse return;
        defer self.a.free(tri.indices);
        const base: u32 = @intCast(verts.items.len);
        var i: usize = 0;
        while (i < tri.verts.len) : (i += 2) {
            try verts.append(arena, vertexOf(op, .{ tri.verts[i], tri.verts[i + 1] }, .{ 0, 0 }));
        }
        for (tri.indices) |idx| try indices.append(arena, base + idx);
    }

    /// Expand a polyline into quads. The width is in REFERENCE PIXELS and goes
    /// into the local offset, not the world position, so a line keeps its screen
    /// width at every zoom without re-tessellating.
    fn emitStroke(self: *GpuSurface, arena: Allocator, verts: *std.ArrayList(Vertex), indices: *std.ArrayList(u32), op: Op, lines: []const []const rs.TilePoint, half_w: f32) !void {
        for (lines) |line| {
            if (line.len < 2) continue;
            var i: usize = 0;
            while (i + 1 < line.len) : (i += 1) {
                const a = self.worldOf(line[i]);
                const b = self.worldOf(line[i + 1]);
                var dx = b[0] - a[0];
                var dy = b[1] - a[1];
                const len = @sqrt(dx * dx + dy * dy);
                if (len == 0) continue;
                dx /= len;
                dy /= len;
                // Normal in screen space: the segment direction is a world
                // direction, but the offset is applied post-projection, so this
                // is only exact for uniform scale — which web-mercator is,
                // locally.
                const nx = -dy * half_w;
                const ny = dx * half_w;
                const base: u32 = @intCast(verts.items.len);
                try verts.append(arena, vertexOf(op, a, .{ nx, ny }));
                try verts.append(arena, vertexOf(op, a, .{ -nx, -ny }));
                try verts.append(arena, vertexOf(op, b, .{ nx, ny }));
                try verts.append(arena, vertexOf(op, b, .{ -nx, -ny }));
                for ([_]u32{ 0, 1, 2, 1, 3, 2 }) |k| try indices.append(arena, base + k);
            }
        }
    }

    fn emitMarkGeom(self: *GpuSurface, arena: Allocator, verts: *std.ArrayList(Vertex), indices: *std.ArrayList(u32), op: Op, anchor: rs.TilePoint, rings: []const []const [2]f32, rule: tess.Rule) !void {
        const tri = (try self.tessellator.run(rings, rule)) orelse return;
        defer self.a.free(tri.indices);
        const w = self.worldOf(anchor);
        const base: u32 = @intCast(verts.items.len);
        var i: usize = 0;
        while (i < tri.verts.len) : (i += 2) {
            // The whole outline rides the anchor's world position; the outline
            // itself is the local px offset.
            try verts.append(arena, vertexOf(op, w, .{ tri.verts[i], tri.verts[i + 1] }));
        }
        for (tri.indices) |idx| try indices.append(arena, base + idx);
    }
};

const testing = std.testing;

fn testSurface(a: Allocator, colors: *const resolve.Colors, settings: *const resolve.Settings) !GpuSurface {
    var s = try GpuSurface.init(a, colors, .day, settings, 12.0);
    s.tile_scale = 1.0 / 4096.0;
    return s;
}

test "gpu: ranges come out sorted by paint_key regardless of walk order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var gs = try testSurface(a, &colors, &settings);
    defer gs.deinit();
    const surf = gs.asSurface();

    const ring = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 100 } };
    const rings = [_][]const rs.TilePoint{&ring};
    const line = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 } };
    const lines = [_][]const rs.TilePoint{&line};

    // Walked worst-first: a high-priority line before a low-priority fill.
    const hi = rs.FeatureMeta{ .class = "LIGHTS", .display_priority = 24 };
    try surf.beginFeature(&hi);
    try surf.strokeLine("LITRD", 2.0, .solid, &lines, null);
    try surf.endFeature();

    const lo = rs.FeatureMeta{ .class = "DEPARE", .display_priority = 3 };
    try surf.beginFeature(&lo);
    try surf.fillArea("DEPVS", &rings, null);
    try surf.endFeature();

    const scene = try gs.build(a);
    try testing.expect(scene.ranges.len >= 2);
    var prev: u32 = 0;
    for (scene.ranges) |r| {
        try testing.expect(r.paint_key >= prev);
        prev = r.paint_key;
    }
    // The prio-3 fill draws first even though it was walked second.
    try testing.expectEqual(Kind.area, scene.ranges[0].kind);
    try testing.expectEqual(Kind.line, scene.ranges[scene.ranges.len - 1].kind);
}

test "gpu: every index is in range and every range is non-empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var gs = try testSurface(a, &colors, &settings);
    defer gs.deinit();
    const surf = gs.asSurface();

    const ring = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 100 }, .{ .x = 0, .y = 100 } };
    const rings = [_][]const rs.TilePoint{&ring};
    const meta = rs.FeatureMeta{ .class = "DEPARE", .display_priority = 9 };
    try surf.beginFeature(&meta);
    try surf.fillArea("DEPVS", &rings, null);
    try surf.endFeature();

    const scene = try gs.build(a);
    try testing.expect(scene.ranges.len > 0);
    for (scene.indices) |i| try testing.expect(i < scene.vertices.len);
    for (scene.ranges) |r| {
        try testing.expect(r.index_count > 0);
        try testing.expect(r.first_index + r.index_count <= scene.indices.len);
    }
}

test "gpu: a stroke's width lives in the local offset, not the world position" {
    // The property that lets a host re-zoom without asking for a new scene: both
    // ends of a segment share a world position and differ only in local offset.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var gs = try testSurface(a, &colors, &settings);
    defer gs.deinit();
    const surf = gs.asSurface();

    const line = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    const lines = [_][]const rs.TilePoint{&line};
    const meta = rs.FeatureMeta{ .class = "DEPCNT", .display_priority = 15 };
    try surf.beginFeature(&meta);
    try surf.strokeLine("CHBLK", 4.0, .solid, &lines, null);
    try surf.endFeature();

    const scene = try gs.build(a);
    try testing.expectEqual(@as(usize, 4), scene.vertices.len);
    // Vertices 0 and 1 are the same world point, offset opposite ways.
    try testing.expectEqual(scene.vertices[0].x, scene.vertices[1].x);
    try testing.expectEqual(scene.vertices[0].y, scene.vertices[1].y);
    try testing.expectApproxEqAbs(scene.vertices[0].oy, -scene.vertices[1].oy, 1e-6);
    try testing.expect(@abs(scene.vertices[0].oy) > 0);
}
