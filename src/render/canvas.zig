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

pub const Canvas = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Fill closed rings with `color` under the NONZERO winding rule —
        /// holes are counter-oriented rings; overlapping same-direction rings
        /// (e.g. a flattened stroke's quads + join discs) fill uniformly with
        /// no double-compositing.
        fillPath: *const fn (*anyopaque, rings: []const []const Point, color: Color) anyerror!void,
        /// Stroke polylines `width_px` wide with round joins and round caps.
        /// `dash` is an [on, off] pixel pattern anchored at each line's start
        /// (null = solid).
        strokePath: *const fn (*anyopaque, lines: []const []const Point, width_px: f32, dash: ?[2]f32, color: Color) anyerror!void,
    };

    pub fn fillPath(self: Canvas, rings: []const []const Point, color: Color) anyerror!void {
        return self.vtable.fillPath(self.ptr, rings, color);
    }
    pub fn strokePath(self: Canvas, lines: []const []const Point, width_px: f32, dash: ?[2]f32, color: Color) anyerror!void {
        return self.vtable.strokePath(self.ptr, lines, width_px, dash, color);
    }
};

test {
    _ = @import("raster.zig");
    _ = @import("png.zig");
}
