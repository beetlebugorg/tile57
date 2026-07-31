//! Render engine Surface contract — the vtable every output format implements.
//!
//! The engine calls these methods with geometry already projected into the
//! scene's coordinate space, clipped, and simplified. S-52 semantics are
//! preserved (color tokens, symbol names, scamin) so tile surfaces (MVT/MLT)
//! can serialize them for clients that re-style without re-baking; pixel
//! surfaces resolve them through a shared lowering layer.
//!
//! Rule: surfaces must NOT import s57, s101, or portray. If a surface needs a
//! fact the calls don't carry, that's an engine bug — extend the contract.
//!
//! Mirrors the original Go RenderSurface interface (internal/s52render).

const std = @import("std");
const font = @import("font.zig");
const Allocator = std.mem.Allocator;
const mvt = @import("tiles").mvt;

/// Tile-space integer point (coordinates in [0, extent]).
/// Aliased from mvt.Point so engine geometry (built by tile helpers that
/// return mvt.Point) passes directly to Surface calls without casting.
/// Pixel surfaces (PNG/PDF — future phases) will use a separate coordinate
/// type; for P0 (tile surfaces only) sharing mvt.Point is the right choice.
pub const TilePoint = mvt.Point;

/// An S-52 color token (e.g. "DEPMS", "CHBLK"). Pixel surfaces resolve to
/// hex via colortables at the scene palette; tile surfaces serialize as-is.
pub const ColorToken = []const u8;

/// An S-52 symbol or area-fill pattern name (e.g. "BCNCAR01", "DIAMOND1").
pub const SymbolName = []const u8;

/// Line dash pattern.
pub const Dash = enum { solid, dashed };

/// How a symbol was placed by the engine.
/// `.point`: at a feature anchor (node / centroid); rotation is the rule's.
/// `.line`: tessellated along a complex-linestyle curve; rotation follows the
/// line tangent and is inherently chart-relative (rot_north is always true).
/// Surfaces may treat the two differently (collision/declutter, serialization).
pub const SymbolPlacement = enum { point, line };

/// Depth range (metres) for fillArea on DEPARE / DRGARE features.
/// Null when the area is not a depth area.
pub const DepthRange = struct { d1: f32, d2: f32 };

/// Split an S-101 ColorFill token "NAME[,transparency]" into the colour name and
/// an alpha byte. `transparency` is the fraction transparent (0 = opaque .. 1 =
/// clear; e.g. `CHGRF,0.5` is 50% see-through), so alpha = (1 - transparency)*255.
/// No comma => fully opaque. Only area fills carry transparency (line/text tokens
/// have no comma, so they pass through unchanged).
pub fn fillToken(token: ColorToken) struct { name: []const u8, alpha: u8 } {
    const comma = std.mem.indexOfScalar(u8, token, ',') orelse return .{ .name = token, .alpha = 255 };
    const t = std.fmt.parseFloat(f64, std.mem.trim(u8, token[comma + 1 ..], " ")) catch 0;
    const a: u8 = @intFromFloat(std.math.clamp((1.0 - t) * 255.0, 0.0, 255.0));
    return .{ .name = token[0..comma], .alpha = a };
}

/// Text-label style carried by drawText.
///
/// An empty `halign` marks a MINIMAL label: no alignment/offset/halo/group was
/// specified by the producing rule (native fallback labels like the SWPARE
/// "swept to N" note). Surfaces emit/draw only what is specified — the mvt
/// surface serializes just text/color/size for a minimal label; a pixel
/// surface uses its defaults.
pub const TextStyle = struct {
    color: ColorToken,
    font_size: f64,
    weight: font.Weight = .regular, // CHARS weight (regular/bold); picks the face
    slant: font.Slant = .upright, // CHARS slant (upright/italic); picks the face
    halign: []const u8 = "", // "left" | "center" | "right" ("" = minimal label)
    valign: []const u8 = "", // "top" | "middle" | "bottom"
    offset_x: f64 = 0, // S-52 LocalOffset in mm (+x right / +y down)
    offset_y: f64 = 0,
    group: i64 = 0, // S-101 text group (§14.5)
};

/// Per-feature S-52 metadata, bracketed around each feature's draw calls via
/// beginFeature / endFeature. All pick data is pre-computed by the engine so
/// surfaces need not import s57/s101.
pub const BAND_UNKNOWN: u8 = 255;

