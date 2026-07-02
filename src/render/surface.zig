//! Render engine Surface contract — the vtable every output format implements.
//!
//! The engine calls these methods with geometry already projected into the
//! scene's coordinate space, clipped, and simplified. S-52 semantics are
//! preserved (color tokens, symbol names, scamin) so tile surfaces (MVT/MLT)
//! can serialize them for clients that re-style without re-baking; pixel
//! surfaces resolve them through a shared lowering layer.
//!
//! Rule: surfaces must NOT import s57, s100, or portray. If a surface needs a
//! fact the calls don't carry, that's an engine bug — extend the contract.
//!
//! Mirrors the original Go RenderSurface interface (internal/s52render).
//! See specs/render-engine.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mvt = @import("mvt");

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
    halign: []const u8 = "", // "left" | "center" | "right" ("" = minimal label)
    valign: []const u8 = "", // "top" | "middle" | "bottom"
    offset_x: f64 = 0,       // S-52 LocalOffset in mm (+x right / +y down)
    offset_y: f64 = 0,
    group: i64 = 0,          // S-101 text group (§14.5)
};

/// Per-feature S-52 metadata, bracketed around each feature's draw calls via
/// beginFeature / endFeature. All pick data is pre-computed by the engine so
/// surfaces need not import s57/s100.
pub const FeatureMeta = struct {
    draw_prio: i64 = 0,
    cat: i64 = 1,            // display category: 0 base, 1 standard, 2 other
    vg: i64 = 0,             // raw viewing group (0 = none)
    scamin: ?i64 = null,     // SCAMIN 1:N denominator (null = no display limit)
    class: []const u8 = "",  // S-57 object-class acronym (e.g. "LIGHTS")
    s57_json: []const u8 = "", // cursor-pick blob: acronym->value JSON or ""
    cell_name: []const u8 = "", // source ENC cell name or ""
    band: u8 = 0,            // NOAA navigational band (0 = finest)
    date_start: []const u8 = "",
    date_end: []const u8 = "",
    // S-52 boundary (§8.6.1) and point-symbol (§11.2.2) variant tags:
    //   2 = style-independent (common, omitted from tile)
    //   0/1 = plain/symbolized boundary or paper/simplified point pass.
    bnd: i64 = 2,
    pts: i64 = 2,
};

/// The render engine Surface vtable.
///
/// Lifecycle per scene: beginScene → (beginFeature → draw calls → endFeature)* → endScene.
/// The engine emits features in draw-priority order; geometry is already
/// projected, clipped, and simplified into the scene's coordinate space.
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
};
