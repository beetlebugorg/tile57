//! PixelSurface: the Surface implementation that RESOLVES and DRAWS — the
//! pixel-side counterpart of the tile surfaces. Written once; every pixel
//! format below it is just a Canvas (RasterCanvas now, PDF later).
//!
//!   Surface calls ─► resolver (token->RGB @ palette, display gates @ zoom)
//!                ─► op buffer ─► endScene: stable sort by draw_prio ─► Canvas
//!
//! Buffering exists because the engine emits features in CELL order (the tile
//! path routes by layer and lets the client sort on the draw_prio prop);
//! pixels must PAINT in S-52 priority order, and the P4 collision pass needs
//! the whole scene anyway.
//!
//! P2 scope: area fills + line strokes end-to-end. Symbols, soundings,
//! patterns and text buffer nothing yet — they land with P3 (catalogue SVG
//! replay) and P4 (glyphs + collision).

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("surface.zig");
const resolve = @import("resolve.zig");
const cv = @import("canvas.zig");
const raster = @import("raster.zig");
const png = @import("png.zig");
const sym = @import("symbols.zig");
const sndfrm = @import("sndfrm.zig");

/// Unmapped color tokens paint magenta, same as the MapLibre style's fallback —
/// visible, never silent.
const FALLBACK = cv.Color{ .r = 255, .g = 0, .b = 255 };

/// The MapLibre style's dashed pattern (line-dasharray [4,3], in line-width
/// units) — mirrored so the two paths dash alike.
const DASH_ON = 4.0;
const DASH_OFF = 3.0;

const OpKind = union(enum) {
    fill: struct { rings: []const []const cv.Point, color: cv.Color, rule: cv.FillRule = .nonzero },
    pattern: struct { rings: []const []const cv.Point, cell: *const cv.Pattern },
    stroke: struct { lines: []const []const cv.Point, width: f32, dash: ?[2]f32, color: cv.Color },
};

const Op = struct {
    prio: i64,
    seq: usize,
    kind: OpKind,
};

