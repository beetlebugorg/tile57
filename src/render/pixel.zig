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
const dc = @import("declutter.zig");
const fontmod = @import("font.zig");
const pdf = @import("pdf.zig");
const cb_canvas = @import("cb_canvas.zig");

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
    /// A shaped label (outlines for raster + the glyph run for text-object
    /// canvases). `bbox` [minx,miny,maxx,maxy] and `group` (the S-52 text group)
    /// feed the collision pass.
    text: struct { run: cv.GlyphRun, bbox: [4]f32, group: i64 },
};

/// Paint class, mirroring the tile style's LAYER order (areas ->
/// area_patterns -> lines -> point_symbols -> soundings -> text): the class
/// is the major sort key, draw priority orders WITHIN a class — a fill never
/// paints over a line, whatever its priority, exactly like the layer stack.
const OpLayer = enum(u8) { area = 0, pattern = 1, line = 2, symbol = 3, sounding = 4, text = 5 };

const Op = struct {
    layer: OpLayer,
    prio: i64,
    seq: usize,
    kind: OpKind,
};

pub const Output = enum { png, pdf, callback };

/// A selection HIGHLIGHT overlay painted ON TOP of the finished chart raster —
/// the `explore --tui` live cell map sets it so the SELECTED feature stands out
/// from every other charted feature. Coordinates are canvas px: the caller
/// (`chart.renderCellView`) has already projected the feature's anchor lon/lat
/// (and, for a line/area, its bbox) into this scene's pixel frame. Null (the
/// default) leaves every other render — tiles, `renderView`, `renderFeature` —
/// byte-for-byte unchanged.
pub const ScreenHighlight = struct {
    /// Feature anchor in canvas px: the ring + reticle centre (any geometry).
    cx: f32,
    cy: f32,
    /// Line/area extent in canvas px [x0, y0, x1, y1] — a dashed box drawn
    /// around the feature; null for a point (reticle only).
    bbox: ?[4]f32 = null,
};

/// Highlight reticle colours: a hi-vis amber core over a near-black halo — a
/// pairing that pops against the whole S-52 palette (blue sea, tan land, white
/// safe water) and reads as a UI overlay, not chart content.
const HL_CORE = cv.Color{ .r = 255, .g = 221, .b = 0 };
const HL_HALO = cv.Color{ .r = 0, .g = 0, .b = 0, .a = 235 };

