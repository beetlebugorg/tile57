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
const sndfrm = @import("sndfrm.zig");
const cv = @import("canvas.zig");
const paint = @import("paint.zig");
const fontmod = @import("font.zig");
const dc = @import("declutter.zig");
const tile = @import("tiles").tile;

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

/// `Range.pattern` when the range is not an area-fill pattern — which is every
/// range except the `pattern` ones.
pub const NO_PATTERN: u32 = std.math.maxInt(u32);

/// One S-101 area-fill pattern cell, rasterized RGBA8 at this scene's screen
/// density. The host uploads it as a texture; `w`/`h` are its size in DEVICE PX,
/// which is also its on-screen tiling period, so no separate period is carried.
pub const PatternCell = struct {
    w: u32,
    h: u32,
    /// `w * h * 4` bytes, row-major. Arena-owned, like the rest of the scene.
    rgba: []const u8,
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
    /// Index into `Scene.patterns`, or `NO_PATTERN`. Set only on `pattern`
    /// ranges; see the tiling contract on `fillPattern`.
    pattern: u32,
    /// Resolved RGBA for the palette this scene was built with. Meaningless on a
    /// pattern range — the cell carries its own colours.
    color: [4]u8,
    kind: Kind,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

/// A finished scene. Everything borrows the arena passed to `endScene` and dies
/// with it.
pub const Scene = struct {
    vertices: []const Vertex,
    indices: []const u32,
    ranges: []const Range,
    /// Cells referenced by `Range.pattern`. Deduplicated: a chart full of one
    /// pattern uploads one texture, not one per feature.
    patterns: []const PatternCell,
};

// ---- the C view of a scene (mirrors tile57_gpu_* in include/tile57.h) -------
//
// These live here, not in capi.zig, so the layout assertions below run: capi.zig
// links libc and is deliberately outside the pure-Zig test build (lib_root.zig),
// where a test would compile nowhere and report green.

/// `PatternCell` flattened for C: a Zig slice is not POD across the seam.
pub const CPattern = extern struct {
    w: u32,
    h: u32,
    rgba: [*]const u8,
    rgba_len: usize,
};

/// `Scene` flattened for C. Every pointer is BORROWED and dies with `owner`,
/// which is the arena handle and opaque to the caller.
pub const CScene = extern struct {
    vertices: ?[*]const Vertex = null,
    vertex_count: usize = 0,
    indices: ?[*]const u32 = null,
    index_count: usize = 0,
    ranges: ?[*]const Range = null,
    range_count: usize = 0,
    patterns: ?[*]const CPattern = null,
    pattern_count: usize = 0,
    owner: ?*anyopaque = null,
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
    pattern: u32 = NO_PATTERN,
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
    /// Pattern cells in first-use order, and the name->index map that dedupes
    /// them. One density per scene, so the name alone is the key.
    patterns: std.ArrayList(PatternCell) = .empty,
    pattern_ix: std.StringHashMapUnmanaged(u32) = .empty,
    fnt: ?fontmod.Font = null,
    /// Shaped labels and the pool that ranks them. Held apart from `ops` because
    /// which labels survive is a property of the WHOLE scene, not of the order
    /// the engine walked it — so none may be admitted until `build` resolves the
    /// pool.
    labels: std.ArrayList(Op) = .empty,
    pool: dc.Pool = .{},
    glyph_cache: std.AutoHashMapUnmanaged(u16, []const []const cv.Point) = .empty,

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

    pub fn init(a: Allocator, colors: *const resolve.Colors, palette: resolve.PaletteId, settings: *const resolve.Settings, zoom: f64) !GpuSurface {
        return .{
            .a = a,
            .colors = colors,
            .palette = palette,
            .settings = settings,
            .zoom = zoom,
            .tessellator = try tess.Tessellator.init(a),
            .fnt = fontmod.Font.init(fontmod.notosans) catch null,
        };
    }

    pub fn deinit(self: *GpuSurface) void {
        self.tessellator.deinit();
        self.ops.deinit(self.a);
        self.patterns.deinit(self.a);
        self.pattern_ix.deinit(self.a);
        self.labels.deinit(self.a);
        self.pool.deinit(self.a);
        self.glyph_cache.deinit(self.a);
    }

    pub fn asSurface(self: *GpuSurface) rs.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Place the NEXT tile's geometry. A view walks many tiles into ONE scene, so
    /// paint order, range packing and above all the label pool span the whole
    /// view — a per-tile pool would let a name collide with itself across a seam.
    pub fn setTile(self: *GpuSurface, z: u8, x: u32, y: u32) void {
        const n = std.math.exp2(@as(f64, @floatFromInt(z)));
        self.tile_scale = 1.0 / (n * @as(f64, @floatFromInt(tile.EXTENT)));
        self.tile_ox = @as(f64, @floatFromInt(x)) / n;
        self.tile_oy = @as(f64, @floatFromInt(y)) / n;
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

    /// The device scale local offsets are sized in. Like the vector surface, this
    /// path hands the HOST reference-px sizes and does not draw them itself, so
    /// unless it is told the density it emits marks in units the host does not
    /// draw in. Both factors default to 1.0.
    fn refDev(self: *const GpuSurface) f64 {
        return self.settings.size_scale * self.settings.device_scale;
    }

    /// refDev with the mariner's extra SOUNDING multiplier folded in — sizes each
    /// digit AND its pivot-baked spacing together, so a 3-digit sounding grows
    /// without colliding with itself (mariner.sounding_size_scale, 1.0 = none).
    fn soundingDev(self: *const GpuSurface) f64 {
        return self.refDev() * self.settings.sounding_size_scale;
    }

    /// refDev with the mariner's extra TEXT multiplier — the one scale that sizes
    /// a label AND its collision box, so enlarged labels still declutter
    /// correctly (mariner.text_size_scale, 1.0 = none).
    fn textDev(self: *const GpuSurface) f64 {
        return self.refDev() * self.settings.text_size_scale;
    }

    /// Surface contract: this surface's display scale, so the engine walks
    /// complex-linestyle periods display-scaled and a HiDPI host gets both wider
    /// spacing and bigger bricks.
    fn sizeScale(ctx: *anyopaque) f64 {
        return sp(ctx).refDev();
    }

    fn rgba(self: *const GpuSurface, token: rs.ColorToken) [4]u8 {
        const split = rs.fillToken(token);
        // Unmapped tokens paint magenta, same as the other surfaces — visible,
        // never silent.
        const c = self.colors.get(self.palette, split.name) orelse resolve.Rgb{ .r = 255, .g = 0, .b = 255 };
        return .{ c.r, c.g, c.b, split.alpha };
    }

    fn push(self: *GpuSurface, kind: Kind, color: [4]u8, geom: Geom) !void {
        try self.pushPattern(kind, color, NO_PATTERN, geom);
    }

    fn pushPattern(self: *GpuSurface, kind: Kind, color: [4]u8, pattern: u32, geom: Geom) !void {
        try self.ops.append(self.a, .{
            .paint_key = paint.key(kind, self.cur.display_priority, self.cur.display_plane, self.settings.radar_overlay),
            .seq = self.ops.items.len,
            .kind = kind,
            .color = color,
            .scamin = if (self.cur.scamin) |s| @floatFromInt(s) else 0,
            .disp_cat = @intCast(std.math.clamp(self.cur.display_category, 0, 2)),
            .map_align = 0,
            .pattern = pattern,
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

    /// An area-fill pattern: the polygon interior, plus the cell to tile over it.
    ///
    /// THE HOST CONTRACT. The geometry is an ordinary tessellated interior — the
    /// tiling is the host's, because it happens per-fragment at the live camera
    /// scale and baking it here would mean re-tessellating on every zoom. The
    /// cell is rasterized at this scene's density, so `w`/`h` ARE the on-screen
    /// period in device px: the host samples it 1:1, phase-anchored to the WORLD
    /// origin (not the screen), so the pattern stays fixed to the chart under a
    /// pan instead of swimming across it. Vertex `x,y` is all that is needed to
    /// derive that phase, so nothing extra rides the vertex.
    fn fillPattern(ctx: *anyopaque, name: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        const store = self.store orelse return;
        if (!resolve.visible(&self.cur, name, self.zoom, self.settings)) return;
        // Same density the pixel path rasterizes at, so a pattern repeats at the
        // same on-screen period on every surface.
        const ppm: f32 = @floatCast(sndfrm.SYMBOL_SCALE * 100.0 * self.refDev());
        const cell = store.getPattern(name, ppm) orelse return;
        const ix = try self.internPattern(name, cell);
        try self.pushPattern(.pattern, .{ 0, 0, 0, 255 }, ix, .{ .fill = .{ .rings = rings, .rule = .nonzero } });
    }

    /// Intern a cell by name, copying its pixels. The store's cache owns the
    /// original and may evict it before `build` runs; the scene must outlive that.
    fn internPattern(self: *GpuSurface, name: rs.SymbolName, cell: *const cv.Pattern) !u32 {
        const gop = try self.pattern_ix.getOrPut(self.a, name);
        if (gop.found_existing) return gop.value_ptr.*;
        // The name is a slice into the decoded tile, which the same eviction can
        // free — dupe it, since it is this map's key.
        gop.key_ptr.* = try self.a.dupe(u8, name);
        gop.value_ptr.* = @intCast(self.patterns.items.len);
        try self.patterns.append(self.a, .{
            .w = cell.w,
            .h = cell.h,
            .rgba = try self.a.dupe(u8, cell.rgba),
        });
        return gop.value_ptr.*;
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
        try self.emitMark(.symbol, s, at, rot_deg, scale, self.refDev(), rot_north);
    }

    fn drawSounding(ctx: *anyopaque, depth_m: f64, swept: bool, low_acc: bool, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        const store = self.store orelse return;
        if (!resolve.visible(&self.cur, null, self.zoom, self.settings)) return;
        // Bold/faint split at the mariner's LIVE safety depth (metres), value in
        // the mariner's unit — the same composition the pixel and vector paths
        // run, from the one shared SNDFRM routine.
        const feet = self.settings.depth_unit == .feet;
        const shown = if (feet) depth_m * sndfrm.M_TO_FT else depth_m;
        const prefix: []const u8 = if (depth_m <= self.settings.safety_depth) "SOUNDS" else "SOUNDG";
        const list = try sndfrm.syms(self.a, prefix, shown, swept, low_acc, feet);
        // A sounding is a SYMBOL, not text: every one draws, none enters a
        // collision pool, and each digit glyph self-positions by its own pivot —
        // so the whole number is emitted at the one anchor. Screen-upright under
        // a rotated view, sized by soundingDev so digit and spacing grow together.
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |glyph| {
            if (glyph.len == 0) continue;
            const s = store.get(glyph) orelse continue;
            try self.emitMark(.sounding, s, at, 0, sndfrm.SYMBOL_SCALE, self.soundingDev(), false);
        }
    }

    /// A label: shaped into outline rings now, admitted only if it wins its space.
    ///
    /// The glyphs become an ordinary mark — world anchor plus local reference-px
    /// rings — so a label rides the chart, stays screen-upright and keeps its size
    /// under zoom by exactly the machinery symbols already use. What it does NOT
    /// get is the host's own text pipeline: these are filled outlines, not an SDF
    /// atlas, and no halo is emitted (the style carries none; the pixel path
    /// resolves its own).
    fn drawText(ctx: *anyopaque, text: []const u8, style: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (!resolve.visible(&self.cur, null, self.zoom, self.settings)) return;
        if (!resolve.textGroupVisible(style.group, self.settings)) return;
        const f = &(self.fnt orelse return);
        const px: f32 = @floatCast((if (style.font_size > 0) style.font_size else 12) * self.textDev());
        if (px <= 1) return;

        // Shape: pen advances left to right, in local reference px.
        var pen: f32 = 0;
        var gids = std.ArrayList(struct { gid: u16, x: f32 }).empty;
        defer gids.deinit(self.a);
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            const gid = f.glyphIndex(cp);
            try gids.append(self.a, .{ .gid = gid, .x = pen });
            pen += f.advance(gid) * px;
        }
        if (pen <= 0) return;

        // Alignment + the S-52 LocalOffset (mm, +y down) -> the baseline origin,
        // anchor-local. Same arithmetic as the pixel and vector paths, so a label
        // sits in the same place whichever surface draws it.
        const mm_px: f32 = @floatCast(sndfrm.SYMBOL_SCALE * 100.0 * self.textDev());
        const halign = if (style.halign.len > 0) style.halign else "center";
        const valign = if (style.valign.len > 0) style.valign else "middle";
        var x0: f32 = @as(f32, @floatCast(style.offset_x)) * mm_px;
        if (std.mem.eql(u8, halign, "center")) x0 -= pen / 2;
        if (std.mem.eql(u8, halign, "right")) x0 -= pen;
        var baseline: f32 = @as(f32, @floatCast(style.offset_y)) * mm_px;
        if (std.mem.eql(u8, valign, "top")) {
            baseline += f.ascent * px;
        } else if (std.mem.eql(u8, valign, "middle")) {
            baseline += (f.ascent - f.descent) / 2 * px;
        } else {
            baseline -= f.descent * px;
        }

        var rings = std.ArrayList([]const [2]f32).empty;
        for (gids.items) |g| {
            for (try self.glyphOutline(g.gid)) |contour| {
                if (contour.len < 3) continue;
                const pts = try self.a.alloc([2]f32, contour.len);
                // em units, y UP -> local reference px, y DOWN.
                for (contour, 0..) |p, i| pts[i] = .{ x0 + g.x + p.x * px, baseline - p.y * px };
                try rings.append(self.a, pts);
            }
        }
        if (rings.items.len == 0) return; // all-whitespace run: nothing to place

        // The collision box, in the screen frame this scene is for. The host owns
        // the camera, but a pan only translates every box alike and so cannot
        // change which labels collide; the zoom is what sets their relative size,
        // and that is known. Ordinary labels are screen-upright, so no rotation
        // enters the box either.
        const sc = self.screenPx(at);
        const box = dc.Box{
            .x0 = sc[0] + x0,
            .y0 = sc[1] + baseline - f.ascent * px,
            .x1 = sc[0] + x0 + pen,
            .y1 = sc[1] + baseline + f.descent * px,
        };
        try self.pool.add(self.a, self.labels.items.len, style.group, self.cur.class, text, box);
        try self.labels.append(self.a, .{
            .paint_key = paint.key(.text, self.cur.display_priority, self.cur.display_plane, self.settings.radar_overlay),
            // Labels sort among themselves by emission order, which is the SENC
            // sequence the pool already used to break its own ties.
            .seq = self.labels.items.len,
            .kind = .text,
            .color = self.rgba(style.color),
            .scamin = if (self.cur.scamin) |s| @floatFromInt(s) else 0,
            .disp_cat = @intCast(std.math.clamp(self.cur.display_category, 0, 2)),
            .map_align = 0,
            .geom = .{ .mark = .{
                .anchor = at,
                .rings = try rings.toOwnedSlice(self.a),
                // TrueType contours wind for the nonzero rule; even-odd would
                // punch the bowl of every 'o' back out.
                .rule = .nonzero,
            } },
        });
    }

    /// World position in screen px at this scene's zoom — the frame the pool
    /// measures collisions and repeat distances in.
    fn screenPx(self: *const GpuSurface, at: rs.TilePoint) [2]f64 {
        const w = self.worldOf(at);
        const s = 256.0 * std.math.exp2(self.zoom);
        return .{ @as(f64, w[0]) * s, @as(f64, w[1]) * s };
    }

    fn glyphOutline(self: *GpuSurface, gid: u16) ![]const []const cv.Point {
        if (self.glyph_cache.get(gid)) |hit| return hit;
        const out = try self.fnt.?.outline(self.a, gid);
        try self.glyph_cache.put(self.a, gid, out);
        return out;
    }

    /// Flatten a symbol's paths into local reference-px rings, rotated.
    ///
    /// `scale` is the engine's SYMBOL_SCALE — screen px per 0.01 mm — but symbol
    /// contours are in mm user units, so the 100 converts mm to the 0.01 mm the
    /// scale is quoted in. `dev` is the display density (refDev for point
    /// symbols, soundingDev for digits). Dropping either shrinks every mark by
    /// that factor; the pixel and vector paths both apply the same product.
    fn emitMark(self: *GpuSurface, kind: Kind, s: *const sym.Symbol, at: rs.TilePoint, rot_deg: f64, scale: f64, dev: f64, rot_north: bool) !void {
        const rad = rot_deg * std.math.pi / 180.0;
        const cs: f32 = @floatCast(@cos(rad));
        const sn: f32 = @floatCast(@sin(rad));
        const k: f32 = @floatCast(scale * 100.0 * dev);
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
        // Rank the whole label set BEFORE any of it becomes geometry, then admit
        // only the survivors. Text sorts last by paint_key either way, so this
        // costs the ops sort nothing.
        var kept = try self.pool.resolve(self.a, dc.REPEAT_PX);
        defer kept.deinit(self.a);
        for (self.labels.items, 0..) |label, i| {
            if (kept.has(i)) try self.ops.append(self.a, label);
        }

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
                    prev.pattern == op.pattern and
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
                .pattern = op.pattern,
                .kind = op.kind,
                .color = op.color,
            });
        }
        return .{
            .vertices = try verts.toOwnedSlice(arena),
            .indices = try indices.toOwnedSlice(arena),
            .ranges = try ranges.toOwnedSlice(arena),
            .patterns = try arena.dupe(PatternCell, self.patterns.items),
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

/// Minimal store for the mark tests: drawSymbol/drawSounding return early
/// without one. Every name resolves to the same 2x2 mm square centred on its
/// pivot, so a test counts glyphs by counting geometry.
const FakeStore = struct {
    square: sym.Symbol,
    const vt = sym.SymbolStore.VTable{ .get = get, .getPattern = getPattern };
    /// Two distinct 2x2 cells, so a test can tell dedup from collapse.
    var cell_a = cv.Pattern{ .w = 2, .h = 2, .rgba = &([_]u8{0xAA} ** 16) };
    var cell_b = cv.Pattern{ .w = 2, .h = 2, .rgba = &([_]u8{0xBB} ** 16) };
    fn getPattern(_: *anyopaque, name: []const u8, _: f32) ?*const cv.Pattern {
        if (std.mem.eql(u8, name, "NONE")) return null;
        return if (std.mem.eql(u8, name, "DIAMOND1")) &cell_b else &cell_a;
    }
    fn get(ctx: *anyopaque, _: []const u8) ?*const sym.Symbol {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return &self.square;
    }
    const ring = [_]cv.Point{ .{ .x = -1, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = 1, .y = 1 }, .{ .x = -1, .y = 1 } };
    const contours = [_][]const cv.Point{&ring};
    fn make() FakeStore {
        return .{ .square = .{
            .paths = &.{.{ .fill = .{ .r = 10, .g = 20, .b = 30 }, .contours = &contours }},
            .pivot = .{ .x = 0, .y = 0 },
        } };
    }
};

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

/// Emit one sounding and return its finished scene.
fn soundingScene(a: Allocator, settings: *const resolve.Settings, depth_m: f64) !Scene {
    var colors = try resolve.Colors.init(a, "");
    var gs = try testSurface(a, &colors, settings);
    var fake = FakeStore.make();
    gs.store = .{ .ptr = &fake, .vtable = &FakeStore.vt };
    const surf = gs.asSurface();
    const meta = rs.FeatureMeta{ .class = "SOUNDG", .display_priority = 27 };
    try surf.beginFeature(&meta);
    try surf.drawSounding(depth_m, false, false, .{ .x = 2000, .y = 2000 });
    try surf.endFeature();
    return gs.build(a);
}

test "gpu: a sounding emits one mark per composed SNDFRM glyph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = resolve.Settings{}; // safety_depth 10 m, metres

    // 4.0 m composes to a single glyph (SOUNDS14); 12.5 m to three (SOUNDG22,
    // SOUNDG11, SOUNDG55 — two integer digits plus the subscript tenth). The
    // digits are what make a sounding a NUMBER rather than one mark, so pin the
    // ratio, not just "something was emitted".
    const one = try soundingScene(a, &settings, 4.0);
    const three = try soundingScene(a, &settings, 12.5);
    try testing.expect(one.vertices.len > 0);
    try testing.expectEqual(one.vertices.len * 3, three.vertices.len);
    try testing.expectEqual(one.indices.len * 3, three.indices.len);
}

test "gpu: a sounding's glyphs coalesce into one sounding-class range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = resolve.Settings{};

    const scene = try soundingScene(a, &settings, 12.5);
    // Three glyphs, one anchor, one paint_key: one draw, not three.
    try testing.expectEqual(@as(usize, 1), scene.ranges.len);
    try testing.expectEqual(Kind.sounding, scene.ranges[0].kind);
    try testing.expectEqual(paint.key(.sounding, 27, 0, false), scene.ranges[0].paint_key);
    // Every glyph rides the anchor's world position; the digits are local px.
    for (scene.vertices) |v| {
        try testing.expectEqual(scene.vertices[0].x, v.x);
        try testing.expectEqual(scene.vertices[0].y, v.y);
    }
}

test "gpu: a mark's local offset carries the mm->0.01mm factor and the device scale" {
    // The bug this pins: emitMark used `scale` raw. SYMBOL_SCALE is quoted in px
    // per 0.01 mm but symbol contours are mm, so every mark came out 100x too
    // small — and ignored size_scale/device_scale entirely, which this path must
    // apply itself because the host draws the offsets without rescaling them.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var gs = try testSurface(a, &colors, &settings);
    var fake = FakeStore.make();
    gs.store = .{ .ptr = &fake, .vtable = &FakeStore.vt };
    const surf = gs.asSurface();

    const meta = rs.FeatureMeta{ .class = "WRECKS", .display_priority = 12 };
    try surf.beginFeature(&meta);
    try surf.drawSymbol("BOYLAT13", .{ .x = 2000, .y = 2000 }, 0, sndfrm.SYMBOL_SCALE, false, .point, null);
    try surf.endFeature();

    const scene = try gs.build(a);
    // The square's corner sits 1 mm from the pivot: 1 * SYMBOL_SCALE * 100 px.
    const want: f32 = @floatCast(sndfrm.SYMBOL_SCALE * 100.0);
    var max_ox: f32 = 0;
    for (scene.vertices) |v| max_ox = @max(max_ox, @abs(v.ox));
    try testing.expectApproxEqAbs(want, max_ox, 1e-5);
}

test "gpu: sounding_size_scale grows the digits and their spacing together" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = resolve.Settings{};
    const big = resolve.Settings{ .sounding_size_scale = 2.0 };

    const s1 = try soundingScene(a, &plain, 12.5);
    const s2 = try soundingScene(a, &big, 12.5);
    try testing.expectEqual(s1.vertices.len, s2.vertices.len);
    // Uniform 2x on every local offset — the pivot-baked spacing between digits
    // is itself an offset, so it scales with them and a grown sounding cannot
    // collide with itself.
    for (s1.vertices, s2.vertices) |v1, v2| {
        try testing.expectApproxEqAbs(v1.ox * 2.0, v2.ox, 1e-5);
        try testing.expectApproxEqAbs(v1.oy * 2.0, v2.oy, 1e-5);
    }
}

const pat_ring = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 100 }, .{ .x = 0, .y = 100 } };
const pat_rings = [_][]const rs.TilePoint{&pat_ring};