pub const PixelSurface = struct {
    a: Allocator,
    colors: *const resolve.Colors,
    palette: resolve.PaletteId,
    settings: *const resolve.MarinerSettings,
    /// Fractional display zoom the gates evaluate at.
    zoom: f64,
    /// Output size in pixels and the tile-space extent the incoming geometry
    /// uses; scale maps one into the other (e.g. 256 / 4096).
    size_px: u32,
    scale: f32,
    /// Catalogue symbol geometry (null = symbols/soundings are skipped —
    /// fills/lines-only render). Wired from the sprite module's nanosvg-backed
    /// store, or a test fake.
    store: ?sym.SymbolStore = null,
    ops: std.ArrayList(Op) = .empty,
    cur: rs.FeatureMeta = .{},
    cur_visible: bool = true,

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

    /// `a` should be the same scratch arena the engine allocates geometry
    /// from — buffered ops live until endScene, exactly like the tile
    /// surface's feature lists.
    pub fn init(a: Allocator, colors: *const resolve.Colors, palette: resolve.PaletteId, settings: *const resolve.MarinerSettings, zoom: f64, size_px: u32, tile_extent: u32) PixelSurface {
        return .{
            .a = a,
            .colors = colors,
            .palette = palette,
            .settings = settings,
            .zoom = zoom,
            .size_px = size_px,
            .scale = @as(f32, @floatFromInt(size_px)) / @as(f32, @floatFromInt(tile_extent)),
        };
    }

    pub fn asSurface(self: *PixelSurface) rs.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn sp(ctx: *anyopaque) *PixelSurface {
        return @ptrCast(@alignCast(ctx));
    }

    fn resolveColor(self: *const PixelSurface, token: []const u8) cv.Color {
        const rgb = self.colors.get(self.palette, token) orelse return FALLBACK;
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }

    fn toCanvas(self: *PixelSurface, parts: []const []const rs.TilePoint) ![]const []const cv.Point {
        const out = try self.a.alloc([]const cv.Point, parts.len);
        for (parts, 0..) |part, i| {
            const pts = try self.a.alloc(cv.Point, part.len);
            for (part, 0..) |p, j| pts[j] = .{
                .x = @as(f32, @floatFromInt(p.x)) * self.scale,
                .y = @as(f32, @floatFromInt(p.y)) * self.scale,
            };
            out[i] = pts;
        }
        return out;
    }

    fn push(self: *PixelSurface, kind: OpKind) !void {
        try self.ops.append(self.a, .{ .prio = self.cur.draw_prio, .seq = self.ops.items.len, .kind = kind });
    }

    // ---- Surface impl ---------------------------------------------------------

    fn beginScene(_: *anyopaque, _: u8) anyerror!void {}

    fn beginFeature(ctx: *anyopaque, meta: *const rs.FeatureMeta) anyerror!void {
        const self = sp(ctx);
        self.cur = meta.*;
        // Category / viewing-group / SCAMIN gates apply per feature; the
        // symbol-specific ISODGR01 case re-evaluates at drawSymbol (P3).
        self.cur_visible = resolve.visible(meta, null, self.zoom, self.settings);
    }

    fn fillArea(ctx: *anyopaque, token: rs.ColorToken, rings: []const []const rs.TilePoint, depth: ?rs.DepthRange) anyerror!void {
        _ = depth; // the rule resolved the depth token against the real context
        const self = sp(ctx);
        if (!self.cur_visible) return;
        try self.push(.{ .fill = .{ .rings = try self.toCanvas(rings), .color = self.resolveColor(token) } });
    }

    fn fillPattern(ctx: *anyopaque, name: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        const store = self.store orelse return;
        if (!self.cur_visible) return;
        // The pattern cell rasterizes at this scene's screen density, so it
        // repeats at the same on-screen period as the MapLibre fill-pattern.
        const ppm: f32 = @floatCast(sndfrm.SYMBOL_SCALE * 100.0 * @as(f64, @floatFromInt(self.size_px)) / 256.0);
        const cell = store.getPattern(name, ppm) orelse return;
        try self.push(.{ .pattern = .{ .rings = try self.toCanvas(rings), .cell = cell } });
    }

    fn strokeLine(ctx: *anyopaque, token: rs.ColorToken, width_px: f64, dash: rs.Dash, lines: []const []const rs.TilePoint, valdco: ?f64) anyerror!void {
        _ = valdco; // contour labels are text (P4)
        const self = sp(ctx);
        if (!self.cur_visible) return;
        const w: f32 = @floatCast(width_px);
        const d: ?[2]f32 = switch (dash) {
            .solid => null,
            .dashed => .{ DASH_ON * w, DASH_OFF * w },
        };
        try self.push(.{ .stroke = .{ .lines = try self.toCanvas(lines), .width = w, .dash = d, .color = self.resolveColor(token) } });
    }

    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: rs.SymbolPlacement, danger_depth: ?f64) anyerror!void {
        _ = rot_north; // north-up scene: rotation is rot_deg either way
        _ = placement;
        const self = sp(ctx);
        const store = self.store orelse return;
        // Re-gate with the symbol name: ISODGR01 rides its own toggle.
        if (!resolve.visible(&self.cur, name, self.zoom, self.settings)) return;
        // Live danger swap (mirrors chartstyle.pointSymbolImage): a danger lying
        // DEEPER than the mariner's safety contour draws the subdued DANGER02.
        var eff = name;
        if (danger_depth) |dd| eff = if (dd > self.settings.safety_contour) "DANGER02" else "DANGER01";
        const s = store.get(eff) orelse return; // unknown glyph: skip (the tile
        // path shows QUESMRK1 for unmapped CLASSES; an unmapped symbol NAME is
        // a catalogue gap and drawing nothing beats a wrong mark)
        try self.pushSymbol(s, at, rot_deg, scale);
    }

    fn drawSounding(ctx: *anyopaque, depth_m: f64, swept: bool, low_acc: bool, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        const store = self.store orelse return;
        if (!resolve.visible(&self.cur, null, self.zoom, self.settings)) return;
        // Bold/faint split at the mariner's LIVE safety depth (metres), display
        // value in the mariner's unit — the same composition the tile path
        // bakes as sym_s/sym_g(+_ft) and picks via soundingsIconImage.
        const feet = self.settings.depth_unit == .feet;
        const shown = if (feet) depth_m * sndfrm.M_TO_FT else depth_m;
        const prefix: []const u8 = if (depth_m <= self.settings.safety_depth) "SOUNDS" else "SOUNDG";
        const list = try sndfrm.syms(self.a, prefix, shown, swept, low_acc, feet);
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |glyph| {
            if (glyph.len == 0) continue;
            // Each digit glyph self-positions by its pivot: draw all at the point.
            if (store.get(glyph)) |s| try self.pushSymbol(s, at, 0, sndfrm.SYMBOL_SCALE);
        }
    }

    /// Buffer one symbol's styled paths, transformed into canvas space:
    /// symbol-mm geometry relative to the pivot, scaled by `scale` (screen px
    /// per 0.01 mm) x the canvas supersample, rotated, anchored at `at`.
    fn pushSymbol(self: *PixelSurface, s: *const sym.Symbol, at: rs.TilePoint, rot_deg: f64, scale: f64) !void {
        const k: f32 = @floatCast(scale * 100.0 * @as(f64, @floatFromInt(self.size_px)) / 256.0);
        const rad: f32 = @floatCast(rot_deg * std.math.pi / 180.0);
        const cosr = @cos(rad);
        const sinr = @sin(rad);
        const ax = @as(f32, @floatFromInt(at.x)) * self.scale;
        const ay = @as(f32, @floatFromInt(at.y)) * self.scale;
        for (s.paths) |p| {
            const rings = try self.a.alloc([]const cv.Point, p.contours.len);
            for (p.contours, 0..) |contour, i| {
                const pts = try self.a.alloc(cv.Point, contour.len);
                for (contour, 0..) |c, j| {
                    const lx = (c.x - s.pivot.x) * k;
                    const ly = (c.y - s.pivot.y) * k;
                    pts[j] = .{ .x = ax + lx * cosr - ly * sinr, .y = ay + lx * sinr + ly * cosr };
                }
                rings[i] = pts;
            }
            if (p.fill) |color| try self.push(.{ .fill = .{ .rings = rings, .color = color, .rule = .even_odd } });
            if (p.stroke) |st| try self.push(.{ .stroke = .{ .lines = rings, .width = st.width * k, .dash = null, .color = st.color } });
        }
    }

    fn drawText(_: *anyopaque, _: []const u8, _: *const rs.TextStyle, _: rs.TilePoint) anyerror!void {} // P4

    fn endFeature(_: *anyopaque) anyerror!void {}

    fn endScene(ctx: *anyopaque, out: Allocator) anyerror![]u8 {
        const self = sp(ctx);
        // S-52 paint order: draw priority, then emission order (stable).
        std.mem.sort(Op, self.ops.items, {}, struct {
            fn lt(_: void, l: Op, r: Op) bool {
                if (l.prio != r.prio) return l.prio < r.prio;
                return l.seq < r.seq;
            }
        }.lt);

        var rc = try raster.RasterCanvas.init(self.a, self.size_px, self.size_px);
        defer rc.deinit();
        // NODTA under everything (S-52 no-data); the palette decides its shade.
        rc.clear(self.resolveColor("NODTA"));
        const canvas = rc.asCanvas();
        for (self.ops.items) |op| switch (op.kind) {
            .fill => |f| try canvas.fillPath(f.rings, f.color, f.rule),
            .pattern => |p| try canvas.fillPattern(p.rings, p.cell),
            .stroke => |s| try canvas.strokePath(s.lines, s.width, s.dash, s.color),
        };
        return png.encodeRgba(out, rc.px, rc.w, rc.h);
    }
};