pub const PixelSurface = struct {
    a: Allocator,
    colors: *const resolve.Colors,
    palette: resolve.PaletteId,
    settings: *const resolve.Settings,
    /// Fractional display zoom the gates evaluate at.
    zoom: f64,
    /// Output size in pixels; a tile render is square (w == h == px_per_tile),
    /// a view spans several tiles. `scale` maps tile-extent units into px;
    /// `origin` is the CURRENT tile's top-left in canvas px (the view driver
    /// moves it between tiles; 0,0 for single-tile renders).
    w_px: u32,
    h_px: u32,
    px_per_tile: f32,
    scale: f32,
    origin: cv.Point = .{ .x = 0, .y = 0 },
    /// Catalogue symbol geometry (null = symbols/soundings are skipped —
    /// fills/lines-only render). Wired from the sprite module's nanosvg-backed
    /// store, or a test fake.
    store: ?sym.SymbolStore = null,
    /// endScene output format: raster PNG (default), vector PDF, or callback.
    output: Output = .png,
    /// For output == .callback: the C paint table geometry is forwarded to.
    cb: ?*const cb_canvas.CCanvas = null,
    /// Background colour token the scene clears to (null = "NODTA", the S-52
    /// no-data shade, as every whole-scene render does). Overridden only by the
    /// isolated single-feature thumbnail, which frames one feature on a solid
    /// sea/neutral fill.
    bg_token: ?[]const u8 = null,
    /// Optional selection highlight painted over the finished raster (see
    /// ScreenHighlight); null for every normal render.
    highlight: ?ScreenHighlight = null,
    /// The embedded label face; null only if the embedded TTF fails to parse.
    fnt: ?fontmod.Font = null,
    glyph_cache: std.AutoHashMapUnmanaged(u16, []const []const cv.Point) = .empty,
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
        .size_scale = sizeScale,
    };

    /// `a` should be the same scratch arena the engine allocates geometry
    /// from — buffered ops live until endScene, exactly like the tile
    /// surface's feature lists.
    pub fn init(a: Allocator, colors: *const resolve.Colors, palette: resolve.PaletteId, settings: *const resolve.Settings, zoom: f64, size_px: u32, tile_extent: u32) PixelSurface {
        return initView(a, colors, palette, settings, zoom, size_px, size_px, @floatFromInt(size_px), tile_extent);
    }

    /// A multi-tile view scene: w x h output px, each source tile occupying
    /// px_per_tile px (fractional zoom = a non-power-of-two px_per_tile).
    pub fn initView(a: Allocator, colors: *const resolve.Colors, palette: resolve.PaletteId, settings: *const resolve.Settings, zoom: f64, w_px: u32, h_px: u32, px_per_tile: f32, tile_extent: u32) PixelSurface {
        return .{
            .a = a,
            .colors = colors,
            .palette = palette,
            .settings = settings,
            .zoom = zoom,
            .w_px = w_px,
            .h_px = h_px,
            .px_per_tile = px_per_tile,
            .scale = px_per_tile / @as(f32, @floatFromInt(tile_extent)),
            .fnt = fontmod.Font.init(fontmod.notosans) catch null,
        };
    }

    /// Position the NEXT tile's geometry: its top-left corner in canvas px.
    pub fn setOrigin(self: *PixelSurface, x: f32, y: f32) void {
        self.origin = .{ .x = x, .y = y };
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
                .x = self.origin.x + @as(f32, @floatFromInt(p.x)) * self.scale,
                .y = self.origin.y + @as(f32, @floatFromInt(p.y)) * self.scale,
            };
            out[i] = pts;
        }
        return out;
    }

    fn push(self: *PixelSurface, layer: OpLayer, kind: OpKind) !void {
        try self.ops.append(self.a, .{ .layer = layer, .prio = self.cur.draw_prio, .seq = self.ops.items.len, .kind = kind });
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
        // ColorFill "NAME[,transparency]": apply the S-101 fill transparency (alpha).
        const ft = rs.fillToken(token);
        var col = self.resolveColor(ft.name);
        col.a = ft.alpha;
        try self.push(.area, .{ .fill = .{ .rings = try self.toCanvas(rings), .color = col } });
    }

    /// Device px per CSS px: the supersample factor (a 512px tile is the @2x
    /// render of the 256 baseline) times the mariner's physical-size
    /// multiplier (settings.size_scale — the style applies the same factor to
    /// icon-size / line-width / text-size so 1 S-52 mm reads as a true mm on
    /// a calibrated display).
    fn devScale(self: *const PixelSurface) f64 {
        return self.settings.size_scale * @as(f64, @floatCast(self.px_per_tile)) / 256.0;
    }

    /// devScale with the mariner's extra TEXT multiplier (mariner.text_size_scale) —
    /// the one scale that sizes a label AND its declutter box, so enlarged labels
    /// still collide correctly. 1.0 = no extra scale (byte-identical output).
    fn textDev(self: *const PixelSurface) f64 {
        return self.devScale() * self.settings.text_size_scale;
    }

    /// Surface contract: the physical-size multiplier the engine uses to walk
    /// complex-linestyle periods (scene.walkComplexRun), so --scale widens the
    /// spacing AND enlarges the bricks together (matching drawSymbol's devScale).
    /// NOT devScale: the period is in tile-coord and gets px_per_tile separately.
    fn sizeScale(ctx: *anyopaque) f64 {
        return sp(ctx).settings.size_scale;
    }

    fn fillPattern(ctx: *anyopaque, name: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        const store = self.store orelse return;
        if (!self.cur_visible) return;
        // The pattern cell rasterizes at this scene's screen density, so it
        // repeats at the same on-screen period as the MapLibre fill-pattern.
        const ppm: f32 = @floatCast(sndfrm.SYMBOL_SCALE * 100.0 * self.devScale());
        const cell = store.getPattern(name, ppm) orelse return;
        try self.push(.pattern, .{ .pattern = .{ .rings = try self.toCanvas(rings), .cell = cell } });
    }

    fn strokeLine(ctx: *anyopaque, token: rs.ColorToken, width_px: f64, dash: rs.Dash, lines: []const []const rs.TilePoint, valdco: ?f64) anyerror!void {
        const self = sp(ctx);
        if (!self.cur_visible) return;
        const w: f32 = @floatCast(width_px * self.devScale());
        const d: ?[2]f32 = switch (dash) {
            .solid => null,
            .dashed => .{ DASH_ON * w, DASH_OFF * w },
        };
        const canvas_lines = try self.toCanvas(lines);
        try self.push(.line, .{ .stroke = .{ .lines = canvas_lines, .width = w, .dash = d, .color = self.resolveColor(token) } });
        // Depth-contour label: the value in the mariner's unit, placed at the
        // midpoint of the longest segment (v1 horizontal placement; collision
        // culls the rest). Value formatting mirrors mariner.contourLabelField:
        // metres round, feet floor-to-tenth (a depth errs SHALLOW).
        if (valdco) |v| {
            var longest: f32 = 0;
            var mid = cv.Point{ .x = 0, .y = 0 };
            for (canvas_lines) |line| {
                for (0..line.len -| 1) |i| {
                    const dx = line[i + 1].x - line[i].x;
                    const dy = line[i + 1].y - line[i].y;
                    const len = dx * dx + dy * dy;
                    if (len > longest) {
                        longest = len;
                        mid = .{ .x = (line[i].x + line[i + 1].x) / 2, .y = (line[i].y + line[i + 1].y) / 2 };
                    }
                }
            }
            if (longest < 100) return; // too short to label at this zoom
            var buf: [24]u8 = undefined;
            const label = if (self.settings.depth_unit == .feet)
                std.fmt.bufPrint(&buf, "{d}", .{@floor(v * sndfrm.M_TO_FT)}) catch return
            else
                std.fmt.bufPrint(&buf, "{d}", .{@round(v)}) catch return;
            // CHGRD by day, bright neutral at dusk/night (contourLabelColor).
            const color = switch (self.palette) {
                .day => self.resolveColor("CHGRD"),
                .dusk => cv.Color{ .r = 0xdd, .g = 0xe7, .b = 0xec },
                .night => cv.Color{ .r = 0xaa, .g = 0xb7, .b = 0xbf },
            };
            // A contour value is not one of the spec's IMPORTANT text groups.
            try self.pushText(label, 10, "center", "middle", 0, 0, color, false, 0, mid);
        }
    }

    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: rs.SymbolPlacement, danger_depth: ?f64) anyerror!void {
        _ = rot_north; // north-up scene: rotation is rot_deg either way
        _ = placement;
        const self = sp(ctx);
        const store = self.store orelse return;
        // Re-gate with the symbol name: ISODGR01 rides its own toggle.
        if (!resolve.visible(&self.cur, name, self.zoom, self.settings)) return;
        // Live danger swap (mirrors mariner.pointSymbolImage): a danger lying
        // DEEPER than the mariner's safety contour draws the subdued DANGER02.
        var eff = name;
        if (danger_depth) |dd| eff = if (dd > self.settings.safety_contour) "DANGER02" else "DANGER01";
        const s = store.get(eff) orelse return; // unknown glyph: skip (the tile
        // path shows QUESMRK1 for unmapped CLASSES; an unmapped symbol NAME is
        // a catalogue gap and drawing nothing beats a wrong mark)
        try self.pushSymbol(.symbol, s, at, rot_deg, scale);
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
            if (store.get(glyph)) |s| try self.pushSymbol(.sounding, s, at, 0, sndfrm.SYMBOL_SCALE);
        }
    }

    /// Buffer one symbol's styled paths, transformed into canvas space:
    /// symbol-mm geometry relative to the pivot, scaled by `scale` (screen px
    /// per 0.01 mm) x the device scale (supersample + physical multiplier),
    /// rotated, anchored at `at`.
    fn pushSymbol(self: *PixelSurface, layer: OpLayer, s: *const sym.Symbol, at: rs.TilePoint, rot_deg: f64, scale: f64) !void {
        // Soundings get the mariner's extra sounding multiplier — enlarging each
        // digit AND its pivot-baked spacing together; plain symbols do not.
        const dev = if (layer == .sounding) self.devScale() * self.settings.sounding_size_scale else self.devScale();
        const k: f32 = @floatCast(scale * 100.0 * dev);
        const rad: f32 = @floatCast(rot_deg * std.math.pi / 180.0);
        const cosr = @cos(rad);
        const sinr = @sin(rad);
        const ax = self.origin.x + @as(f32, @floatFromInt(at.x)) * self.scale;
        const ay = self.origin.y + @as(f32, @floatFromInt(at.y)) * self.scale;
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
            if (p.fill) |color| try self.push(layer, .{ .fill = .{ .rings = rings, .color = color, .rule = .even_odd } });
            if (p.stroke) |st| try self.push(layer, .{ .stroke = .{ .lines = rings, .width = st.width * k, .dash = null, .color = st.color } });
        }
    }

    fn drawText(ctx: *anyopaque, text: []const u8, style: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (!self.cur_visible) return;
        if (!resolve.textGroupVisible(style.group, self.settings)) return;
        const font_px: f32 = @floatCast(if (style.font_size > 0) style.font_size else 12);
        // LocalOffset is millimetres, converted inside pushText at the S-52
        // screen pitch (2.835 px/mm x device scale) — NOT via em units of the
        // font size, which would overshoot the spec offset for a 12px label.
        const ox: f32 = @floatCast(style.offset_x);
        const oy: f32 = @floatCast(style.offset_y);
        // S-52/S-101 text is SOLID (FontBackgroundColor transparent) — the served
        // style deliberately renders no halo; match it. The GlyphRun halo plumbing
        // stays for a future opt-in legibility setting.
        const haloed = false;
        try self.pushText(text, font_px, if (style.halign.len > 0) style.halign else "center", if (style.valign.len > 0) style.valign else "middle", ox, oy, self.resolveColor(style.color), haloed, style.group, .{
            .x = self.origin.x + @as(f32, @floatFromInt(at.x)) * self.scale,
            .y = self.origin.y + @as(f32, @floatFromInt(at.y)) * self.scale,
        });
    }

    fn glyphOutline(self: *PixelSurface, gid: u16) ![]const []const cv.Point {
        if (self.glyph_cache.get(gid)) |hit| return hit;
        const out = try self.fnt.?.outline(self.a, gid);
        try self.glyph_cache.put(self.a, gid, out);
        return out;
    }

    /// Shape + buffer one label: glyphs advance left-to-right at `font_px`
    /// (CSS px; device scale applied here), anchored per halign/valign with
    /// MILLIMETRE offsets (S-52 LocalOffset, +y down), optional halo.
    fn pushText(self: *PixelSurface, text: []const u8, font_px_css: f32, halign: []const u8, valign: []const u8, ox_mm: f32, oy_mm: f32, color: cv.Color, haloed: bool, group: i64, anchor: cv.Point) !void {
        const f = &(self.fnt orelse return);
        const px = font_px_css * @as(f32, @floatCast(self.textDev()));
        if (px <= 1) return;
        const mm_px: f32 = @floatCast(sndfrm.SYMBOL_SCALE * 100.0 * self.textDev());

        // Shape: glyph ids + pen positions (+ the PDF 1000/em advances).
        var gids = std.ArrayList(cv.Glyph).empty;
        var pen: f32 = 0;
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            const gid = f.glyphIndex(cp);
            const adv = f.advance(gid);
            try gids.append(self.a, .{ .gid = gid, .cp = cp, .x = pen, .w1000 = @intFromFloat(std.math.clamp(@round(adv * 1000.0), 0, 65535)) });
            pen += adv * px;
        }
        if (gids.items.len == 0) return;

        const width = pen;
        var x0 = anchor.x + ox_mm * mm_px;
        if (std.mem.eql(u8, halign, "center")) x0 -= width / 2;
        if (std.mem.eql(u8, halign, "right")) x0 -= width;
        var baseline = anchor.y + oy_mm * mm_px;
        if (std.mem.eql(u8, valign, "top")) {
            baseline += f.ascent * px;
        } else if (std.mem.eql(u8, valign, "middle")) {
            baseline += (f.ascent - f.descent) / 2 * px;
        } else { // bottom (and the tile default)
            baseline -= f.descent * px;
        }

        var rings = std.ArrayList([]const cv.Point).empty;
        var bbox = [4]f32{ std.math.floatMax(f32), std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
        for (gids.items) |g| {
            const contours = try self.glyphOutline(g.gid);
            for (contours) |contour| {
                const pts = try self.a.alloc(cv.Point, contour.len);
                for (contour, 0..) |p, i| {
                    // em units, y up -> canvas px, y down.
                    pts[i] = .{ .x = x0 + g.x + p.x * px, .y = baseline - p.y * px };
                    bbox[0] = @min(bbox[0], pts[i].x);
                    bbox[1] = @min(bbox[1], pts[i].y);
                    bbox[2] = @max(bbox[2], pts[i].x);
                    bbox[3] = @max(bbox[3], pts[i].y);
                }
                try rings.append(self.a, pts);
            }
        }
        if (rings.items.len == 0) return;
        const halo_w = @as(f32, @floatCast(self.devScale())); // 1 CSS px
        try self.push(.text, .{ .text = .{
            .run = .{
                .rings = rings.items,
                .glyphs = try gids.toOwnedSlice(self.a),
                .origin = .{ .x = x0, .y = baseline },
                .size = px,
                .color = color,
                .halo = if (haloed) self.resolveColor("CHWHT") else null,
                .halo_w = halo_w,
                .text = try self.a.dupe(u8, text),
            },
            .bbox = .{ bbox[0] - halo_w, bbox[1] - halo_w, bbox[2] + halo_w, bbox[3] + halo_w },
            .group = group,
        } });
    }

    fn endFeature(_: *anyopaque) anyerror!void {}

    // Paint the sorted, decluttered op list onto any Canvas — the raster and
    // PDF outputs share this exactly (Gate 3's self-consistency by construction).
    fn paintOps(self: *PixelSurface, canvas: cv.Canvas, kept: *const dc.Kept) !void {
        for (self.ops.items) |op| switch (op.kind) {
            .fill => |f| try canvas.fillPath(f.rings, f.color, f.rule),
            .pattern => |p| try canvas.fillPattern(p.rings, p.cell),
            .stroke => |s| try canvas.strokePath(s.lines, s.width, s.dash, s.color),
            .text => |*t| {
                if (!kept.has(op.seq)) continue;
                try canvas.drawGlyphRun(&t.run);
            },
        };
    }

    // Paint the selection HIGHLIGHT (if any) over the finished chart: a ring +
    // crosshair reticle at the feature's anchor and, for a line/area, a dashed
    // box around its extent. A hi-vis amber core over a near-black halo so it
    // reads against any S-52 shade. Canvas-space; a no-op when unset, so every
    // ordinary render is untouched.
    fn drawHighlight(self: *PixelSurface, canvas: cv.Canvas) !void {
        const hl = self.highlight orelse return;
        const md: f32 = @floatFromInt(@min(self.w_px, self.h_px));
        const r = std.math.clamp(md * 0.055, 12.0, 64.0); // ring radius
        const gap = r * 0.42; // crosshair centre gap (the feature stays visible)
        const arm = r * 1.85; // crosshair half-length
        const core_w = std.math.clamp(md * 0.006, 1.5, 4.0);
        const halo_w = core_w + std.math.clamp(md * 0.005, 1.5, 3.5);

        // Reticle: a closed ring + four radial ticks (N/S/E/W).
        const N = 48;
        var ring: [N + 1]cv.Point = undefined;
        for (0..N + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f32, N));
            ring[i] = .{ .x = hl.cx + r * @cos(t), .y = hl.cy + r * @sin(t) };
        }
        const up = [_]cv.Point{ .{ .x = hl.cx, .y = hl.cy - gap }, .{ .x = hl.cx, .y = hl.cy - arm } };
        const dn = [_]cv.Point{ .{ .x = hl.cx, .y = hl.cy + gap }, .{ .x = hl.cx, .y = hl.cy + arm } };
        const lf = [_]cv.Point{ .{ .x = hl.cx - gap, .y = hl.cy }, .{ .x = hl.cx - arm, .y = hl.cy } };
        const rt = [_]cv.Point{ .{ .x = hl.cx + gap, .y = hl.cy }, .{ .x = hl.cx + arm, .y = hl.cy } };
        const reticle = [_][]const cv.Point{ &ring, &up, &dn, &lf, &rt };

        // Halo (wide, dark) first, bright core last so the core sits inside it.
        try canvas.strokePath(&reticle, halo_w, null, HL_HALO);

        // Line/area extent box (dashed), padded a hair outside the geometry.
        if (hl.bbox) |b| {
            const pad = r * 0.25;
            const box = [_]cv.Point{
                .{ .x = b[0] - pad, .y = b[1] - pad },
                .{ .x = b[2] + pad, .y = b[1] - pad },
                .{ .x = b[2] + pad, .y = b[3] + pad },
                .{ .x = b[0] - pad, .y = b[3] + pad },
                .{ .x = b[0] - pad, .y = b[1] - pad },
            };
            const boxlines = [_][]const cv.Point{&box};
            const dash = [2]f32{ 9.0 * core_w, 6.0 * core_w };
            try canvas.strokePath(&boxlines, halo_w, dash, HL_HALO);
            try canvas.strokePath(&boxlines, core_w, dash, HL_CORE);
        }
        try canvas.strokePath(&reticle, core_w, null, HL_CORE);
    }

    fn endScene(ctx: *anyopaque, out: Allocator) anyerror![]u8 {
        const self = sp(ctx);
        // Label declutter, through the shared pool (render/declutter.zig owns the
        // whole policy). Only text competes: symbols and soundings all draw, and
        // text is drawn last, over them. Candidates go in by EMISSION order — the
        // SENC sequence the pool settles peers by — never by paint order.
        var pool = dc.Pool{};
        defer pool.deinit(self.a);
        for (self.ops.items) |op| {
            if (op.kind != .text) continue;
            const b = op.kind.text.bbox;
            try pool.add(self.a, op.seq, op.kind.text.group, .{ .x0 = b[0], .y0 = b[1], .x1 = b[2], .y1 = b[3] });
        }
        var kept = try pool.resolve(self.a);
        defer kept.deinit(self.a);

        // Paint order = the tile style's layer stack: class-major (see
        // OpLayer), draw priority within a class, emission order for ties.
        std.mem.sort(Op, self.ops.items, {}, struct {
            fn lt(_: void, l: Op, r: Op) bool {
                if (l.layer != r.layer) return @intFromEnum(l.layer) < @intFromEnum(r.layer);
                if (l.prio != r.prio) return l.prio < r.prio;
                return l.seq < r.seq;
            }
        }.lt);

        switch (self.output) {
            .png => {
                var rc = try raster.RasterCanvas.init(self.a, self.w_px, self.h_px);
                defer rc.deinit();
                // NODTA under everything (S-52 no-data); the palette picks the shade.
                // The isolated-feature thumbnail overrides this via bg_token.
                rc.clear(self.resolveColor(self.bg_token orelse "NODTA"));
                try self.paintOps(rc.asCanvas(), &kept);
                try self.drawHighlight(rc.asCanvas());
                return png.encodeRgba(out, rc.px, rc.w, rc.h);
            },
            .pdf => {
                var pc = pdf.PdfCanvas.init(self.a, self.w_px, self.h_px);
                pc.font_data = fontmod.notosans; // labels become REAL text objects
                const canvas = pc.asCanvas();
                // NODTA page background.
                const bg = [_]cv.Point{
                    .{ .x = 0, .y = 0 },
                    .{ .x = @floatFromInt(self.w_px), .y = 0 },
                    .{ .x = @floatFromInt(self.w_px), .y = @floatFromInt(self.h_px) },
                    .{ .x = 0, .y = @floatFromInt(self.h_px) },
                };
                const bg_rings = [_][]const cv.Point{&bg};
                try canvas.fillPath(&bg_rings, self.resolveColor(self.bg_token orelse "NODTA"), .nonzero);
                try self.paintOps(canvas, &kept);
                try self.drawHighlight(canvas);
                return pc.finish(out);
            },
            .callback => {
                // Forward every resolved, flattened primitive to the C paint
                // table (pixel space, endScene paint order). No bytes returned.
                var cc = cb_canvas.CbCanvas.init(self.a, self.cb.?);
                const canvas = cc.asCanvas();
                // NODTA background as a full-canvas fill, first (base layer).
                const bg = [_]cv.Point{
                    .{ .x = 0, .y = 0 },
                    .{ .x = @floatFromInt(self.w_px), .y = 0 },
                    .{ .x = @floatFromInt(self.w_px), .y = @floatFromInt(self.h_px) },
                    .{ .x = 0, .y = @floatFromInt(self.h_px) },
                };
                const bg_rings = [_][]const cv.Point{&bg};
                try canvas.fillPath(&bg_rings, self.resolveColor(self.bg_token orelse "NODTA"), .nonzero);
                try self.paintOps(canvas, &kept);
                return out.alloc(u8, 0);
            },
        }
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
    const settings = resolve.Settings{};
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
    const settings = resolve.Settings{};
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
    // Stroke width scales with the device scale (64px canvas = 0.25x the 256
    // baseline): 2 CSS px -> 0.5 device px; dash [4w, 3w] follows.
    try std.testing.expectEqual(@as(f32, 0.5), op.width);
    try std.testing.expectEqual([2]f32{ 2, 1.5 }, op.dash.?);
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
    const settings = resolve.Settings{ .display_other = true };
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

test "drawText: shaping, group gate, halo, and collision declutter" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.Settings{};
    var ps = PixelSurface.init(a, &colors, .day, &settings, 14.0, 256, 256);
    const surf = ps.asSurface();

    // A named label (group 26, text_names on) at prio 9.
    const hi = rs.FeatureMeta{ .draw_prio = 9 };
    try surf.beginFeature(&hi);
    const style = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .halign = "left", .valign = "bottom", .offset_x = 0, .offset_y = 0, .group = 26 };
    try surf.drawText("Reef 12", &style, .{ .x = 100, .y = 100 });
    try surf.endFeature();
    try std.testing.expectEqual(@as(usize, 1), ps.ops.items.len);
    const t = ps.ops.items[0].kind.text;
    try std.testing.expect(t.run.rings.len >= 6); // R,e,e,f,1,2 (space has none)
    try std.testing.expect(t.run.glyphs.len == 7); // incl. the space glyph
    try std.testing.expect(t.run.halo == null); // S-52: solid text, no halo
    try std.testing.expect(t.bbox[2] > t.bbox[0] and t.bbox[3] > t.bbox[1]);
    try std.testing.expect(t.bbox[0] >= 99); // halign left: extends right of x=100

    // Same spot, same text group (both Other text): peers, so the SENC sequence
    // settles it and the label emitted FIRST keeps the space. The feature draw
    // priority is deliberately not consulted — see declutter.zig.
    const lo = rs.FeatureMeta{ .draw_prio = 3 };
    try surf.beginFeature(&lo);
    try surf.drawText("Overlap", &style, .{ .x = 102, .y = 101 });
    try surf.endFeature();
    // A light description with the toggle OFF: gated before buffering.
    const no_lights = resolve.Settings{ .show_light_descriptions = false };
    var ps2 = PixelSurface.init(a, &colors, .day, &no_lights, 14.0, 256, 256);
    const lstyle = rs.TextStyle{ .color = "CHBLK", .font_size = 11, .halign = "left", .valign = "bottom", .offset_x = 0, .offset_y = 0, .group = 23 };
    try ps2.asSurface().beginFeature(&hi);
    try ps2.asSurface().drawText("Fl R 4s", &lstyle, .{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(usize, 0), ps2.ops.items.len);

    const bytes = try surf.endScene(a);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, bytes[0..4]);
    // Both labels are BUFFERED (the collision set is internal to endScene, which
    // paints only the survivor — "Reef 12", the earlier peer). declutter.zig's
    // own tests pin the ranking; here we pin that text still buffers and paints.
    try std.testing.expectEqual(@as(usize, 2), ps.ops.items.len);
}

