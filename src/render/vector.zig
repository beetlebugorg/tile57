//! VectorSurface — the Surface implementation for GPU vector embedders.
//!
//! The sibling of PixelSurface: it RESOLVES the same S-52 semantics (token->RGBA,
//! symbol name->outline, text->glyph outlines, the non-SCAMIN display gates) but,
//! instead of baking everything into one pixel frame, emits a WORLD-SPACE tagged
//! stream to a C callback so a GPU host can transform geometry and pin symbols/
//! text at a constant screen size — no re-portrayal per pan/zoom.
//!
//! Differences from PixelSurface, and why:
//!   * Area/line geometry is emitted in web-mercator WORLD coords ([0,1], y down)
//!     — the host applies its own view transform each frame. Needs the tile
//!     (z,x,y) to unproject tile-space; set via setTile before each tile.
//!   * Point symbols and text are emitted as a WORLD anchor + a LOCAL outline in
//!     reference px (device scale fixed at 1x, NOT the view's px_per_tile) — so
//!     the host draws them at a fixed screen size at the projected anchor.
//!   * SCAMIN is NOT gated here; it is passed through per feature so the host can
//!     cull per frame. Category / viewing-group / text-group / point / boundary
//!     gates DO apply (they track mariner settings, not zoom). We evaluate the
//!     combined gate at a high zoom so only SCAMIN is neutralised.
//!   * No op buffer / sort / declutter: the host owns paint order (draw calls
//!     arrive in Surface emission order) and label collision.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("surface.zig");
const resolve = @import("resolve.zig");
const cv = @import("canvas.zig");
const sym = @import("symbols.zig");
const sndfrm = @import("sndfrm.zig");
const fontmod = @import("font.zig");
const tile = @import("tiles").tile;

const FALLBACK = cv.Color{ .r = 255, .g = 0, .b = 255 };
const DASH_ON = 4.0;
const DASH_OFF = 3.0;
/// The zoom the display gates evaluate at — high enough that SCAMIN never gates
/// (log2(DENOM_Z0/scamin) < 28 for any scamin >= 1), so every feature is emitted
/// and the host culls by the per-feature scamin we pass through.
const GATE_ZOOM = 30.0;

// ---- extern C ABI (mirrored in include/tile57.h) ---------------------------
pub const CWorldPt = extern struct { x: f64, y: f64 }; // web-mercator [0,1], y down
pub const CLocalPt = extern struct { x: f32, y: f32 }; // anchor-relative reference px
pub const CColor = extern struct { r: u8, g: u8, b: u8, a: u8 };

/// Multi-ring path in world space (same layout as CRings but f64 world pts).
pub const CWorldRings = extern struct {
    pts: [*]const CWorldPt,
    n: u32,
    ring_starts: [*]const u32,
    ring_count: u32,
};
/// Multi-ring path in anchor-local reference px (symbols/text shapes).
pub const CLocalRings = extern struct {
    pts: [*]const CLocalPt,
    n: u32,
    ring_starts: [*]const u32,
    ring_count: u32,
};

/// The feature the following draw calls belong to. `cls` is the S-57 object-class
/// acronym (NUL-terminated, "" if none); `scamin` is the SCAMIN 1:N denominator
/// (<=0 => always visible); `plane` is the S-52 draw priority (paint-order hint).
pub const CFeature = extern struct {
    cls: [*:0]const u8,
    scamin: i64,
    plane: i32,
};

/// The GPU paint table. Every call gets `ctx` back verbatim; pointers are valid
/// only for the duration of the call. Area/line geometry is world-space; symbol/
/// text shapes are anchor-local reference px at a world anchor.
pub const CSurface = extern struct {
    ctx: ?*anyopaque,
    /// Filled area (world). even_odd != 0 selects the even-odd rule.
    fill_area: *const fn (?*anyopaque, *const CFeature, *const CWorldRings, CColor, c_int) callconv(.c) void,
    /// Stroked line (world), width in reference px; dash on/off px (0,0 = solid).
    stroke_line: *const fn (?*anyopaque, *const CFeature, *const CWorldRings, f32, f32, f32, CColor) callconv(.c) void,
    /// Point symbol: world anchor + local outline (px). even_odd for compound
    /// glyphs; stroke_w > 0 means the rings are a polyline stroked that px wide.
    draw_symbol: *const fn (?*anyopaque, *const CFeature, CWorldPt, *const CLocalRings, CColor, c_int, f32) callconv(.c) void,
    /// Text label: world anchor + local glyph outlines (px, even-odd) + halo
    /// (halo.a == 0 => none).
    draw_text: *const fn (?*anyopaque, *const CFeature, CWorldPt, *const CLocalRings, CColor, CColor, f32) callconv(.c) void,
};