test "gpu: a pattern fill emits interior geometry plus a cell reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var gs = try testSurface(a, &colors, &settings);
    var fake = FakeStore.make();
    gs.store = .{ .ptr = &fake, .vtable = &FakeStore.vt };
    const surf = gs.asSurface();

    // The fill beneath and the pattern over it: same feature, same priority,
    // ordered by class (area 0 < pattern 1) so the pattern paints on top.
    const meta = rs.FeatureMeta{ .class = "DEPARE", .display_priority = 12 };
    try surf.beginFeature(&meta);
    try surf.fillArea("DEPVS", &pat_rings, null);
    try surf.fillPattern("DRGARE01", &pat_rings);
    try surf.endFeature();

    const scene = try gs.build(a);
    try testing.expectEqual(@as(usize, 2), scene.ranges.len);
    try testing.expectEqual(Kind.area, scene.ranges[0].kind);
    try testing.expectEqual(Kind.pattern, scene.ranges[1].kind);
    // The plain fill carries no cell; the pattern does, and it is real geometry
    // (a host that ignored the interior would draw nothing).
    try testing.expectEqual(NO_PATTERN, scene.ranges[0].pattern);
    try testing.expect(scene.ranges[1].pattern != NO_PATTERN);
    try testing.expect(scene.ranges[1].index_count > 0);
    try testing.expectEqual(@as(usize, 1), scene.patterns.len);
    try testing.expectEqual(@as(u32, 2), scene.patterns[0].w);
    try testing.expectEqual(@as(usize, 16), scene.patterns[0].rgba.len);
}