// ---- tests -------------------------------------------------------------------

const test_profile =
    \\<palette name="Day">
    \\ <item token="NODTA"><srgb><red>160</red><green>160</green><blue>160</blue></srgb></item>
    \\ <item token="DEPVS"><srgb><red>180</red><green>210</green><blue>230</blue></srgb></item>
    \\ <item token="CHBLK"><srgb><red>0</red><green>0</green><blue>0</blue></srgb></item>
    \\</palette>
;

test "PixelSurface: resolves tokens, gates SCAMIN, sorts by draw_prio" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.MarinerSettings{};
    var ps = PixelSurface.init(a, &colors, .day, &settings, 14.0, 64, 64);
    const surf = ps.asSurface();

    try surf.beginScene(14);

    // Low-prio full-cover fill, emitted FIRST but painted UNDER the later
    // higher-prio one? No — higher prio paints LATER (on top). Emit the
    // high-prio fill first to prove sorting reorders it above.
    const big = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 64, .y = 0 }, .{ .x = 64, .y = 64 }, .{ .x = 0, .y = 64 } };
    const rings = [_][]const rs.TilePoint{&big};

    const hi = rs.FeatureMeta{ .draw_prio = 8 };
    try surf.beginFeature(&hi);
    try surf.fillArea("DEPVS", &rings, null);
    try surf.endFeature();

    const lo = rs.FeatureMeta{ .draw_prio = 2 };
    try surf.beginFeature(&lo);
    try surf.fillArea("CHBLK", &rings, null);
    try surf.endFeature();

    // A SCAMIN 1:30000 feature at zoom 10 (gate ~13.19): dropped entirely.
    var ps_low = PixelSurface.init(a, &colors, .day, &settings, 10.0, 64, 64);
    const surf_low = ps_low.asSurface();
    const gated = rs.FeatureMeta{ .draw_prio = 9, .scamin = 30000 };
    try surf_low.beginFeature(&gated);
    try surf_low.fillArea("CHBLK", &rings, null);
    try std.testing.expectEqual(@as(usize, 0), ps_low.ops.items.len);

    const bytes = try surf.endScene(a);
    // Decode-free check: PNG signature + the sort left DEPVS (prio 8) on top —
    // verify via the op order after endScene's sort.
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, bytes[0..4]);
    try std.testing.expectEqual(@as(i64, 2), ps.ops.items[0].prio);
    try std.testing.expectEqual(@as(i64, 8), ps.ops.items[1].prio);
}