test "drawHighlight: reticle straddles the anchor, bbox adds a dashed box, hi-vis colours" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A recording Canvas: each strokePath call's colour, dash flag, and the
    // bounding box of every point it drew.
    const Rec = struct { color: cv.Color, dashed: bool, minx: f32, miny: f32, maxx: f32, maxy: f32 };
    const Fake = struct {
        recs: std.ArrayList(Rec),
        alloc: Allocator,
        const vt = cv.Canvas.VTable{ .fillPath = fillPath, .fillPattern = fillPattern, .strokePath = strokePath, .drawGlyphRun = drawGlyphRun };
        fn fillPath(_: *anyopaque, _: []const []const cv.Point, _: cv.Color, _: cv.FillRule) anyerror!void {}
        fn fillPattern(_: *anyopaque, _: []const []const cv.Point, _: *const cv.Pattern) anyerror!void {}
        fn drawGlyphRun(_: *anyopaque, _: *const cv.GlyphRun) anyerror!void {}
        fn strokePath(ctx: *anyopaque, lines: []const []const cv.Point, _: f32, dash: ?[2]f32, color: cv.Color) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var r = Rec{ .color = color, .dashed = dash != null, .minx = 1e9, .miny = 1e9, .maxx = -1e9, .maxy = -1e9 };
            for (lines) |ln| for (ln) |p| {
                r.minx = @min(r.minx, p.x);
                r.miny = @min(r.miny, p.y);
                r.maxx = @max(r.maxx, p.x);
                r.maxy = @max(r.maxy, p.y);
            };
            self.recs.append(self.alloc, r) catch {};
        }
    };

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.Settings{};
    var ps = PixelSurface.init(a, &colors, .day, &settings, 14.0, 400, 400);

    // POINT: reticle only (no dashed box). Both halo + core passes straddle the
    // anchor at (200,200).
    var fake = Fake{ .recs = .empty, .alloc = a };
    ps.highlight = .{ .cx = 200, .cy = 200 };
    try ps.drawHighlight(.{ .ptr = &fake, .vtable = &Fake.vt });
    var saw_core = false;
    var saw_halo = false;
    var saw_dash = false;
    try std.testing.expect(fake.recs.items.len >= 2);
    for (fake.recs.items) |r| {
        if (std.meta.eql(r.color, HL_CORE)) saw_core = true;
        if (std.meta.eql(r.color, HL_HALO)) saw_halo = true;
        if (r.dashed) saw_dash = true;
        try std.testing.expect(r.minx < 200 and r.maxx > 200 and r.miny < 200 and r.maxy > 200);
    }
    try std.testing.expect(saw_core and saw_halo and !saw_dash);

    // LINE/AREA: the bbox adds a dashed extent box in the core colour.
    var fake2 = Fake{ .recs = .empty, .alloc = a };
    ps.highlight = .{ .cx = 200, .cy = 200, .bbox = .{ 120, 140, 280, 260 } };
    try ps.drawHighlight(.{ .ptr = &fake2, .vtable = &Fake.vt });
    var dashed_box = false;
    for (fake2.recs.items) |r| {
        if (r.dashed and std.meta.eql(r.color, HL_CORE)) dashed_box = true;
    }
    try std.testing.expect(dashed_box);
}