test "gpu: identical patterns dedupe to one cell, distinct ones do not merge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var gs = try testSurface(a, &colors, &settings);
    var fake = FakeStore.make();
    gs.store = .{ .ptr = &fake, .vtable = &FakeStore.vt };
    const surf = gs.asSurface();

    const meta = rs.FeatureMeta{ .class = "DEPARE", .display_priority = 12 };
    try surf.beginFeature(&meta);
    try surf.fillPattern("DRGARE01", &pat_rings);
    try surf.fillPattern("DRGARE01", &pat_rings); // same cell
    try surf.fillPattern("DIAMOND1", &pat_rings); // different cell
    try surf.endFeature();

    const scene = try gs.build(a);
    // Two textures uploaded, not three: a chart full of one pattern must not
    // upload it once per feature.
    try testing.expectEqual(@as(usize, 2), scene.patterns.len);
    try testing.expectEqual(@as(u8, 0xAA), scene.patterns[0].rgba[0]);
    try testing.expectEqual(@as(u8, 0xBB), scene.patterns[1].rgba[0]);
    // The two DRGARE01 fills coalesce into one draw; DIAMOND1 cannot join them,
    // because coalescing across cells would silently paint one with the other.
    try testing.expectEqual(@as(usize, 2), scene.ranges.len);
    try testing.expectEqual(@as(u32, 0), scene.ranges[0].pattern);
    try testing.expectEqual(@as(u32, 1), scene.ranges[1].pattern);
}

