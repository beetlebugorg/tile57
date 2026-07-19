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
//!   * No op buffer / sort: the host owns paint order (draw calls arrive in
//!     Surface emission order). Labels are the ONE exception — they are held
//!     back and resolved against the shared collision pool at endScene, because
//!     which label survives cannot be known until the whole scene is walked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("surface.zig");
const resolve = @import("resolve.zig");
const cv = @import("canvas.zig");
const sym = @import("symbols.zig");
const sndfrm = @import("sndfrm.zig");
const dc = @import("declutter.zig");
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
/// Packed 0xRRGGBBAA. A SCALAR, not a struct — see tile57_color in tile57.h:
/// a small extern struct by value across callconv(.c) is miscompiled by zig
/// 0.16 on aarch64 in every optimized mode.
pub const CColor = u32;

/// cv.Color -> packed 0xRRGGBBAA.
pub fn packColor(c: cv.Color) CColor {
    return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | @as(u32, c.a);
}

/// What a rotatable draw call's rotation is referenced to (MapLibre's
/// rotation-alignment). `.viewport`: SCREEN-relative — the host leaves the mark
/// upright under a rotated view. `.map`: CHART-relative (north / a line tangent)
/// — the host ADDS its view rotation so the mark turns with the chart. This is
/// the engine's `rot_north`.
pub const CRotAlign = enum(c_int) { viewport = 0, map = 1 };

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

/// The S-52 display category — the axis the mariner's display_base /
/// display_standard / display_other settings select on. Display base is the
/// never-hide set: SCAMIN is not applied to it.
pub const CDispCat = enum(c_int) { base = 0, standard = 1, other = 2 };

/// The feature the following draw calls belong to. `cls` is the S-57 object-class
/// acronym (NUL-terminated, "" if none); `scamin` is the SCAMIN 1:N denominator
/// (<=0 => always visible); `plane` is the S-52 draw priority (paint-order hint);
/// `disp_cat` is the display category the feature came in on — a host applying
/// SCAMIN itself must skip it for `.base`.
pub const CFeature = extern struct {
    cls: [*:0]const u8,
    scamin: i64,
    plane: i32,
    disp_cat: CDispCat,
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
    /// The outline is already rotated; `align` says whether the host additionally
    /// rotates it by the view rotation (.map) or leaves it upright (.viewport).
    draw_symbol: *const fn (?*anyopaque, *const CFeature, CWorldPt, *const CLocalRings, CColor, c_int, f32, CRotAlign) callconv(.c) void,
    /// Text label: world anchor + local glyph outlines (px, even-odd) + halo
    /// (halo.a == 0 => none). The glyphs are already rotated; `align` says whether
    /// the host additionally rotates by the view rotation (.map = follow the
    /// chart, e.g. a contour value) or leaves the label upright (.viewport).
    draw_text: *const fn (?*anyopaque, *const CFeature, CWorldPt, *const CLocalRings, CColor, CColor, f32, CRotAlign) callconv(.c) void,
    /// Point symbol as a sprite: name (ptr,len) to look up in the atlas, world
    /// anchor, rotation (deg), the rotation alignment (.map => host adds the view
    /// rotation), and the symbol's un-rotated half-extent in reference px (draw
    /// the atlas cell as a quad of that half-size, centred on the anchor). Null =>
    /// symbols tessellate via draw_symbol instead.
    draw_sprite: ?*const fn (?*anyopaque, *const CFeature, [*]const u8, usize, CWorldPt, f32, CRotAlign, f32, f32) callconv(.c) void = null,
    /// Area fill pattern: pattern name (ptr,len) to look up in the atlas ("pat:"
    /// prefix) + the fill rings (world). Tile the pattern cell across the polygon
    /// at a constant screen size. Null => patterns fall back to a flat tint.
    draw_pattern: ?*const fn (?*anyopaque, *const CFeature, [*]const u8, usize, *const CWorldRings) callconv(.c) void = null,
    /// Text label as a STRING for the host's SDF glyph atlas: world anchor + the
    /// anchor-relative baseline-left origin in px (ox,oy, alignment already applied)
    /// + UTF-8 text (ptr,len) + the glyph pixel size + the run rotation (deg) + its
    /// alignment (.map => host adds the view rotation) + colour + halo. The host
    /// lays the string out from its glyph metrics and draws SDF quads. Null => text
    /// tessellates via draw_text instead. Must be the LAST field (ABI-appended).
    draw_text_str: ?*const fn (?*anyopaque, *const CFeature, CWorldPt, f32, f32, [*]const u8, usize, f32, f32, CRotAlign, CColor, CColor) callconv(.c) void = null,
};

/// One label held back from the stream until endScene. Text is the only thing
/// that competes for space (declutter.zig documents why), and a label can only
/// be ranked against the others once the whole scene has been walked — so it is
/// SHAPED here and emitted only if it survives. Everything else (areas, lines,
/// symbols, soundings) streams to the host as it is drawn.
const Label = struct {
    feat: CFeature,
    anchor: CWorldPt,
    text: []const u8,
    px: f32, // glyph size, device px
    x0: f32, // anchor-local baseline origin (alignment + LocalOffset applied)
    baseline: f32,
    color: cv.Color,
    rot_deg: f64,
    rot_align: CRotAlign,
};

/// A label BEFORE the view is known: everything about it the TILE decides, and
/// nothing the VIEW does. This is the unit the per-tile label memo stores
/// (labelcache.zig) — shaping (glyph px, advance width, the aligned baseline
/// origin), the world anchor, the resolved colour, and the pool's ranking
/// inputs, all of which depend only on the tile's portrayal at the mariner's
/// settings and palette.
///
/// Exactly three things about a label are view-dependent, and all three derive
/// per call in `pushCandidate` rather than being stored: the screen-frame
/// collision box (view zoom + rotation), the depth-contour legibility gate
/// (view zoom), and the upside-down flip on a tangent-rotated run (view
/// rotation). That split is what lets a pan or a zoom re-resolve the SAME
/// candidates instead of re-portraying the tiles.
pub const Candidate = struct {
    /// NUL-terminated so CFeature can point straight at it — the candidate's
    /// storage outlives the call that emits it.
    cls: [:0]const u8,
    scamin: i64,
    plane: i32,
    disp_cat: CDispCat,
    anchor: CWorldPt,
    text: []const u8,
    px: f32, // glyph size, device px
    pen: f32, // shaped advance width, device px (the box's length)
    x0: f32, // anchor-local baseline origin (alignment + LocalOffset applied)
    baseline: f32,
    color: cv.Color,
    /// The S-52 text group the pool ranks on.
    group: i64,
    /// The run's own angle, radians (a contour's tangent; 0 for plain text).
    rot_rad: f64,
    rot_align: CRotAlign,
    /// Flip the run 180° when the view rotation would otherwise leave it
    /// reading upside down. Only a tangent-rotated (MAP-aligned) run does.
    upright: bool = false,
    /// The on-screen legibility gate's carrier length, in WORLD units: the
    /// label is dropped when `len × 256·2^zoom` falls below LEGIBLE_PX at the
    /// view zoom. 0 = no gate (an ordinary label always places).
    gate_world_len: f64 = 0,
};

/// Below this many screen px a depth contour's visible piece is too short to
/// carry a legible value (S-52 SAFCON01 placement, mirrored from pixel.zig).
const LEGIBLE_PX: f64 = 10;

/// Where a labels-only walk PARKS its candidates instead of resolving them: the
/// driver hands the surface one of these per tile, backed by that tile's cache
/// arena, so the shaped labels outlive the render and can be re-resolved at the
/// next view. Candidates park in walk order — the order the pool's tie-break
/// (the SENC sequence) rides on — so replaying them reproduces it exactly.
pub const Capture = struct {
    a: Allocator,
    list: std.ArrayListUnmanaged(Candidate) = .empty,
};

