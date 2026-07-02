//! The Canvas: the PRIMITIVE drawing seam of the render engine — the
//! pixel-side counterpart of the semantic Surface. The pixel surface resolves
//! S-52 semantics (render_resolve: token -> RGB, display gates) and paints
//! through this interface, so a new pixel format is one new Canvas
//! implementation (RasterCanvas now; a PDF canvas later) and the resolver /
//! layout code is never rewritten.
//!
//! Mirrors the original Go RenderSurface (chartplotter-original pkg/s52render):
//! resolved colors and flattened geometry only — no S-52 tokens, symbol names,
//! or catalogue knowledge below this line.
//!
//! Geometry arrives fully transformed into the canvas's pixel space (y down).
//! P2 scope is fills + strokes; pattern fills (P3) and glyph runs (P4) extend
//! the vtable when their phases land.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Resolved straight-alpha RGBA color.
pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

/// Canvas-space point in float pixels (y down).
pub const Point = struct { x: f32, y: f32 };

/// Polygon fill rule. Chart areas + flattened strokes use `.nonzero` (holes
/// via counter-oriented rings; overlapping same-direction rings — a stroke's
/// quads and join discs — fill uniformly). Catalogue symbol outlines use
/// `.even_odd`: the S-101 compound glyphs encode holes as same-direction
/// subpaths, which nonzero would fill solid.
pub const FillRule = enum { nonzero, even_odd };

/// A seamless repeat cell (straight-alpha RGBA8) for pattern fills — one
/// S-101 AreaFill tiled at the canvas's pixel density. Tiling phase is
/// anchored to the canvas origin so adjacent polygons pattern seamlessly.
pub const Pattern = struct { w: u32, h: u32, rgba: []const u8 };

/// One positioned glyph of a shaped label. `x` is the pen offset from the
/// run origin in canvas px; `w1000` is the advance in PDF text units
/// (1000/em) so a text-object canvas can build its widths array; `cp` is
/// the source codepoint (ToUnicode / searchability).
pub const Glyph = struct { gid: u16, cp: u21, x: f32, w1000: u16 };

/// A shaped label, carried BOTH ways a canvas may want it: pre-flattened
/// outline contours in canvas px (raster paints these — identical metrics to
/// every other path), AND the glyph run + source string (a vector canvas
/// emits real text objects: embedded font, selectable, searchable).
pub const GlyphRun = struct {
    rings: []const []const Point,
    glyphs: []const Glyph,
    /// Baseline origin of the run in canvas px.
    origin: Point,
    /// Font size in canvas px.
    size: f32,
    color: Color,
    halo: ?Color,
    halo_w: f32,
    /// The source UTF-8 string (ToUnicode mapping).
    text: []const u8,
};

pub const Canvas = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Fill closed rings with `color` under `rule` (see FillRule).
        fillPath: *const fn (*anyopaque, rings: []const []const Point, color: Color, rule: FillRule) anyerror!void,
        /// Fill closed rings (nonzero) with a repeating pattern cell,
        /// canvas-anchored phase.
        fillPattern: *const fn (*anyopaque, rings: []const []const Point, pattern: *const Pattern) anyerror!void,
        /// Stroke polylines `width_px` wide with round joins and round caps.
        /// `dash` is an [on, off] pixel pattern anchored at each line's start
        /// (null = solid).
        strokePath: *const fn (*anyopaque, lines: []const []const Point, width_px: f32, dash: ?[2]f32, color: Color) anyerror!void,
        /// Draw one shaped label (see GlyphRun): raster canvases paint the
        /// outline contours; vector canvases may emit real text objects.
        drawGlyphRun: *const fn (*anyopaque, run: *const GlyphRun) anyerror!void,
    };

    pub fn fillPath(self: Canvas, rings: []const []const Point, color: Color, rule: FillRule) anyerror!void {
        return self.vtable.fillPath(self.ptr, rings, color, rule);
    }
    pub fn fillPattern(self: Canvas, rings: []const []const Point, pattern: *const Pattern) anyerror!void {
        return self.vtable.fillPattern(self.ptr, rings, pattern);
    }
    pub fn strokePath(self: Canvas, lines: []const []const Point, width_px: f32, dash: ?[2]f32, color: Color) anyerror!void {
        return self.vtable.strokePath(self.ptr, lines, width_px, dash, color);
    }
    pub fn drawGlyphRun(self: Canvas, run: *const GlyphRun) anyerror!void {
        return self.vtable.drawGlyphRun(self.ptr, run);
    }
};

test {
    _ = @import("raster.zig");
    _ = @import("png.zig");
    _ = @import("symbols.zig");
}