test "gpu: an unknown pattern name emits nothing rather than an untiled block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var gs = try testSurface(a, &colors, &settings);
    var fake = FakeStore.make();
    gs.store = .{ .ptr = &fake, .vtable = &FakeStore.vt };
    const surf = gs.asSurface();

    const meta = rs.FeatureMeta{ .class = "DEPARE", .display_priority = 12 };
    try surf.beginFeature(&meta);
    try surf.fillPattern("NONE", &pat_rings);
    try surf.endFeature();

    const scene = try gs.build(a);
    // A catalogue gap must not become a flat opaque polygon over the chart.
    try testing.expectEqual(@as(usize, 0), scene.ranges.len);
    try testing.expectEqual(@as(usize, 0), scene.patterns.len);
}

test "gpu: a pattern cell survives the store evicting its pixels" {
    // The lifetime trap the pixel path documents: `name` and the cell both point
    // into caches that an eviction can free before build() runs, so the scene
    // must own copies.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var gs = try testSurface(a, &colors, &settings);
    var fake = FakeStore.make();
    gs.store = .{ .ptr = &fake, .vtable = &FakeStore.vt };
    const surf = gs.asSurface();

    var volatile_name = [_]u8{ 'D', 'R', 'G', 'A', 'R', 'E', '0', '1' };
    const meta = rs.FeatureMeta{ .class = "DEPARE", .display_priority = 12 };
    try surf.beginFeature(&meta);
    try surf.fillPattern(&volatile_name, &pat_rings);
    try surf.endFeature();

    // Evict: scribble over both the name and the cell's pixels.
    volatile_name = [_]u8{ 'X', 'X', 'X', 'X', 'X', 'X', 'X', 'X' };
    FakeStore.cell_a.rgba = &([_]u8{0} ** 16);

    const scene = try gs.build(a);
    FakeStore.cell_a.rgba = &([_]u8{0xAA} ** 16); // restore for other tests
    try testing.expectEqual(@as(usize, 1), scene.patterns.len);
    try testing.expectEqual(@as(u8, 0xAA), scene.patterns[0].rgba[0]);
}