// ---- the Surface implementation --------------------------------------------
pub const VectorSurface = struct {
    a: Allocator,
    colors: *const resolve.Colors,
    palette: resolve.PaletteId,
    settings: *const resolve.Settings,
    cb: *const CSurface,
    store: ?sym.SymbolStore = null,
    fnt: ?fontmod.Font = null,
    glyph_cache: std.AutoHashMapUnmanaged(u16, []const []const cv.Point) = .empty,

    /// Current tile (set before replaying each tile) for tile-space -> world.
    tz: u8 = 0,
    tx: u32 = 0,
    ty: u32 = 0,
    // 1/2^tz and 1/(2^tz·EXTENT), set by setTile — worldOf runs per VERTEX, and
    // recomputing pow(2,tz) there was ~9% of a whole view render.
    inv_n: f64 = 1.0,
    inv_ne: f64 = 1.0,

    cur: rs.FeatureMeta = .{},
    cur_visible: bool = true,

    /// Portray zoom (set by the driver) — the scale at which labels/symbols are
    /// decluttered, and the shared occupancy grid.
    view_zoom: f64 = 0,
    /// View rotation (radians CW; 0 = north-up), set by the whole-view driver.
    /// The host applies it to the GPU transform; the surface needs it for two
    /// view-dependent decisions only — the upside-down flip on tangent-rotated
    /// (MAP-aligned) contour labels, and decluttering labels in the SCREEN frame
    /// the host actually draws them in. The per-tile path leaves it 0 (a tile is
    /// tessellated once, north-up, and re-transformed on the GPU every frame).
    view_rotation: f64 = 0,
    /// Labels-only mode (the view-level text pass): shape and declutter TEXT, but
    /// emit no area/line/symbol/sounding geometry — a host draws those from its own
    /// per-tile cache and takes only the globally-decluttered text from this walk.
    /// Set by the driver; the collision pool, holdLabel and endScene are untouched,
    /// so the survivors are exactly the ones the full surface view would emit.
    labels_only: bool = false,
    /// Capture mode (labels-only): PARK each shaped label as a view-independent
    /// Candidate here instead of adding it to the pool. Set by the driver around
    /// the portrayal of a tile whose candidates are not memoized yet; cleared
    /// again before the driver replays candidates through `pushCandidate`.
    capture: ?*Capture = null,
    pool: dc.Pool = .{},
    labels: std.ArrayListUnmanaged(Label) = .empty,

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
        // Render surface: the engine walks complex-linestyle periods at this scale.
        // (No store_complex_run — this surface WALKS/renders runs, never stores.)
        .size_scale = sizeScale,
    };

    pub fn init(a: Allocator, colors: *const resolve.Colors, palette: resolve.PaletteId, settings: *const resolve.Settings, cb: *const CSurface) VectorSurface {
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
        self.inv_n = 1.0 / std.math.exp2(@as(f64, @floatFromInt(z)));
        self.inv_ne = self.inv_n / @as(f64, @floatFromInt(tile.EXTENT));
    }

    fn sp(ctx: *anyopaque) *VectorSurface {
        return @ptrCast(@alignCast(ctx));
    }

    fn ccolor(c: cv.Color) CColor {
        return packColor(c);
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

    /// refDev with the mariner's extra TEXT multiplier folded in — the one scale
    /// that sizes a label AND (via px/pen) its declutter box, so enlarged labels
    /// still collide correctly (mariner.text_size_scale, 1.0 = none).
    fn textDev(self: *const VectorSurface) f64 {
        return self.refDev() * self.settings.text_size_scale;
    }
    /// refDev with the mariner's extra SOUNDING multiplier folded in — sizes each
    /// sounding digit AND its pivot-baked spacing together, so a 3-digit sounding
    /// grows without colliding with itself (mariner.sounding_size_scale, 1.0 = none).
    fn soundingDev(self: *const VectorSurface) f64 {
        return self.refDev() * self.settings.sounding_size_scale;
    }

    /// Surface contract: this render surface's display scale (settings.size_scale).
    /// The engine reads it to walk complex-linestyle periods display-scaled so a
    /// HiDPI display gets both wider spacing AND bigger bricks (baked tiles native).
    fn sizeScale(ctx: *anyopaque) f64 {
        return sp(ctx).refDev();
    }

    /// Tile-space point -> web-mercator world [0,1] (y down). Per-vertex hot
    /// path: the tile factors are precomputed in setTile.
    fn worldOf(self: *const VectorSurface, p: rs.TilePoint) CWorldPt {
        return .{
            .x = @as(f64, @floatFromInt(self.tx)) * self.inv_n + @as(f64, @floatFromInt(p.x)) * self.inv_ne,
            .y = @as(f64, @floatFromInt(self.ty)) * self.inv_n + @as(f64, @floatFromInt(p.y)) * self.inv_ne,
        };
    }

    /// A symbol's rotation alignment: chart-relative (`.map`) when the rule asked
    /// for north-referenced rotation (ORIENT symbols, all linestyle bricks), else
    /// screen-upright (`.viewport`, the common navaid). Mirrors the style path's
    /// icon-rotation-alignment switch on `rot_north`.
    fn alignOf(rot_north: bool) CRotAlign {
        return if (rot_north) .map else .viewport;
    }

    /// A world anchor's position in the world-pixel grid the declutter uses,
    /// rotated into the SCREEN frame the host draws labels in. Under a rotated
    /// view the upright label boxes live in screen space, so collision must be
    /// tested there; rotating every centre about the origin by the view rotation
    /// is a rigid transform that puts them in that frame (north-up => identity).
    fn screenPx(self: *const VectorSurface, anchor: CWorldPt) [2]f64 {
        const scale_px = 256.0 * std.math.exp2(self.view_zoom);
        const wx = anchor.x * scale_px;
        const wy = anchor.y * scale_px;
        if (self.view_rotation == 0) return .{ wx, wy };
        const c = @cos(self.view_rotation);
        const s = @sin(self.view_rotation);
        return .{ wx * c - wy * s, wx * s + wy * c };
    }

    /// Normalise a CHART-relative run angle so tangent-rotated text never renders
    /// upside down: if the run, once the host adds the view rotation, would point
    /// into the left half-plane of the SCREEN, flip it 180°. Radians in and out.
    fn uprightTangent(self: *const VectorSurface, tangent_rad: f64) f64 {
        return if (@cos(tangent_rad + self.view_rotation) < 0) tangent_rad + std.math.pi else tangent_rad;
    }

    fn cur_feature(self: *const VectorSurface) CFeature {
        // cur.class is a Zig slice; it is NUL-terminated in the meta (acronyms are
        // static strings), but guard by duping a sentinel-terminated copy.
        const cls = self.a.dupeZ(u8, self.cur.class) catch @as([:0]u8, @constCast(""));
        return .{
            .cls = cls.ptr,
            .scamin = self.cur.scamin orelse 0,
            .plane = @intCast(self.cur.draw_prio),
            // Standard is the default for an unbanded feature (the baker's `cat < 0`
            // fallback, and the style's coalesce) — any other value is already
            // filtered out upstream by resolve.categoryVisible.
            .disp_cat = switch (self.cur.cat) {
                0 => .base,
                2 => .other,
                else => .standard,
            },
        };
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
    fn beginScene(ctx: *anyopaque, _: u8) anyerror!void {
        const self = sp(ctx);
        self.pool.deinit(self.a);
        self.pool = .{};
        self.labels.clearRetainingCapacity();
    }
    fn endFeature(_: *anyopaque) anyerror!void {}

    /// The scene is walked; now the labels can be ranked. Resolve the pool and
    /// emit the survivors — text last, over the symbols and soundings that
    /// streamed out ahead of it.
    fn endScene(ctx: *anyopaque, out: Allocator) anyerror![]u8 {
        const self = sp(ctx);
        // Boxes are screen px at the view zoom, so the pixel spacing applies as-is.
        var kept = try self.pool.resolve(self.a, dc.REPEAT_PX * self.refDev());
        defer kept.deinit(self.a);
        for (self.labels.items, 0..) |l, id| {
            if (kept.has(id)) try self.emitLabel(l);
        }
        return out.alloc(u8, 0);
    }

    fn beginFeature(ctx: *anyopaque, meta: *const rs.FeatureMeta) anyerror!void {
        const self = sp(ctx);
        self.cur = meta.*;
        // Everything but SCAMIN: evaluate at GATE_ZOOM so SCAMIN always passes.
        self.cur_visible = resolve.visible(meta, null, GATE_ZOOM, self.settings);
    }

    fn fillArea(ctx: *anyopaque, token: rs.ColorToken, rings: []const []const rs.TilePoint, depth: ?rs.DepthRange) anyerror!void {
        const self = sp(ctx);
        if (self.labels_only) return; // areas carry no label; skip the tessellation
        if (!self.cur_visible) return;
        const feat = self.cur_feature();
        var wr = try self.worldRings(rings);
        // ColorFill "NAME[,transparency]": apply the S-101 fill transparency (alpha).
        const ft = rs.fillToken(token);
        // A depth area re-shades LIVE against the mariner's contours (SEABED01) — the
        // baked token carries the bake context's contours, not this mariner's. Keep the
        // baked transparency: the swap is of the colour, not of the fill's opacity.
        const name = if (depth) |d| resolve.seabedToken(d, self.settings) else ft.name;
        var col = self.resolveColor(name);
        col.a = ft.alpha;
        self.cb.fill_area(self.cb.ctx, &feat, &wr, ccolor(col), 0);
    }

    fn fillPattern(ctx: *anyopaque, name: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.labels_only) return; // no label; skip the pattern fill
        if (!self.cur_visible) return;
        const feat = self.cur_feature();
        var wr = try self.worldRings(rings);
        // Tile the real S-101 pattern cell when the host supports it; else fall
        // back to a flat translucent tint.
        if (self.cb.draw_pattern) |dp| {
            dp(self.cb.ctx, &feat, name.ptr, name.len, &wr);
        } else {
            self.cb.fill_area(self.cb.ctx, &feat, &wr, 0xA0A0AA8C, 0);
        }
    }

    fn strokeLine(ctx: *anyopaque, token: rs.ColorToken, width_px: f64, dash: rs.Dash, lines: []const []const rs.TilePoint, valdco: ?f64) anyerror!void {
        const self = sp(ctx);
        if (!self.cur_visible) return;
        // Labels-only: emit no stroke geometry, but a depth contour still carries a
        // value label — hold it so it competes in the shared pool like any other.
        if (self.labels_only) {
            if (valdco) |v| try self.emitContourLabel(v, lines);
            return;
        }
        const w: f32 = @floatCast(width_px * self.refDev());
        const on: f32, const off: f32 = switch (dash) {
            .solid => .{ 0, 0 },
            .dashed => .{ DASH_ON * w, DASH_OFF * w },
        };
        const feat = self.cur_feature();
        var wr = try self.worldRings(lines);
        self.cb.stroke_line(self.cb.ctx, &feat, &wr, w, on, off, ccolor(self.resolveColor(token)));
        // Depth-contour value label, laid out ALONG the contour (see emitContourLabel).
        if (valdco) |v| try self.emitContourLabel(v, lines);
    }

    /// Depth-contour value label (S-52 SAFCON01): the DEPCNT value in the mariner's
    /// unit, placed at the midpoint of the longest segment (v1), rotated to that
    /// segment's tangent and MAP-aligned so it follows the contour when the chart
    /// turns — kept upright on screen. Mirrors pixel.zig's placement, mariner's
    /// contourLabelField formatting (metres round, feet floor — a depth errs
    /// shallow), and contourLabelColor (CHGRD by day, brighter neutrals at
    /// dusk/night). The collision pool culls the duplicates a contour spanning many
    /// tiles produces.
    fn emitContourLabel(self: *VectorSurface, v: f64, lines: []const []const rs.TilePoint) !void {
        var best2: f64 = 0;
        var mid: rs.TilePoint = .{ .x = 0, .y = 0 };
        var tangent: f64 = 0;
        for (lines) |line| {
            for (0..line.len -| 1) |i| {
                const dx: f64 = @floatFromInt(line[i + 1].x - line[i].x);
                const dy: f64 = @floatFromInt(line[i + 1].y - line[i].y);
                const len2 = dx * dx + dy * dy;
                if (len2 > best2) {
                    best2 = len2;
                    mid = .{ .x = @divTrunc(line[i].x + line[i + 1].x, 2), .y = @divTrunc(line[i].y + line[i + 1].y, 2) };
                    tangent = std.math.atan2(dy, dx);
                }
            }
        }
        // The visible piece's length in WORLD units — the legibility gate is
        // applied against the view zoom when the candidate is resolved, so a
        // memoized contour label re-gates itself as the mariner zooms.
        const gate_world_len = @sqrt(best2) * self.inv_ne;

        var buf: [24]u8 = undefined;
        const label = if (self.settings.depth_unit == .feet)
            std.fmt.bufPrint(&buf, "{d}", .{@floor(v * sndfrm.M_TO_FT)}) catch return
        else
            std.fmt.bufPrint(&buf, "{d}", .{@round(v)}) catch return;

        // CHGRD by day, bright neutral at dusk/night (mariner.contourLabelColor).
        const color = switch (self.palette) {
            .day => self.resolveColor("CHGRD"),
            .dusk => cv.Color{ .r = 0xdd, .g = 0xe7, .b = 0xec },
            .night => cv.Color{ .r = 0xaa, .g = 0xb7, .b = 0xbf },
        };
        // Follow the contour (MAP), flipped as needed so it never reads upside
        // down — the flip depends on the view rotation, so it is deferred too.
        // A contour value is not one of the spec's IMPORTANT text groups (group 0).
        try self.holdLabel(label, 10, "center", "middle", 0, 0, color, tangent, .map, true, gate_world_len, 0, mid);
    }

    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: rs.SymbolPlacement, danger_depth: ?f64) anyerror!void {
        _ = placement; // both .point and .line now draw at display size (refDev)
        const self = sp(ctx);
        if (self.labels_only) return; // a symbol is not text and never enters the pool
        const store = self.store orelse return;
        if (!resolve.visible(&self.cur, name, GATE_ZOOM, self.settings)) return;
        // The style path gates INFORM01 information callouts behind
        // show_inform_callouts (mariner.zig); the live Surface path bypasses
        // the style, so mirror that toggle here.
        if (!self.settings.show_inform_callouts and std.mem.eql(u8, name, "INFORM01")) return;
        var eff = name;
        if (danger_depth) |dd| eff = if (dd > self.settings.safety_contour) "DANGER02" else "DANGER01";
        const s = store.get(eff) orelse return;
        // Draw as an atlas sprite when the host supports it; else tessellate.
        // Symbols never participate in declutter (S-52 icon-allow-overlap — they
        // all draw). Both .point navaids AND .line bricks draw at display size
        // (refDev): the complex-linestyle period is now walked at render time
        // scaled by size_scale (scene.walkComplexRun), so the brick must scale to
        // match — otherwise bricks would be native-sized at display-scaled spacing.
        const dev: f64 = self.refDev();
        // ORIENT symbols and every linestyle brick are north-referenced (rot_north)
        // → chart-relative; the rest stay upright under a rotated view.
        const rot_align = alignOf(rot_north);
        if (self.cb.draw_sprite) |ds| self.emitSprite(ds, eff, s, at, rot_deg, scale, dev, rot_align) else try self.emitSymbol(s, at, rot_deg, scale, dev, rot_align);
    }

    /// Emit a symbol as an atlas sprite: pass its un-rotated pivot-relative
    /// half-extent (reference px) + world anchor + rotation. The pivot-centred
    /// atlas cell drawn centred on the anchor reproduces the vector placement —
    /// for point symbols AND multi-glyph soundings, whose per-glyph pivots lay
    /// out the number.
    /// `dev` = the device scale for the symbol size (refDev for display-sized
    /// point symbols; 1.0 for line bricks, which must match the engine's native
    /// tile-space spacing so they tile). Symbols never collide — they all draw,
    /// and they claim nothing from the labels above them (see declutter.zig).
    fn emitSprite(self: *VectorSurface, draw_sprite: anytype, name: []const u8, s: *const sym.Symbol, at: rs.TilePoint, rot_deg: f64, scale: f64, dev: f64, rot_align: CRotAlign) void {
        const k = scale * 100.0 * dev;
        var hw: f64 = 0;
        var hh: f64 = 0;
        for (s.paths) |p| for (p.contours) |contour| for (contour) |c| {
            const lx = @abs((c.x - s.pivot.x) * k);
            const ly = @abs((c.y - s.pivot.y) * k);
            if (lx > hw) hw = lx;
            if (ly > hh) hh = ly;
        };
        if (hw <= 0 or hh <= 0) return;
        const anchor = self.worldOf(at);
        const feat = self.cur_feature();
        draw_sprite(self.cb.ctx, &feat, name.ptr, name.len, anchor, @floatCast(rot_deg), rot_align, @floatCast(hw), @floatCast(hh));
    }

    fn drawSounding(ctx: *anyopaque, depth_m: f64, swept: bool, low_acc: bool, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (self.labels_only) return; // a sounding is a symbol, not text — never in the pool
        const store = self.store orelse return;
        if (!resolve.visible(&self.cur, null, GATE_ZOOM, self.settings)) return;
        const feet = self.settings.depth_unit == .feet;
        const shown = if (feet) depth_m * sndfrm.M_TO_FT else depth_m;
        const prefix: []const u8 = if (depth_m <= self.settings.safety_depth) "SOUNDS" else "SOUNDG";
        const list = try sndfrm.syms(self.a, prefix, shown, swept, low_acc, feet);
        // A sounding is a SYMBOL — the Presentation Library draws it as symbol
        // glyphs so it stays legible and correctly located — and every symbol
        // draws: S-52 suppresses only coincident lines and area boundaries. So a
        // sounding never enters the collision pool. It neither drops a label nor
        // is dropped by one; text simply draws on top of it (text is drawn last).
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |glyph| {
            if (glyph.len == 0) continue;
            const s = store.get(glyph) orelse continue;
            // Sounding digits read upright under a rotated view (screen-referenced),
            // sized by soundingDev so digit + spacing scale together.
            if (self.cb.draw_sprite) |ds| self.emitSprite(ds, glyph, s, at, 0, sndfrm.SYMBOL_SCALE, self.soundingDev(), .viewport) else try self.emitSymbol(s, at, 0, sndfrm.SYMBOL_SCALE, self.soundingDev(), .viewport);
        }
    }

    /// Emit one symbol: world anchor + each path's outline in anchor-local
    /// reference px (pivot-relative, scaled, rotated). Constant screen size.
    fn emitSymbol(self: *VectorSurface, s: *const sym.Symbol, at: rs.TilePoint, rot_deg: f64, scale: f64, dev: f64, rot_align: CRotAlign) !void {
        const anchor = self.worldOf(at);
        const feat = self.cur_feature();
        const k: f32 = @floatCast(scale * 100.0 * dev);
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
            if (p.fill) |color| self.cb.draw_symbol(self.cb.ctx, &feat, anchor, &lr, ccolor(color), 1, 0, rot_align);
            if (p.stroke) |st| self.cb.draw_symbol(self.cb.ctx, &feat, anchor, &lr, ccolor(st.color), 0, st.width * k, rot_align);
        }
    }

    fn drawText(ctx: *anyopaque, text: []const u8, style: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (!self.cur_visible) return;
        if (!resolve.textGroupVisible(style.group, self.settings)) return;
        const font_css: f32 = @floatCast(if (style.font_size > 0) style.font_size else 12);
        const halign = if (style.halign.len > 0) style.halign else "center";
        const valign = if (style.valign.len > 0) style.valign else "middle";
        // An ordinary label stays upright under a rotated view: no rotation, and
        // screen-referenced so the host does not turn it with the chart. It carries
        // no legibility gate — a point label places at every zoom.
        try self.holdLabel(text, font_css, halign, valign, @floatCast(style.offset_x), @floatCast(style.offset_y), self.resolveColor(style.color), 0, .viewport, false, 0, style.group, at);
    }

    /// Shape a label and HOLD it: which labels survive is a property of the WHOLE
    /// scene, not of the order the engine walked it (the engine walks a cell in
    /// ENC record order), so nothing is emitted until endScene ranks the pool.
    /// `color` is already resolved (the contour label uses a palette-specific
    /// neutral the colortables do not name); `rot_rad`/`rot_align`/`upright` carry
    /// the run's rotation, `gate_world_len` its legibility gate (0 = none), and
    /// `group` is the S-52 text group the pool ranks on.
    ///
    /// In CAPTURE mode the shaped candidate parks in the driver's list instead —
    /// the whole point of the split: shaping is a property of the tile, and only
    /// the resolution below it is a property of the view.
    fn holdLabel(self: *VectorSurface, text: []const u8, font_css: f32, halign: []const u8, valign: []const u8, ox_mm: f32, oy_mm: f32, color: cv.Color, rot_rad: f64, rot_align: CRotAlign, upright: bool, gate_world_len: f64, group: i64, at: rs.TilePoint) !void {
        const a = if (self.capture) |cap| cap.a else self.a;
        const c = (try self.shapeCandidate(a, text, font_css, halign, valign, ox_mm, oy_mm, color, rot_rad, rot_align, upright, gate_world_len, group, at)) orelse return;
        if (self.capture) |cap| {
            try cap.list.append(cap.a, c);
            return;
        }
        try self.pushCandidate(c);
    }

    /// Lay a label out into its view-independent Candidate — glyph size, real
    /// advance width, the aligned baseline origin, the world anchor. Null when
    /// there is nothing to place (no font, sub-pixel type, empty run). Every
    /// slice it keeps is duped into `a`, which for a captured candidate is the
    /// tile cache entry's arena, not the render arena.
    fn shapeCandidate(self: *VectorSurface, a: Allocator, text: []const u8, font_css: f32, halign: []const u8, valign: []const u8, ox_mm: f32, oy_mm: f32, color: cv.Color, rot_rad: f64, rot_align: CRotAlign, upright: bool, gate_world_len: f64, group: i64, at: rs.TilePoint) !?Candidate {
        const f = &(self.fnt orelse return null);
        const px = font_css * @as(f32, @floatCast(self.textDev()));
        if (px <= 1) return null;

        // Real advance width — the collision box and the alignment.
        var pen: f32 = 0;
        var it = (std.unicode.Utf8View.init(text) catch return null).iterator();
        while (it.nextCodepoint()) |cp| pen += f.advance(f.glyphIndex(cp)) * px;
        if (pen <= 0) return null;

        // Alignment + S-52 LocalOffset -> the anchor-local baseline origin. Laid
        // out ONCE: both host paths (SDF string, tessellated outline) draw from it,
        // so a held label and a drawn label cannot disagree.
        const mm_px: f32 = @floatCast(sndfrm.SYMBOL_SCALE * 100.0 * self.textDev());
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

        return .{
            // cur.class is a slice into the decoded tile, which a cache eviction
            // can free out from under a memoized candidate — dupe it.
            .cls = a.dupeZ(u8, self.cur.class) catch @as([:0]u8, @constCast("")),
            .scamin = self.cur.scamin orelse 0,
            .plane = @intCast(self.cur.draw_prio),
            // Standard is the default for an unbanded feature (see cur_feature).
            .disp_cat = switch (self.cur.cat) {
                0 => .base,
                2 => .other,
                else => .standard,
            },
            .anchor = self.worldOf(at),
            .text = try a.dupe(u8, text),
            .px = px,
            .pen = pen,
            .x0 = x0,
            .baseline = baseline,
            .color = color,
            .group = group,
            .rot_rad = rot_rad,
            .rot_align = rot_align,
            .upright = upright,
            .gate_world_len = gate_world_len,
        };
    }

    /// Resolve a candidate AGAINST THIS VIEW and enter it in the shared pool: apply
    /// the zoom's legibility gate, turn the run upright for the view rotation, and
    /// box it in the screen frame the host will draw it in. Called once per
    /// candidate per view — over freshly shaped labels or over memoized ones, with
    /// the same result either way, because none of the three inputs it applies were
    /// ever baked into the candidate.
    pub fn pushCandidate(self: *VectorSurface, c: Candidate) !void {
        // Too short a piece to carry a legible label at this zoom (screen px).
        if (c.gate_world_len > 0 and c.gate_world_len * 256.0 * std.math.exp2(self.view_zoom) < LEGIBLE_PX) return;
        const rot_deg = (if (c.upright) self.uprightTangent(c.rot_rad) else c.rot_rad) * 180.0 / std.math.pi;
        try self.pool.add(self.a, self.labels.items.len, c.group, c.cls, c.text, self.labelBox(c.anchor, c.x0, c.baseline, c.pen, c.px, rot_deg, c.rot_align));
        try self.labels.append(self.a, .{
            .feat = .{ .cls = c.cls.ptr, .scamin = c.scamin, .plane = c.plane, .disp_cat = c.disp_cat },
            .anchor = c.anchor,
            .text = c.text,
            .px = c.px,
            .x0 = c.x0,
            .baseline = c.baseline,
            .color = c.color,
            .rot_deg = rot_deg,
            .rot_align = c.rot_align,
        });
    }

    /// A label's ink box in the SCREEN frame the host draws it in: the shaped run
    /// (advance width by the font's ascent/descent) turned by the angle it will
    /// actually appear at — its own rotation, plus the view rotation when the host
    /// will add that (.map) — then bounded axis-aligned. A north-up view of an
    /// unrotated label is the plain aligned box.
    fn labelBox(self: *const VectorSurface, anchor: CWorldPt, x0: f32, baseline: f32, pen: f32, px: f32, rot_deg: f64, rot_align: CRotAlign) dc.Box {
        const f = &(self.fnt.?);
        const top = baseline - f.ascent * px;
        const bot = baseline + f.descent * px;
        const theta = rot_deg * std.math.pi / 180.0 + if (rot_align == .map) self.view_rotation else 0;
        const c = @cos(theta);
        const sn = @sin(theta);
        const corners = [4][2]f64{
            .{ x0, top },
            .{ x0 + pen, top },
            .{ x0 + pen, bot },
            .{ x0, bot },
        };
        const sc = self.screenPx(anchor);
        var box = dc.Box{ .x0 = std.math.floatMax(f64), .y0 = std.math.floatMax(f64), .x1 = -std.math.floatMax(f64), .y1 = -std.math.floatMax(f64) };
        for (corners) |k| {
            const rx = sc[0] + k[0] * c - k[1] * sn;
            const ry = sc[1] + k[0] * sn + k[1] * c;
            box.x0 = @min(box.x0, rx);
            box.y0 = @min(box.y0, ry);
            box.x1 = @max(box.x1, rx);
            box.y1 = @max(box.y1, ry);
        }
        return box;
    }

    /// Emit one label that WON its space, through whichever text path the host
    /// offers: its SDF glyph atlas, or tessellated glyph outlines.
    fn emitLabel(self: *VectorSurface, l: Label) !void {
        if (self.cb.draw_text_str) |dts| {
            dts(self.cb.ctx, &l.feat, l.anchor, l.x0, l.baseline, l.text.ptr, l.text.len, l.px, @floatCast(l.rot_deg), l.rot_align, ccolor(l.color), 0);
            return;
        }
        try self.emitText(l);
    }

    fn glyphOutline(self: *VectorSurface, gid: u16) ![]const []const cv.Point {
        if (self.glyph_cache.get(gid)) |hit| return hit;
        const out = try self.fnt.?.outline(self.a, gid);
        try self.glyph_cache.put(self.a, gid, out);
        return out;
    }

    /// Tessellate a label that won its space into anchor-local reference px glyph
    /// outlines, walking from the baseline origin the layout already fixed and
    /// rotated about the anchor (the host adds the view rotation when .map).
    fn emitText(self: *VectorSurface, l: Label) !void {
        const f = &(self.fnt orelse return);
        const rad: f32 = @floatCast(l.rot_deg * std.math.pi / 180.0);
        const cosr = @cos(rad);
        const sinr = @sin(rad);

        var rings = std.ArrayList([]const cv.Point).empty;
        var pen: f32 = 0;
        var it = (std.unicode.Utf8View.init(l.text) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            const gid = f.glyphIndex(cp);
            for (try self.glyphOutline(gid)) |contour| {
                const pts = try self.a.alloc(cv.Point, contour.len);
                for (contour, 0..) |p, i| {
                    // em units, y up -> local px, y down (anchor-relative), then
                    // rotated about the anchor.
                    const lx = l.x0 + pen + p.x * l.px;
                    const ly = l.baseline - p.y * l.px;
                    pts[i] = .{ .x = lx * cosr - ly * sinr, .y = lx * sinr + ly * cosr };
                }
                try rings.append(self.a, pts);
            }
            pen += f.advance(gid) * l.px;
        }
        if (rings.items.len == 0) return;
        var lr = try self.localRings(rings.items);
        self.cb.draw_text(self.cb.ctx, &l.feat, l.anchor, &lr, ccolor(l.color), 0, 0, l.rot_align);
    }
};

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