pub const FeatureMeta = struct {
    display_priority: i64 = 0,
    /// S-101 DisplayPlane: 0 UnderRadar (default), 1 OverRadar. Outranks
    /// display_priority in paint order — S-52 PresLib §10.3.4.2: "the OVERRADAR
    /// flag takes precedence over the objects display priority".
    display_plane: i64 = 0,
    display_category: i64 = 1, // 0 base, 1 standard, 2 other
    vg: i64 = 0, // raw viewing group (0 = none)
    scamin: ?i64 = null, // SCAMIN 1:N denominator (null = no display limit)
    oscl: i64 = 0, // the source cell's X2 overscale gate denominator
    // (cscl/OVERSCALE_FACTOR, 0 = unknown): tagged on area fills +
    // patterns so the style can order/gate by overscale state;
    // on the OVERSC01 hatch (overscale=true) it is the show gate
    overscale: bool = false, // this feature IS the S-52 §10.1.10.2 overscale hatch
    // (AP(OVERSC01) over the cell's M_COVR coverage), shown only
    // while grossly overscale (denom < oscl, i.e. X2+)
    class: []const u8 = "", // S-57 object-class acronym (e.g. "LIGHTS")
    s57_json: []const u8 = "", // cursor-pick blob: acronym->value JSON or ""
    cell_name: []const u8 = "", // source ENC cell name or ""
    /// Usage band (tiles.band.Band ordinal) of the SOURCE cell, or BAND_UNKNOWN
    /// when the feature carries none — unknown never counts as fill-down.
    band: u8 = BAND_UNKNOWN,
    date_start: []const u8 = "",
    date_end: []const u8 = "",
    // S-52 boundary (§8.6.1) and point-symbol (§11.2.2) variant tags:
    //   2 = style-independent (common, omitted from tile)
    //   0/1 = plain/symbolized boundary or paper/simplified point pass.
    bnd: i64 = 2,
    pts: i64 = 2,
    // S-52 §8.6.2 suppressed boundary piece: geometry the producer masked as a
    // cell-limit edge (MASK/USAG), baked anyway so the meta-bounds inspection
    // view can outline meta objects; the standard display never shows it (the
    // meta classes are filtered out entirely unless meta-bounds is on).
    masked: bool = false,
};