/// A scene holding `n` labels placed by the caller.
const TextFixture = struct {
    gs: GpuSurface,
    /// Zoom 4 against a 4096 extent puts one tile unit on exactly one screen px
    /// (world * 256 * 2^4 == the tile coordinate), so the distances below read
    /// directly against REPEAT_PX and the font metrics.
    fn init(a: Allocator, colors: *const resolve.Colors, settings: *const resolve.Settings) !TextFixture {
        var gs = try GpuSurface.init(a, colors, .day, settings, 4.0);
        gs.tile_scale = 1.0 / 4096.0;
        return .{ .gs = gs };
    }
    fn label(self: *TextFixture, text: []const u8, x: i32, y: i32) !void {
        const surf = self.gs.asSurface();
        const meta = rs.FeatureMeta{ .class = "SEAARE", .display_priority = 3 };
        try surf.beginFeature(&meta);
        const style = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 26 };
        try surf.drawText(text, &style, .{ .x = x, .y = y });
        try surf.endFeature();
    }
    /// One label alone: the baseline a crowded scene is measured against.
    fn one(a: Allocator, colors: *const resolve.Colors, settings: *const resolve.Settings, text: []const u8) !Scene {
        var fx = try TextFixture.init(a, colors, settings);
        try fx.label(text, 2000, 2000);
        return fx.gs.build(a);
    }
};