/// A recording CSurface for the tests below: it captures every draw_text_str
/// (the string + its rotation + alignment — all these tests assert). The four
/// required draw callbacks are no-ops; supplying draw_text_str routes the label
/// text through the SDF path so the run angle arrives verbatim (no outline).
const RecordCb = struct {
    a: Allocator,
    texts: std.ArrayList(Text) = .empty,

    const Text = struct { text: []const u8, rot_deg: f32, rot_align: CRotAlign };

    fn noFill(_: ?*anyopaque, _: *const CFeature, _: *const CWorldRings, _: CColor, _: c_int) callconv(.c) void {}
    fn noStroke(_: ?*anyopaque, _: *const CFeature, _: *const CWorldRings, _: f32, _: f32, _: f32, _: CColor) callconv(.c) void {}
    fn noSymbol(_: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: *const CLocalRings, _: CColor, _: c_int, _: f32, _: CRotAlign) callconv(.c) void {}
    fn noText(_: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: *const CLocalRings, _: CColor, _: CColor, _: f32, _: CRotAlign) callconv(.c) void {}
    fn onTextStr(ctx: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: f32, _: f32, text: [*]const u8, len: usize, _: f32, rot_deg: f32, rot_align: CRotAlign, _: CColor, _: CColor) callconv(.c) void {
        const self: *RecordCb = @ptrCast(@alignCast(ctx.?));
        const dup = self.a.dupe(u8, text[0..len]) catch return;
        self.texts.append(self.a, .{ .text = dup, .rot_deg = rot_deg, .rot_align = rot_align }) catch {};
    }

    fn surface(self: *RecordCb) CSurface {
        return .{
            .ctx = self,
            .fill_area = noFill,
            .stroke_line = noStroke,
            .draw_symbol = noSymbol,
            .draw_text = noText,
            .draw_text_str = onTextStr,
        };
    }
};