test "PixelSurface: unknown token falls back magenta, dashed maps to [4w,3w]" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.MarinerSettings{};
    var ps = PixelSurface.init(a, &colors, .day, &settings, 14.0, 64, 4096);
    const surf = ps.asSurface();

    const line = [_]rs.TilePoint{ .{ .x = 0, .y = 2048 }, .{ .x = 4096, .y = 2048 } };
    const lines = [_][]const rs.TilePoint{&line};
    const meta = rs.FeatureMeta{ .draw_prio = 5 };
    try surf.beginFeature(&meta);
    try surf.strokeLine("NOSUCH", 2, .dashed, &lines, null);
    try surf.endFeature();

    const op = ps.ops.items[0].kind.stroke;
    try std.testing.expectEqual(FALLBACK, op.color);
    try std.testing.expectEqual([2]f32{ 8, 6 }, op.dash.?);
    // 4096-extent geometry landed in 64px space.
    try std.testing.expectEqual(@as(f32, 32), op.lines[0][1].y);
    try std.testing.expectEqual(@as(f32, 64), op.lines[0][1].x);
}

test "drawSymbol: pivot/scale/rotate transform, even-odd fill, danger swap, sounding digits" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Fake store: one 2x2mm square with pivot at its centre, named for every
    // lookup this test makes (symbol, danger variants, sounding digit glyphs).
    const Fake = struct {
        square: sym.Symbol,
        hits: std.ArrayList([]const u8),
        alloc: Allocator,
        const vt = sym.SymbolStore.VTable{ .get = get, .getPattern = getPattern };
        fn getPattern(_: *anyopaque, _: []const u8, _: f32) ?*const cv.Pattern {
            return null;
        }
        fn get(ctx: *anyopaque, name: []const u8) ?*const sym.Symbol {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits.append(self.alloc, self.alloc.dupe(u8, name) catch return null) catch return null;
            return &self.square;
        }
    };
    const ring = [_]cv.Point{ .{ .x = -1, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = 1, .y = 1 }, .{ .x = -1, .y = 1 } };
    const contours = [_][]const cv.Point{&ring};
    var fake = Fake{
        .square = .{
            .paths = &.{.{ .fill = .{ .r = 10, .g = 20, .b = 30 }, .contours = &contours }},
            .pivot = .{ .x = 0, .y = 0 },
        },
        .hits = .empty,
        .alloc = a,
    };

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.MarinerSettings{ .display_other = true };
    var ps = PixelSurface.init(a, &colors, .day, &settings, 14.0, 256, 256);
    ps.store = .{ .ptr = &fake, .vtable = &Fake.vt };
    const surf = ps.asSurface();

    const meta = rs.FeatureMeta{ .draw_prio = 9 };
    try surf.beginFeature(&meta);
    // scale 0.02835 px per 0.01mm -> k = 2.835 px/mm at 256px; 90° rotation.
    try surf.drawSymbol("BOYLAT13", .{ .x = 128, .y = 128 }, 90, sndfrm.SYMBOL_SCALE, false, .point, null);
    try surf.endFeature();
    try std.testing.expectEqual(@as(usize, 1), ps.ops.items.len);
    const fill = ps.ops.items[0].kind.fill;
    try std.testing.expectEqual(cv.FillRule.even_odd, fill.rule);
    // (-1,-1)mm * 2.835, rotated 90° -> (2.835, -2.835) + anchor(128,128).
    try std.testing.expectApproxEqAbs(@as(f32, 128 + 2.835), fill.rings[0][0].x, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 128 - 2.835), fill.rings[0][0].y, 1e-2);

    // Danger swap: deeper than the (default 10 m) safety contour -> DANGER02.
    try surf.beginFeature(&meta);
    try surf.drawSymbol("DANGER01", .{ .x = 10, .y = 10 }, 0, sndfrm.SYMBOL_SCALE, false, .point, 15.0);
    try surf.drawSymbol("DANGER01", .{ .x = 10, .y = 10 }, 0, sndfrm.SYMBOL_SCALE, false, .point, 5.0);
    try surf.endFeature();
    try std.testing.expectEqualStrings("DANGER02", fake.hits.items[1]);
    try std.testing.expectEqualStrings("DANGER01", fake.hits.items[2]);

    // Sounding: 4.5 m <= safety depth -> bold SOUNDS digits 14 + 55.
    try surf.beginFeature(&meta);
    try surf.drawSounding(4.5, false, false, .{ .x = 50, .y = 50 });
    try surf.endFeature();
    try std.testing.expectEqualStrings("SOUNDS14", fake.hits.items[3]);
    try std.testing.expectEqualStrings("SOUNDS55", fake.hits.items[4]);
    // 54 m deep -> faint SOUNDG digits.
    try surf.beginFeature(&meta);
    try surf.drawSounding(54.0, false, false, .{ .x = 60, .y = 60 });
    try surf.endFeature();
    try std.testing.expectEqualStrings("SOUNDG15", fake.hits.items[5]);
    try std.testing.expectEqualStrings("SOUNDG04", fake.hits.items[6]);
}