test "gpu: a label becomes text-kind geometry that paints last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    var fx = try TextFixture.init(a, &colors, &settings);
    const surf = fx.gs.asSurface();

    // A label on a LOW-priority feature and geometry on a much higher one: text
    // is drawn last whatever its feature's priority (S-52 §10.3.4.1), so the
    // label must still land on top.
    const hi = rs.FeatureMeta{ .class = "LIGHTS", .display_priority = 30 };
    const ring = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 100 } };
    const rings = [_][]const rs.TilePoint{&ring};
    try surf.beginFeature(&hi);
    try surf.fillArea("DEPVS", &rings, null);
    try surf.endFeature();
    try fx.label("Rhode Island", 2000, 2000);

    const scene = try fx.gs.build(a);
    try testing.expectEqual(@as(usize, 2), scene.ranges.len);
    try testing.expectEqual(Kind.text, scene.ranges[scene.ranges.len - 1].kind);
    try testing.expect(scene.ranges[1].index_count > 0);
    // The glyphs ride the anchor: one world position, outlines as local px.
    const first = scene.ranges[1].first_index;
    const v0 = scene.vertices[scene.indices[first]];
    for (scene.indices[first .. first + scene.ranges[1].index_count]) |i| {
        try testing.expectEqual(v0.x, scene.vertices[i].x);
        try testing.expectEqual(v0.y, scene.vertices[i].y);
    }
    try testing.expect(@abs(v0.ox) > 0 or @abs(v0.oy) > 0);
}