// ---- the Surface implementation --------------------------------------------
pub const VectorSurface = struct {
    a: Allocator,
    colors: *const resolve.Colors,
    palette: resolve.PaletteId,
    settings: *const resolve.MarinerSettings,
    cb: *const CSurface,
    store: ?sym.SymbolStore = null,
    fnt: ?fontmod.Font = null,
    glyph_cache: std.AutoHashMapUnmanaged(u16, []const []const cv.Point) = .empty,

    /// Current tile (set before replaying each tile) for tile-space -> world.
    tz: u8 = 0,
    tx: u32 = 0,
    ty: u32 = 0,

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

    pub fn init(a: Allocator, colors: *const resolve.Colors, palette: resolve.PaletteId, settings: *const resolve.MarinerSettings, cb: *const CSurface) VectorSurface {
        return .{
            .a = a,
            .colors = colors,
            .palette = palette,
            .settings = settings,
            .cb = cb,
            .fnt = fontmod.Font.init(fontmod.notosans) catch null,
        };
    }

    pub fn asSurface(self: *VectorSurface) rs.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn setTile(self: *VectorSurface, z: u8, x: u32, y: u32) void {
        self.tz = z;
        self.tx = x;
        self.ty = y;
    }

    fn sp(ctx: *anyopaque) *VectorSurface {
        return @ptrCast(@alignCast(ctx));
    }

    fn ccolor(c: cv.Color) CColor {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }

    fn resolveColor(self: *const VectorSurface, token: []const u8) cv.Color {
        const rgb = self.colors.get(self.palette, token) orelse return FALLBACK;
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }

    /// Reference device scale: physical multiplier only (px_per_tile fixed at the
    /// 256 baseline), so symbol/text px are a constant screen size.
    fn refDev(self: *const VectorSurface) f64 {
        return self.settings.size_scale;
    }

    /// Tile-space point -> web-mercator world [0,1] (y down).
    fn worldOf(self: *const VectorSurface, p: rs.TilePoint) CWorldPt {
        const n = std.math.pow(f64, 2.0, @floatFromInt(self.tz));
        const e: f64 = @floatFromInt(tile.EXTENT);
        return .{
            .x = (@as(f64, @floatFromInt(self.tx)) + @as(f64, @floatFromInt(p.x)) / e) / n,
            .y = (@as(f64, @floatFromInt(self.ty)) + @as(f64, @floatFromInt(p.y)) / e) / n,
        };
    }

    fn cur_feature(self: *const VectorSurface) CFeature {
        // cur.class is a Zig slice; it is NUL-terminated in the meta (acronyms are
        // static strings), but guard by duping a sentinel-terminated copy.
        const cls = self.a.dupeZ(u8, self.cur.class) catch @as([:0]u8, @constCast(""));
        return .{ .cls = cls.ptr, .scamin = self.cur.scamin orelse 0, .plane = @intCast(self.cur.draw_prio) };
    }

    // Flatten tile rings -> world CWorldRings (arena; valid for the call).
    fn worldRings(self: *VectorSurface, parts: []const []const rs.TilePoint) !CWorldRings {
        var total: usize = 0;
        for (parts) |p| total += p.len;
        const pts = try self.a.alloc(CWorldPt, total);
        const starts = try self.a.alloc(u32, parts.len);
        var i: usize = 0;
        for (parts, 0..) |part, k| {
            starts[k] = @intCast(i);
            for (part) |p| {
                pts[i] = self.worldOf(p);
                i += 1;
            }
        }
        return .{ .pts = pts.ptr, .n = @intCast(total), .ring_starts = starts.ptr, .ring_count = @intCast(parts.len) };
    }

    fn localRings(self: *VectorSurface, parts: []const []const cv.Point) !CLocalRings {
        var total: usize = 0;
        for (parts) |p| total += p.len;
        const pts = try self.a.alloc(CLocalPt, total);
        const starts = try self.a.alloc(u32, parts.len);
        var i: usize = 0;
        for (parts, 0..) |part, k| {
            starts[k] = @intCast(i);
            for (part) |p| {
                pts[i] = .{ .x = p.x, .y = p.y };
                i += 1;
            }
        }
        return .{ .pts = pts.ptr, .n = @intCast(total), .ring_starts = starts.ptr, .ring_count = @intCast(parts.len) };
    }

    // ---- Surface impl ---------------------------------------------------------
    fn beginScene(_: *anyopaque, _: u8) anyerror!void {}
    fn endFeature(_: *anyopaque) anyerror!void {}
    fn endScene(_: *anyopaque, out: Allocator) anyerror![]u8 {
        return out.alloc(u8, 0);
    }

    fn beginFeature(ctx: *anyopaque, meta: *const rs.FeatureMeta) anyerror!void {
        const self = sp(ctx);
        self.cur = meta.*;
        // Everything but SCAMIN: evaluate at GATE_ZOOM so SCAMIN always passes.
        self.cur_visible = resolve.visible(meta, null, GATE_ZOOM, self.settings);
    }

    fn fillArea(ctx: *anyopaque, token: rs.ColorToken, rings: []const []const rs.TilePoint, depth: ?rs.DepthRange) anyerror!void {
        _ = depth;
        const self = sp(ctx);
        if (!self.cur_visible) return;
        const feat = self.cur_feature();
        var wr = try self.worldRings(rings);
        self.cb.fill_area(self.cb.ctx, &feat, &wr, ccolor(self.resolveColor(token)), 0);
    }

    fn fillPattern(ctx: *anyopaque, name: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        _ = name;
        const self = sp(ctx);
        if (!self.cur_visible) return;
        // v1: approximate the S-101 area pattern as a flat translucent tint (the
        // host has no pattern raster). A dedicated pattern channel can follow.
        const feat = self.cur_feature();
        var wr = try self.worldRings(rings);
        self.cb.fill_area(self.cb.ctx, &feat, &wr, .{ .r = 160, .g = 160, .b = 170, .a = 140 }, 0);
    }

    fn strokeLine(ctx: *anyopaque, token: rs.ColorToken, width_px: f64, dash: rs.Dash, lines: []const []const rs.TilePoint, valdco: ?f64) anyerror!void {
        _ = valdco; // depth-contour value labels: host-side follow-up
        const self = sp(ctx);
        if (!self.cur_visible) return;
        const w: f32 = @floatCast(width_px * self.refDev());
        const on: f32, const off: f32 = switch (dash) {
            .solid => .{ 0, 0 },
            .dashed => .{ DASH_ON * w, DASH_OFF * w },
        };
        const feat = self.cur_feature();
        var wr = try self.worldRings(lines);
        self.cb.stroke_line(self.cb.ctx, &feat, &wr, w, on, off, ccolor(self.resolveColor(token)));
    }

    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: rs.SymbolPlacement, danger_depth: ?f64) anyerror!void {
        _ = rot_north;
        _ = placement;
        const self = sp(ctx);
        const store = self.store orelse return;
        if (!resolve.visible(&self.cur, name, GATE_ZOOM, self.settings)) return;
        // The style path gates INFORM01 information callouts behind
        // show_inform_callouts (chartstyle.zig); the live Surface path bypasses
        // the style, so mirror that toggle here.
        if (!self.settings.show_inform_callouts and std.mem.eql(u8, name, "INFORM01")) return;
        var eff = name;
        if (danger_depth) |dd| eff = if (dd > self.settings.safety_contour) "DANGER02" else "DANGER01";
        const s = store.get(eff) orelse return;
        try self.emitSymbol(s, at, rot_deg, scale);
    }

    fn drawSounding(ctx: *anyopaque, depth_m: f64, swept: bool, low_acc: bool, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        const store = self.store orelse return;
        if (!resolve.visible(&self.cur, null, GATE_ZOOM, self.settings)) return;
        const feet = self.settings.depth_unit == .feet;
        const shown = if (feet) depth_m * sndfrm.M_TO_FT else depth_m;
        const prefix: []const u8 = if (depth_m <= self.settings.safety_depth) "SOUNDS" else "SOUNDG";
        const list = try sndfrm.syms(self.a, prefix, shown, swept, low_acc, feet);
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |glyph| {
            if (glyph.len == 0) continue;
            if (store.get(glyph)) |s| try self.emitSymbol(s, at, 0, sndfrm.SYMBOL_SCALE);
        }
    }

    /// Emit one symbol: world anchor + each path's outline in anchor-local
    /// reference px (pivot-relative, scaled, rotated). Constant screen size.
    fn emitSymbol(self: *VectorSurface, s: *const sym.Symbol, at: rs.TilePoint, rot_deg: f64, scale: f64) !void {
        const anchor = self.worldOf(at);
        const feat = self.cur_feature();
        const k: f32 = @floatCast(scale * 100.0 * self.refDev());
        const rad: f32 = @floatCast(rot_deg * std.math.pi / 180.0);
        const cosr = @cos(rad);
        const sinr = @sin(rad);
        for (s.paths) |p| {
            const rings = try self.a.alloc([]const cv.Point, p.contours.len);
            for (p.contours, 0..) |contour, i| {
                const pts = try self.a.alloc(cv.Point, contour.len);
                for (contour, 0..) |c, j| {
                    const lx = (c.x - s.pivot.x) * k;
                    const ly = (c.y - s.pivot.y) * k;
                    pts[j] = .{ .x = lx * cosr - ly * sinr, .y = lx * sinr + ly * cosr };
                }
                rings[i] = pts;
            }
            var lr = try self.localRings(rings);
            if (p.fill) |color| self.cb.draw_symbol(self.cb.ctx, &feat, anchor, &lr, ccolor(color), 1, 0);
            if (p.stroke) |st| self.cb.draw_symbol(self.cb.ctx, &feat, anchor, &lr, ccolor(st.color), 0, st.width * k);
        }
    }

    fn drawText(ctx: *anyopaque, text: []const u8, style: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (!self.cur_visible) return;
        if (!resolve.textGroupVisible(style.group, self.settings)) return;
        const font_css: f32 = @floatCast(if (style.font_size > 0) style.font_size else 12);
        try self.emitText(text, font_css, if (style.halign.len > 0) style.halign else "center", if (style.valign.len > 0) style.valign else "middle", @floatCast(style.offset_x), @floatCast(style.offset_y), self.resolveColor(style.color), at);
    }

    fn glyphOutline(self: *VectorSurface, gid: u16) ![]const []const cv.Point {
        if (self.glyph_cache.get(gid)) |hit| return hit;
        const out = try self.fnt.?.outline(self.a, gid);
        try self.glyph_cache.put(self.a, gid, out);
        return out;
    }

    /// Shape a label into anchor-local reference px glyph outlines (baseline at
    /// the origin, aligned per halign/valign with mm offsets) at a world anchor.
    fn emitText(self: *VectorSurface, text: []const u8, font_css: f32, halign: []const u8, valign: []const u8, ox_mm: f32, oy_mm: f32, color: cv.Color, at: rs.TilePoint) !void {
        const f = &(self.fnt orelse return);
        const px = font_css * @as(f32, @floatCast(self.refDev()));
        if (px <= 1) return;
        const mm_px: f32 = @floatCast(sndfrm.SYMBOL_SCALE * 100.0 * self.refDev());

        var gids = std.ArrayList(struct { gid: u16, x: f32 }).empty;
        var pen: f32 = 0;
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            const gid = f.glyphIndex(cp);
            try gids.append(self.a, .{ .gid = gid, .x = pen });
            pen += f.advance(gid) * px;
        }
        if (gids.items.len == 0) return;

        var x0: f32 = ox_mm * mm_px;
        if (std.mem.eql(u8, halign, "center")) x0 -= pen / 2;
        if (std.mem.eql(u8, halign, "right")) x0 -= pen;
        var baseline: f32 = oy_mm * mm_px;
        if (std.mem.eql(u8, valign, "top")) {
            baseline += f.ascent * px;
        } else if (std.mem.eql(u8, valign, "middle")) {
            baseline += (f.ascent - f.descent) / 2 * px;
        } else {
            baseline -= f.descent * px;
        }

        var rings = std.ArrayList([]const cv.Point).empty;
        for (gids.items) |g| {
            const contours = try self.glyphOutline(g.gid);
            for (contours) |contour| {
                const pts = try self.a.alloc(cv.Point, contour.len);
                for (contour, 0..) |p, i| {
                    // em units, y up -> local px, y down (anchor-relative).
                    pts[i] = .{ .x = x0 + g.x + p.x * px, .y = baseline - p.y * px };
                }
                try rings.append(self.a, pts);
            }
        }
        if (rings.items.len == 0) return;
        const feat = self.cur_feature();
        var lr = try self.localRings(rings.items);
        self.cb.draw_text(self.cb.ctx, &feat, self.worldOf(at), &lr, ccolor(color), .{ .r = 0, .g = 0, .b = 0, .a = 0 }, 0);
    }
};