test "VectorSurface: depth-contour value is emitted along the contour, MAP-aligned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, ""); // empty palette: colours fall back, unasserted
    const settings = resolve.Settings{};
    var rec = RecordCb{ .a = a };
    const cb = rec.surface();

    var vs = VectorSurface.init(a, &colors, .dusk, &settings, &cb);
    vs.view_zoom = 12;
    vs.setTile(12, 0, 0);
    const surf = vs.asSurface();

    const meta = rs.FeatureMeta{ .class = "DEPCNT" };
    try surf.beginFeature(&meta);
    // A long, VERTICAL contour piece (tangent 90°) that clears the length gate.
    const line = [_]rs.TilePoint{ .{ .x = 2000, .y = 100 }, .{ .x = 2000, .y = 3900 } };
    const lines = [_][]const rs.TilePoint{&line};
    try surf.strokeLine("DEPCNT", 1.0, .solid, &lines, 20.0); // 20 m contour
    try surf.endFeature();
    _ = try surf.endScene(a); // labels are held until the scene closes and the pool ranks them

    try testing.expectEqual(@as(usize, 1), rec.texts.items.len);
    const t = rec.texts.items[0];
    try testing.expectEqualStrings("20", t.text); // metres, rounded
    try testing.expectEqual(CRotAlign.map, t.rot_align); // follows the chart
    try testing.expect(@abs(t.rot_deg - 90) < 0.5); // vertical tangent, upright at north-up
}