test "gpu: colliding labels resolve to one, and the loser emits no geometry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};

    // Baselines: what one of each label costs on its own. Counting RANGES would
    // not do — two labels that survive coalesce into a single draw call, which is
    // the point of the range packing.
    const alpha = (try TextFixture.one(a, &colors, &settings, "Alpha")).vertices.len;
    const bravo = (try TextFixture.one(a, &colors, &settings, "Bravo")).vertices.len;
    try testing.expect(alpha > 0 and bravo > 0);

    var apart = try TextFixture.init(a, &colors, &settings);
    try apart.label("Alpha", 0, 0);
    try apart.label("Bravo", 5000, 5000); // thousands of px away
    try testing.expectEqual(alpha + bravo, (try apart.gs.build(a)).vertices.len);

    var stacked = try TextFixture.init(a, &colors, &settings);
    try stacked.label("Alpha", 2000, 2000);
    try stacked.label("Bravo", 2000, 2000); // same spot, different text
    // The loser is dropped outright — not emitted transparent, not emitted
    // behind. Alpha wins: peers tie-break on emission order, the SENC sequence.
    try testing.expectEqual(alpha, (try stacked.gs.build(a)).vertices.len);
}

test "gpu: the same label repeated close by is dropped, far away is kept" {
    // The tile-clipping artefact declutter.zig exists to settle: one sea area
    // spanning several tiles is labelled once per tile, and the copies never
    // overlap, so collision alone would happily keep them all.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const settings = resolve.Settings{};
    const one = (try TextFixture.one(a, &colors, &settings, "Rhode Island")).vertices.len;

    // 200 screen px apart: no overlap, but inside REPEAT_PX (384).
    var near = try TextFixture.init(a, &colors, &settings);
    try near.label("Rhode Island", 2000, 2000);
    try near.label("Rhode Island", 2200, 2000);
    try testing.expectEqual(one, (try near.gs.build(a)).vertices.len);

    // 600 px apart: far enough that the repeat is informative, not redundant.
    var far = try TextFixture.init(a, &colors, &settings);
    try far.label("Rhode Island", 2000, 2000);
    try far.label("Rhode Island", 2600, 2000);
    try testing.expectEqual(one * 2, (try far.gs.build(a)).vertices.len);
}