/// The render engine Surface vtable.
///
/// Lifecycle per scene: beginScene → (beginFeature → draw calls → endFeature)* → endScene.
/// The engine walks features in WALK order — tile by tile, then cell record order
/// — NOT draw-priority order; `meta.display_priority` carries the priority and it is the
/// surface's job to order by it (the pixel, ascii and vector surfaces each buffer
/// the scene and sort at endScene). Geometry is already projected, clipped, and
/// simplified into the scene's coordinate space.
///
/// Adding an output format = one file implementing this vtable; no engine edits.
pub const Surface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called once per scene before any feature calls.
        beginScene: *const fn (*anyopaque, z: u8) anyerror!void,
        /// Begin one feature's draw calls. `meta` is valid only for the duration.
        beginFeature: *const fn (*anyopaque, meta: *const FeatureMeta) anyerror!void,
        /// Fill an area with a color token. `depth` is non-null for DEPARE/DRGARE.
        fillArea: *const fn (*anyopaque, token: ColorToken, rings: []const []const TilePoint, depth: ?DepthRange) anyerror!void,
        /// Tile a pattern fill over an area.
        fillPattern: *const fn (*anyopaque, name: SymbolName, rings: []const []const TilePoint) anyerror!void,
        /// Stroke a line. `valdco` carries the depth-contour value for DEPCNT labels.
        strokeLine: *const fn (*anyopaque, token: ColorToken, width_px: f64, dash: Dash, lines: []const []const TilePoint, valdco: ?f64) anyerror!void,
        /// Draw a point symbol. `placement` distinguishes anchor-placed symbols
        /// from linestyle-tessellated ones (see SymbolPlacement). `danger_depth`
        /// is non-null for DANGER01/02 on wreck/obstruction/rock classes
        /// (live-mariner depth swap); point placement only.
        drawSymbol: *const fn (*anyopaque, name: SymbolName, at: TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: SymbolPlacement, danger_depth: ?f64) anyerror!void,
        /// Draw a depth sounding (the engine has recognized it as a sounding glyph).
        drawSounding: *const fn (*anyopaque, depth_m: f64, swept: bool, low_acc: bool, at: TilePoint) anyerror!void,
        /// Draw a text label.
        drawText: *const fn (*anyopaque, text: []const u8, style: *const TextStyle, at: TilePoint) anyerror!void,
        /// End the current feature's draw calls.
        endFeature: *const fn (*anyopaque) anyerror!void,
        /// Finalize the scene; returns encoded bytes owned by `out`.
        endScene: *const fn (*anyopaque, out: Allocator) anyerror![]u8,

        // ---- Optional (appended; default null so existing vtable literals compile) ----

        /// A RENDER surface's display scale (settings.size_scale). Present on
        /// pixel/vector output surfaces so the engine can walk complex-linestyle
        /// periods display-scaled at render time. Null (=> 1.0) on the bake encoder.
        size_scale: ?*const fn (*anyopaque) f64 = null,
        /// Present ONLY on the bake encoder: store an un-tessellated clipped
        /// complex-linestyle run (tile-local integer points) + the style id so
        /// replay can re-lookup its LsInfo and re-walk the period at render time.
        /// The baked tile stays display-independent (the disk cache survives a
        /// display change). Null on render surfaces (they walk, not store).
        store_complex_run: ?*const fn (*anyopaque, style: []const u8, color: ColorToken, width_px: f64, arc0: f64, run: []const TilePoint) anyerror!void = null,
        /// Present on RENDER surfaces: the tile's available depth-contour
        /// ladder (distinct DEPCN valdco + DEPARE drval1 values, unsorted).
        /// The surface snaps the mariner's safety contour to the next DEEPER
        /// value in it (S-52: a safety contour absent from the data promotes
        /// to the next deeper one; the shading split and the bold line must
        /// coincide). replayTile calls this per tile before emitting; the
        /// slice is valid only for the call. Null on the bake encoder.
        set_contour_ladder: ?*const fn (*anyopaque, ladder: []const f64) void = null,
        /// Cursor-pick geometry for an area the chart does not fill. The pick
        /// (§10.8) replays the DRAWING, so an area whose only mark is the
        /// INFORM01 marker — M_NPUB, and any note area — answers a pick under
        /// that marker alone, and a click inside the area reports the water
        /// under it instead. The bake encoder stores these rings on a
        /// query-only layer and the query surface tests them, so the area
        /// answers anywhere inside it. Null on render surfaces: nothing draws.
        pick_area: ?*const fn (*anyopaque, rings: []const []const TilePoint) anyerror!void = null,
        /// Draw a depth contour's VALUE, in the surface's own depth unit.
        ///
        /// The catalogue composes that label itself — DEPCNT03 calls SAFCON01,
        /// which picks one glyph per digit — but only ever in metres, because
        /// S-52 has no other unit. A chart shown in feet then drew a metric
        /// contour label beside feet soundings. So a surface that composes the
        /// label itself declares it here, the emitter SKIPS the catalogue's
        /// SAFCON glyphs, and the surface composes the same glyphs through
        /// sndfrm.safconSyms at its own unit. `valdco_m` is always metres; the
        /// surface converts.
        ///
        /// The contour twin of drawSounding, and optional for the same reason:
        /// null leaves the catalogue's metric glyphs in place, so a surface with
        /// no unit of its own (ascii, query, inspect) needs no change.
        draw_contour_label: ?*const fn (*anyopaque, valdco_m: f64, at: TilePoint) anyerror!void = null,
    };

    /// True when the surface composes contour labels itself, so the emitter
    /// drops the catalogue's metres-only SAFCON glyphs.
    pub fn wantsContourLabel(self: Surface) bool {
        return self.vtable.draw_contour_label != null;
    }

    pub fn drawContourLabel(self: Surface, valdco_m: f64, at: TilePoint) anyerror!void {
        if (self.vtable.draw_contour_label) |f| try f(self.ptr, valdco_m, at);
    }

    pub fn setContourLadder(self: Surface, ladder: []const f64) void {
        if (self.vtable.set_contour_ladder) |f| f(self.ptr, ladder);
    }

    /// True when the surface takes pick geometry — the bake encoder and the
    /// query surface. The emitter skips the work for every other surface.
    pub fn wantsPickArea(self: Surface) bool {
        return self.vtable.pick_area != null;
    }

    pub fn pickArea(self: Surface, rings: []const []const TilePoint) !void {
        if (self.vtable.pick_area) |f| try f(self.ptr, rings);
    }

    /// The S-52 effective safety contour against a tile's ladder: the least
    /// available value >= the mariner's, else the mariner's own. Shared by every
    /// render surface.
    ///
    /// The snap only ever goes DEEPER. Falling back to the deepest available rung
    /// (the old behaviour) could only fire when EVERY rung is shallower than the
    /// mariner asked for — if any were deeper, `next` would have matched it — so
    /// it always snapped the split DOWN and shaded water as safer than requested.
    /// The ladder is scanned per TILE, which made that misfire constantly: a tile
    /// holding only a drval1=0 depth area (open sound, contours all in the
    /// neighbouring tiles) snapped safety to 0 and painted every fill DEPMD, one
    /// tile-shaped box of wrong shade against its neighbours.
    pub fn effectiveSafety(safety: f64, ladder: []const f64) f64 {
        var next: ?f64 = null;
        for (ladder) |v| {
            if (v >= safety and (next == null or v < next.?)) next = v;
        }
        return next orelse safety;
    }

    pub fn beginScene(self: Surface, z: u8) anyerror!void {
        return self.vtable.beginScene(self.ptr, z);
    }
    pub fn beginFeature(self: Surface, meta: *const FeatureMeta) anyerror!void {
        return self.vtable.beginFeature(self.ptr, meta);
    }
    pub fn fillArea(self: Surface, token: ColorToken, rings: []const []const TilePoint, depth: ?DepthRange) anyerror!void {
        return self.vtable.fillArea(self.ptr, token, rings, depth);
    }
    pub fn fillPattern(self: Surface, name: SymbolName, rings: []const []const TilePoint) anyerror!void {
        return self.vtable.fillPattern(self.ptr, name, rings);
    }
    pub fn strokeLine(self: Surface, token: ColorToken, width_px: f64, dash: Dash, lines: []const []const TilePoint, valdco: ?f64) anyerror!void {
        return self.vtable.strokeLine(self.ptr, token, width_px, dash, lines, valdco);
    }
    pub fn drawSymbol(self: Surface, name: SymbolName, at: TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: SymbolPlacement, danger_depth: ?f64) anyerror!void {
        return self.vtable.drawSymbol(self.ptr, name, at, rot_deg, scale, rot_north, placement, danger_depth);
    }
    pub fn drawSounding(self: Surface, depth_m: f64, swept: bool, low_acc: bool, at: TilePoint) anyerror!void {
        return self.vtable.drawSounding(self.ptr, depth_m, swept, low_acc, at);
    }
    pub fn drawText(self: Surface, text: []const u8, style: *const TextStyle, at: TilePoint) anyerror!void {
        return self.vtable.drawText(self.ptr, text, style, at);
    }
    pub fn endFeature(self: Surface) anyerror!void {
        return self.vtable.endFeature(self.ptr);
    }
    pub fn endScene(self: Surface, out: Allocator) anyerror![]u8 {
        return self.vtable.endScene(self.ptr, out);
    }

    /// This render surface's display scale (1.0 when unset — the bake encoder).
    pub fn sizeScale(self: Surface) f64 {
        return if (self.vtable.size_scale) |f| f(self.ptr) else 1.0;
    }
    /// True on the bake encoder: complex runs are stored (not walked) here.
    pub fn canStoreComplexRun(self: Surface) bool {
        return self.vtable.store_complex_run != null;
    }
    /// Store one clipped, un-tessellated complex-linestyle run (bake path only).
    pub fn storeComplexRun(self: Surface, style: []const u8, color: ColorToken, width_px: f64, arc0: f64, run: []const TilePoint) anyerror!void {
        return self.vtable.store_complex_run.?(self.ptr, style, color, width_px, arc0, run);
    }
};

test "effectiveSafety: next-deeper snap, never shallower, empty ladder" {
    const t = @import("std").testing;
    const ladder = [_]f64{ 2, 5.4, 9.1, 18.2, 30 };
    // exact hit stays
    try t.expectEqual(@as(f64, 9.1), Surface.effectiveSafety(9.1, &ladder));
    // between rungs -> next DEEPER
    try t.expectEqual(@as(f64, 18.2), Surface.effectiveSafety(10, &ladder));
    try t.expectEqual(@as(f64, 5.4), Surface.effectiveSafety(2.2, &ladder));
    // deeper than everything -> the mariner's own value, NEVER a shallower rung:
    // snapping down would shade unsafe water in a safe shade
    try t.expectEqual(@as(f64, 50), Surface.effectiveSafety(50, &ladder));
    // a lone shallow rung (the tile-shaped-box case) must not drag the split to 0
    try t.expectEqual(@as(f64, 10), Surface.effectiveSafety(10, &.{0}));
    // no ladder -> the mariner's own value
    try t.expectEqual(@as(f64, 7), Surface.effectiveSafety(7, &.{}));
}