test "VectorSurface: depth in feet floors (a depth errs shallow)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, "");
    var settings = resolve.Settings{};
    settings.depth_unit = .feet;
    var rec = RecordCb{ .a = a };
    const cb = rec.surface();

    var vs = VectorSurface.init(a, &colors, .day, &settings, &cb);
    vs.view_zoom = 12;
    vs.setTile(12, 0, 0);
    const surf = vs.asSurface();

    const meta = rs.FeatureMeta{ .class = "DEPCNT" };
    try surf.beginFeature(&meta);
    const line = [_]rs.TilePoint{ .{ .x = 2000, .y = 100 }, .{ .x = 2000, .y = 3900 } };
    const lines = [_][]const rs.TilePoint{&line};
    try surf.strokeLine("DEPCNT", 1.0, .solid, &lines, 2.0); // 2 m = 6.56 ft
    try surf.endFeature();
    _ = try surf.endScene(a);

    try testing.expectEqual(@as(usize, 1), rec.texts.items.len);
    try testing.expectEqualStrings("6", rec.texts.items[0].text); // floor(6.56), never "7"
}

test "VectorSurface: an ordinary label stays upright and viewport-aligned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var rec = RecordCb{ .a = a };
    const cb = rec.surface();

    var vs = VectorSurface.init(a, &colors, .day, &settings, &cb);
    vs.view_zoom = 12;
    vs.setTile(12, 0, 0);
    const surf = vs.asSurface();

    const meta = rs.FeatureMeta{ .class = "SEAARE" };
    try surf.beginFeature(&meta);
    const style = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .halign = "center", .valign = "middle" };
    try surf.drawText("Bay", &style, .{ .x = 2000, .y = 2000 });
    try surf.endFeature();
    _ = try surf.endScene(a);

    try testing.expectEqual(@as(usize, 1), rec.texts.items.len);
    const t = rec.texts.items[0];
    try testing.expectEqualStrings("Bay", t.text);
    try testing.expectEqual(CRotAlign.viewport, t.rot_align); // never turns with the chart
    try testing.expectEqual(@as(f32, 0), t.rot_deg);
}