test "gpu: text_size_scale grows the label and its collision box together" {
    // The property that makes the mariner's text slider safe: if the glyphs grew
    // but the box did not, enlarged labels would overlap on screen while the pool
    // still believed they were clear.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var colors = try resolve.Colors.init(a, "");
    const plain = resolve.Settings{};
    const big = resolve.Settings{ .text_size_scale = 2.0 };

    const sp_ = try TextFixture.one(a, &colors, &plain, "Annapolis");
    const sb = try TextFixture.one(a, &colors, &big, "Annapolis");
    try testing.expectEqual(sp_.vertices.len, sb.vertices.len);
    for (sp_.vertices, sb.vertices) |v1, v2| {
        try testing.expectApproxEqAbs(v1.ox * 2.0, v2.ox, 1e-4);
        try testing.expectApproxEqAbs(v1.oy * 2.0, v2.oy, 1e-4);
    }

    // And the box scaled with them. A label box is (ascent + descent) * px tall
    // — about 16 px at font 12, 33 px at 2x — so a pair 20 px apart clears at 1x
    // and collides at 2x. Had the box not grown, both would survive at both.
    const ann = sp_.vertices.len;
    const bal = (try TextFixture.one(a, &colors, &plain, "Baltimore")).vertices.len;
    var small = try TextFixture.init(a, &colors, &plain);
    try small.label("Annapolis", 2000, 2000);
    try small.label("Baltimore", 2000, 2020);
    try testing.expectEqual(ann + bal, (try small.gs.build(a)).vertices.len);

    var grown = try TextFixture.init(a, &colors, &big);
    try grown.label("Annapolis", 2000, 2000);
    try grown.label("Baltimore", 2000, 2020);
    try testing.expectEqual(ann, (try grown.gs.build(a)).vertices.len);
}

// ---- ABI layout ------------------------------------------------------------

test "gpu: the C scene structs match their tile57.h layout" {
    // include/tile57.h is hand-maintained, and a host compiles against IT while
    // linking against THIS. A field reordered on one side only is a silent
    // misread — wrong colours, wrong offsets, no error anywhere. These numbers
    // came from a C program compiled against the header (sizeof + offsetof), so
    // a Zig-side change that breaks the C view fails here instead of on a chart.
    try testing.expectEqual(@as(usize, 24), @sizeOf(Vertex));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Vertex, "ox"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Vertex, "scamin"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(Vertex, "disp_cat"));
    try testing.expectEqual(@as(usize, 21), @offsetOf(Vertex, "map_align"));

    try testing.expectEqual(@as(usize, 24), @sizeOf(Range));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Range, "first_index"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Range, "index_count"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Range, "paint_key"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Range, "pattern"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Range, "color"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(Range, "kind"));

    try testing.expectEqual(@as(usize, 24), @sizeOf(CPattern));
    try testing.expectEqual(@as(usize, 8), @offsetOf(CPattern, "rgba"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(CPattern, "rgba_len"));

    try testing.expectEqual(@as(usize, 72), @sizeOf(CScene));
    try testing.expectEqual(@as(usize, 64), @offsetOf(CScene, "owner"));

    // The header's tile57_gpu_kind values ARE paint.Layer — the S-52 class
    // tiebreak order, with pattern between area and line so an area-fill pattern
    // paints over its fill and under its boundary.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Kind.area));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Kind.pattern));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Kind.line));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Kind.symbol));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Kind.sounding));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(Kind.text));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), NO_PATTERN);
}
