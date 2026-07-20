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
    band: u8 = 0, // NOAA navigational band (0 = finest)
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
    };

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