test "VectorSurface: a sounding claims no space — a label on top of it survives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var rec = RecordCb{ .a = a };
    const cb = rec.surface();

    var vs = VectorSurface.init(a, &colors, .day, &settings, &cb);
    vs.view_zoom = 12;
    vs.setTile(12, 0, 0);
    const surf = vs.asSurface();

    // The sounding is drawn FIRST, exactly where the light description lands —
    // the shape of the bug this pool exists to kill. A sounding is a symbol: it
    // claims nothing, so the label still wins its space. Toggling soundings can
    // therefore never cost a chart its labels.
    const meta = rs.FeatureMeta{ .class = "SOUNDG", .draw_prio = 5 };
    try surf.beginFeature(&meta);
    try surf.drawSounding(4.0, false, false, .{ .x = 2000, .y = 2000 });
    try surf.endFeature();

    const light = rs.FeatureMeta{ .class = "LIGHTS", .draw_prio = 5 };
    try surf.beginFeature(&light);
    const style = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 23 }; // light description
    try surf.drawText("Fl R 4s", &style, .{ .x = 2000, .y = 2000 });
    try surf.endFeature();
    _ = try surf.endScene(a);

    try testing.expectEqual(@as(usize, 1), rec.texts.items.len);
    try testing.expectEqualStrings("Fl R 4s", rec.texts.items[0].text);
}

test "VectorSurface: important text outranks a name it overlaps, whatever the walk order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var rec = RecordCb{ .a = a };
    const cb = rec.surface();

    var vs = VectorSurface.init(a, &colors, .day, &settings, &cb);
    vs.view_zoom = 12;
    vs.setTile(12, 0, 0);
    const surf = vs.asSurface();

    // The NAME is walked first (the cell encoded it first) and carries the higher
    // feature draw priority. Neither buys it the space: the text group is the
    // whole ladder, and a label's feature priority says nothing about the label.
    const named = rs.FeatureMeta{ .class = "SEAARE", .draw_prio = 9 };
    try surf.beginFeature(&named);
    const name = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 26 };
    try surf.drawText("Bay", &name, .{ .x = 2000, .y = 2000 });
    try surf.endFeature();

    const bridge = rs.FeatureMeta{ .class = "BRIDGE", .draw_prio = 3 };
    try surf.beginFeature(&bridge);
    const clearance = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 11 }; // vertical clearance
    try surf.drawText("clr 11", &clearance, .{ .x = 2000, .y = 2000 });
    try surf.endFeature();
    _ = try surf.endScene(a);

    try testing.expectEqual(@as(usize, 1), rec.texts.items.len);
    try testing.expectEqualStrings("clr 11", rec.texts.items[0].text);
}

test "VectorSurface: labels_only emits decluttered text but no area/line/symbol geometry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    // Count every geometry callback; the text goes through the SDF path (recorded).
    const Counting = struct {
        a: Allocator,
        fills: usize = 0,
        strokes: usize = 0,
        symbols: usize = 0,
        texts: std.ArrayList([]const u8) = .empty,
        fn onFill(ctx: ?*anyopaque, _: *const CFeature, _: *const CWorldRings, _: CColor, _: c_int) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.fills += 1;
        }
        fn onStroke(ctx: ?*anyopaque, _: *const CFeature, _: *const CWorldRings, _: f32, _: f32, _: f32, _: CColor) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.strokes += 1;
        }
        fn onSymbol(ctx: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: *const CLocalRings, _: CColor, _: c_int, _: f32, _: CRotAlign) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.symbols += 1;
        }
        fn noText(_: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: *const CLocalRings, _: CColor, _: CColor, _: f32, _: CRotAlign) callconv(.c) void {}
        fn onTextStr(ctx: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: f32, _: f32, text: [*]const u8, len: usize, _: f32, _: f32, _: CRotAlign, _: CColor, _: CColor) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            const dup = s.a.dupe(u8, text[0..len]) catch return;
            s.texts.append(s.a, dup) catch {};
        }
    };
    var rec = Counting{ .a = a };
    const cb = CSurface{
        .ctx = &rec,
        .fill_area = Counting.onFill,
        .stroke_line = Counting.onStroke,
        .draw_symbol = Counting.onSymbol,
        .draw_text = Counting.noText,
        .draw_text_str = Counting.onTextStr,
    };

    var vs = VectorSurface.init(a, &colors, .day, &settings, &cb);
    vs.view_zoom = 12;
    vs.labels_only = true;
    vs.setTile(12, 0, 0);
    const surf = vs.asSurface();
    try surf.beginScene(12);

    // An area fill: no geometry in labels-only mode.
    const ring = [_]rs.TilePoint{ .{ .x = 100, .y = 100 }, .{ .x = 900, .y = 100 }, .{ .x = 900, .y = 900 } };
    const rings = [_][]const rs.TilePoint{&ring};
    const sea = rs.FeatureMeta{ .class = "SEAARE" };
    try surf.beginFeature(&sea);
    try surf.fillArea("DEPVS", &rings, null);
    // ...but the sea area's NAME still competes and is emitted. Anchored well clear
    // of the contour's midpoint below so both labels win their space.
    const style = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 26 };
    try surf.drawText("Bay", &style, .{ .x = 400, .y = 400 });
    try surf.endFeature();

    // A depth contour: no stroke geometry, but its value label is emitted (midpoint
    // of the longest segment, well away from "Bay").
    const dep = rs.FeatureMeta{ .class = "DEPCNT" };
    try surf.beginFeature(&dep);
    const line = [_]rs.TilePoint{ .{ .x = 2000, .y = 100 }, .{ .x = 2000, .y = 3900 } };
    const lines = [_][]const rs.TilePoint{&line};
    try surf.strokeLine("DEPCNT", 1.0, .solid, &lines, 20.0);
    try surf.endFeature();
    _ = try surf.endScene(a);

    try testing.expectEqual(@as(usize, 0), rec.fills);
    try testing.expectEqual(@as(usize, 0), rec.strokes);
    try testing.expectEqual(@as(usize, 0), rec.symbols);
    try testing.expectEqual(@as(usize, 2), rec.texts.items.len); // "Bay" + the "20" contour value
}

// ---- the per-tile candidate memo ---------------------------------------------
//
// The memo's whole correctness claim is that a view resolved from CAPTURED
// candidates is indistinguishable from one portrayed from scratch — same
// survivors, same order, same geometry — at ANY view, not just the one the
// candidates happened to be captured at. These tests pin exactly that, by
// running both paths over the same scene and comparing the emitted label
// stream field by field.

/// Everything the host is told about one emitted label. Comparing whole records
/// is the point: a memo that got the anchor or the run angle subtly wrong while
/// keeping the text right would be the dangerous failure.
///
/// COLOUR is part of the record. It is carried as a packed 0xRRGGBBAA scalar
/// (CColor), not a 4-byte struct: passing a small extern struct by value across
/// callconv(.c) is miscompiled by zig 0.16 on aarch64 in every optimized build
/// mode, which silently delivered transparent fills, lines and text to hosts.
/// Asserting colour here guards that regression through a real callback.
const EmittedLabel = struct {
    color: CColor,
    cls: []const u8,
    text: []const u8,
    anchor: CWorldPt,
    ox: f32,
    oy: f32,
    px: f32,
    rot_deg: f32,
    rot_align: CRotAlign,
};

const LabelRec = struct {
    a: Allocator,
    out: std.ArrayListUnmanaged(EmittedLabel) = .empty,

    fn noFill(_: ?*anyopaque, _: *const CFeature, _: *const CWorldRings, _: CColor, _: c_int) callconv(.c) void {}
    fn noStroke(_: ?*anyopaque, _: *const CFeature, _: *const CWorldRings, _: f32, _: f32, _: f32, _: CColor) callconv(.c) void {}
    fn noSymbol(_: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: *const CLocalRings, _: CColor, _: c_int, _: f32, _: CRotAlign) callconv(.c) void {}
    fn noText(_: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: *const CLocalRings, _: CColor, _: CColor, _: f32, _: CRotAlign) callconv(.c) void {}
    fn onTextStr(ctx: ?*anyopaque, f: *const CFeature, anchor: CWorldPt, ox: f32, oy: f32, text: [*]const u8, len: usize, px: f32, rot_deg: f32, rot_align: CRotAlign, color: CColor, _: CColor) callconv(.c) void {
        const self: *LabelRec = @ptrCast(@alignCast(ctx.?));
        self.out.append(self.a, .{
            .color = color,
            .cls = self.a.dupe(u8, std.mem.span(f.cls)) catch return,
            .text = self.a.dupe(u8, text[0..len]) catch return,
            .anchor = anchor,
            .ox = ox,
            .oy = oy,
            .px = px,
            .rot_deg = rot_deg,
            .rot_align = rot_align,
        }) catch {};
    }

    fn surface(self: *LabelRec) CSurface {
        return .{
            .ctx = self,
            .fill_area = noFill,
            .stroke_line = noStroke,
            .draw_symbol = noSymbol,
            .draw_text = noText,
            .draw_text_str = onTextStr,
        };
    }
};

/// The two-tile scene both halves of the memo tests walk. Tile 0 carries a sea
/// area's name and a long depth contour (the one label whose placement re-derives
/// per view — it re-gates on zoom and flips upright on rotation); tile 1 carries a
/// light description, so the walk crosses a tile seam the way a real view does.
fn walkLabelTile(surf: rs.Surface, vs: *VectorSurface, which: u32, settings: *const resolve.Settings) !void {
    _ = settings;
    vs.setTile(12, which, 0);
    if (which == 0) {
        const sea = rs.FeatureMeta{ .class = "SEAARE" };
        try surf.beginFeature(&sea);
        const name = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 26 };
        try surf.drawText("Mount Hope Bay", &name, .{ .x = 400, .y = 400 });
        try surf.endFeature();

        const dep = rs.FeatureMeta{ .class = "DEPCNT" };
        try surf.beginFeature(&dep);
        const line = [_]rs.TilePoint{ .{ .x = 2000, .y = 100 }, .{ .x = 2000, .y = 3900 } };
        const lines = [_][]const rs.TilePoint{&line};
        try surf.strokeLine("DEPCNT", 1.0, .solid, &lines, 20.0);
        try surf.endFeature();
    } else {
        const light = rs.FeatureMeta{ .class = "LIGHTS" };
        try surf.beginFeature(&light);
        const desc = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 23 };
        try surf.drawText("Fl R 4s", &desc, .{ .x = 1000, .y = 2000 });
        try surf.endFeature();
    }
}

/// Walk the scene the way the UNCACHED pass does: portray straight into the pool.
fn labelsPortrayed(a: Allocator, colors: *const resolve.Colors, settings: *const resolve.Settings, zoom: f64, rot: f64) ![]const EmittedLabel {
    const rec = try a.create(LabelRec);
    rec.* = .{ .a = a };
    const cb = try a.create(CSurface);
    cb.* = rec.surface();

    var vs = VectorSurface.init(a, colors, .day, settings, cb);
    vs.view_zoom = zoom;
    vs.view_rotation = rot;
    vs.labels_only = true;
    const surf = vs.asSurface();
    try surf.beginScene(12);
    for (0..2) |i| try walkLabelTile(surf, &vs, @intCast(i), settings);
    _ = try surf.endScene(a);
    return rec.out.items;
}

/// Walk it the way the CACHED pass does: capture each tile's candidates once,
/// then resolve the view from those candidates alone.
fn labelsFromCandidates(a: Allocator, colors: *const resolve.Colors, settings: *const resolve.Settings, cands: []const []const Candidate, zoom: f64, rot: f64) ![]const EmittedLabel {
    const rec = try a.create(LabelRec);
    rec.* = .{ .a = a };
    const cb = try a.create(CSurface);
    cb.* = rec.surface();

    var vs = VectorSurface.init(a, colors, .day, settings, cb);
    vs.view_zoom = zoom;
    vs.view_rotation = rot;
    vs.labels_only = true;
    const surf = vs.asSurface();
    try surf.beginScene(12);
    for (cands) |tile_cands| {
        for (tile_cands) |c| try vs.pushCandidate(c);
    }
    _ = try surf.endScene(a);
    return rec.out.items;
}

/// Capture each tile's candidates, exactly as the driver does on a cache miss.
fn captureCandidates(a: Allocator, colors: *const resolve.Colors, settings: *const resolve.Settings, palette: resolve.PaletteId) ![]const []const Candidate {
    const cb = try a.create(CSurface);
    var throwaway = LabelRec{ .a = a };
    cb.* = throwaway.surface();

    var vs = VectorSurface.init(a, colors, palette, settings, cb);
    vs.view_zoom = 12; // the capture-time view must not reach the candidates
    vs.view_rotation = 0;
    vs.labels_only = true;
    const surf = vs.asSurface();
    try surf.beginScene(12);

    const out = try a.alloc([]const Candidate, 2);
    for (0..2) |i| {
        var cap = Capture{ .a = a };
        vs.capture = &cap;
        try walkLabelTile(surf, &vs, @intCast(i), settings);
        vs.capture = null;
        out[i] = cap.list.items;
    }
    return out;
}

fn expectSameLabels(want: []const EmittedLabel, got: []const EmittedLabel) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.color, g.color);
        // The colour must also SURVIVE the callconv(.c) boundary: a 4-byte
        // struct by value is miscompiled here in optimized builds (zeroed under
        // ReleaseFast/ReleaseSafe), which shipped invisible text to hosts.
        // CHBLK is opaque, so a zero alpha means the ABI ate it.
        try testing.expect(w.color & 0xFF != 0);
        try testing.expectEqualStrings(w.cls, g.cls);
        try testing.expectEqualStrings(w.text, g.text);
        try testing.expectEqual(w.anchor.x, g.anchor.x);
        try testing.expectEqual(w.anchor.y, g.anchor.y);
        try testing.expectEqual(w.ox, g.ox);
        try testing.expectEqual(w.oy, g.oy);
        try testing.expectEqual(w.px, g.px);
        try testing.expectEqual(w.rot_deg, g.rot_deg);
        try testing.expectEqual(w.rot_align, g.rot_align);
    }
}

test "label memo: a view resolved from cached candidates emits exactly the portrayed view" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};

    const cands = try captureCandidates(a, &colors, &settings, .day);
    // The candidates were captured ONCE, at z12 north-up. Every view below resolves
    // from that same set and must match a walk portrayed fresh at that view — the
    // memo's entire contract, and the reason zoom and rotation are not in its key.
    const views = [_][2]f64{
        .{ 12, 0 }, // the capture view itself (the "second call, same view" case)
        .{ 12.7, 0 }, // a fractional zoom mid-pinch
        .{ 8, 0.4 }, // zoomed way out and rotated
        .{ 14, -1.9 }, // rotated past vertical: the contour value flips upright
        .{ 7, 0 }, // far enough out that the contour's piece is illegible and drops
    };
    for (views) |v| {
        const want = try labelsPortrayed(a, &colors, &settings, v[0], v[1]);
        const got = try labelsFromCandidates(a, &colors, &settings, cands, v[0], v[1]);
        try expectSameLabels(want, got);
    }

    // The views above must actually exercise the ZOOM-dependent parts, or matching
    // proves nothing. The contour value carries the legibility gate: its piece is
    // long enough to read at z12 and too short at z7, and the memo re-gates the
    // same candidate both ways.
    const has = struct {
        fn depcnt(ls: []const EmittedLabel) bool {
            for (ls) |l| {
                if (std.mem.eql(u8, l.cls, "DEPCNT")) return true;
            }
            return false;
        }
    }.depcnt;
    try testing.expect(has(try labelsFromCandidates(a, &colors, &settings, cands, 12, 0)));
    try testing.expect(!has(try labelsFromCandidates(a, &colors, &settings, cands, 7, 0)));

    // ...and the ROTATION-dependent one: the contour value is MAP-aligned, so its
    // run angle is flipped 180° for a view rotation that would leave it upside
    // down. Same candidate, two different emitted angles.
    const upright = try labelsFromCandidates(a, &colors, &settings, cands, 12, 0);
    const flipped = try labelsFromCandidates(a, &colors, &settings, cands, 12, 2.0);
    for (upright, flipped) |u, fl| {
        if (!std.mem.eql(u8, u.cls, "DEPCNT")) continue;
        try testing.expectEqual(CRotAlign.map, u.rot_align);
        try testing.expect(@abs(@abs(u.rot_deg - fl.rot_deg) - 180) < 0.001);
    }
}

test "label memo: a mariner text-group switch changes the candidates it must be re-keyed on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");

    // Default: the name (group 26), the light description (group 23) and the
    // contour value all place.
    const all = resolve.Settings{};
    const base = try captureCandidates(a, &colors, &all, .day);
    try testing.expectEqual(@as(usize, 2), base[0].len); // name + contour
    try testing.expectEqual(@as(usize, 1), base[1].len); // light description

    // text_names off drops the geographic name from the CANDIDATES, not merely from
    // the survivors — so a memo keyed without it would serve a label the mariner
    // switched off. labelcache.epochOf hashes it (and every other setting).
    const no_names = resolve.Settings{ .text_names = false };
    const without = try captureCandidates(a, &colors, &no_names, .day);
    try testing.expectEqual(@as(usize, 1), without[0].len); // contour value only
    try testing.expectEqualStrings("DEPCNT", without[0][0].cls);

    // ...and the same for the light descriptions switch.
    const no_lights = resolve.Settings{ .show_light_descriptions = false };
    const dark = try captureCandidates(a, &colors, &no_lights, .day);
    try testing.expectEqual(@as(usize, 0), dark[1].len);

    // Depth unit rewrites the contour value's TEXT (20 m -> 65 ft), which is why it
    // is in the key too.
    const feet = resolve.Settings{ .depth_unit = .feet };
    const ft = try captureCandidates(a, &colors, &feet, .day);
    try testing.expectEqualStrings("20", base[0][1].text);
    try testing.expectEqualStrings("65", ft[0][1].text);

    // And the palette: a candidate carries a RESOLVED colour, so the same tile at
    // dusk is a different candidate set. Asserted on the candidate — the only place
    // a label's colour is observable (see EmittedLabel for why not through the
    // callback). Capture is otherwise deterministic: same inputs, same colour.
    const again = try captureCandidates(a, &colors, &all, .day);
    const dusk = try captureCandidates(a, &colors, &all, .dusk);
    try testing.expectEqual(base[0][1].color, again[0][1].color);
    try testing.expect(!std.meta.eql(base[0][1].color, dusk[0][1].color));
}

/// Records the CFeature each draw call is tagged with.
const FeatCb = struct {
    a: Allocator,
    feats: std.ArrayListUnmanaged(struct { cls: []const u8, scamin: i64, disp_cat: CDispCat }) = .empty,

    fn onFill(ctx: ?*anyopaque, f: *const CFeature, _: *const CWorldRings, _: CColor, _: c_int) callconv(.c) void {
        const self: *FeatCb = @ptrCast(@alignCast(ctx.?));
        const cls = std.mem.span(f.cls);
        self.feats.append(self.a, .{
            .cls = self.a.dupe(u8, cls) catch return,
            .scamin = f.scamin,
            .disp_cat = f.disp_cat,
        }) catch {};
    }
    fn noStroke(_: ?*anyopaque, _: *const CFeature, _: *const CWorldRings, _: f32, _: f32, _: f32, _: CColor) callconv(.c) void {}
    fn noSymbol(_: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: *const CLocalRings, _: CColor, _: c_int, _: f32, _: CRotAlign) callconv(.c) void {}
    fn noText(_: ?*anyopaque, _: *const CFeature, _: CWorldPt, _: *const CLocalRings, _: CColor, _: CColor, _: f32, _: CRotAlign) callconv(.c) void {}

    fn surface(self: *FeatCb) CSurface {
        return .{ .ctx = self, .fill_area = onFill, .stroke_line = noStroke, .draw_symbol = noSymbol, .draw_text = noText };
    }
};

test "VectorSurface: every draw call carries its feature's display category" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, "");
    // "Other" is off by default (S-52's Standard display) — turn it on, or the
    // cat-2 feature never reaches the surface to be tagged.
    const settings = resolve.Settings{ .display_other = true };
    var rec = FeatCb{ .a = a };
    const cb = rec.surface();

    var vs = VectorSurface.init(a, &colors, .day, &settings, &cb);
    vs.view_zoom = 12;
    vs.setTile(12, 0, 0);
    const surf = vs.asSurface();

    const ring = [_]rs.TilePoint{ .{ .x = 100, .y = 100 }, .{ .x = 900, .y = 100 }, .{ .x = 900, .y = 900 }, .{ .x = 100, .y = 900 } };
    const rings = [_][]const rs.TilePoint{&ring};

    // Display base carries a SCAMIN: the engine reports both and leaves the S-52
    // "SCAMIN shall not be applied to display base" call to the host.
    const depare = rs.FeatureMeta{ .class = "DEPARE", .cat = 0, .scamin = 45000 };
    try surf.beginFeature(&depare);
    try surf.fillArea("DEPVS", &rings, null);
    try surf.endFeature();

    const dmpgrd = rs.FeatureMeta{ .class = "DMPGRD", .cat = 2 };
    try surf.beginFeature(&dmpgrd);
    try surf.fillArea("CHBRN", &rings, null);
    try surf.endFeature();

    // Unbanded (no ViewingGroup in the catalogue) defaults to Standard.
    const seaare = rs.FeatureMeta{ .class = "SEAARE" };
    try surf.beginFeature(&seaare);
    try surf.fillArea("CHBLK", &rings, null);
    try surf.endFeature();
    _ = try surf.endScene(a);

    try testing.expectEqual(@as(usize, 3), rec.feats.items.len);
    try testing.expectEqual(CDispCat.base, rec.feats.items[0].disp_cat);
    try testing.expectEqual(@as(i64, 45000), rec.feats.items[0].scamin);
    try testing.expectEqual(CDispCat.other, rec.feats.items[1].disp_cat);
    try testing.expectEqual(CDispCat.standard, rec.feats.items[2].disp_cat);
}

test "CFeature matches the C tile57_feature layout" {
    // The header spells this struct out by hand; a silent size/offset drift here
    // is a wrong read on the host side of the ABI, not a compile error.
    try testing.expectEqual(@sizeOf(CFeature), @sizeOf(extern struct { cls: [*:0]const u8, scamin: i64, plane: c_int, disp_cat: c_int }));
    try testing.expectEqual(@as(usize, 0), @offsetOf(CFeature, "cls"));
    try testing.expectEqual(@offsetOf(CFeature, "plane") + @sizeOf(c_int), @offsetOf(CFeature, "disp_cat"));
}
