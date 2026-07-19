//! cb_canvas.zig — the callback Canvas: a third cv.Canvas implementation
//! (alongside RasterCanvas and the PDF canvas) that forwards each resolved,
//! flattened primitive to a table of C function pointers. This is the seam a C
//! embedder uses to drive its own renderer (GPU or vector) from the same view
//! portrayal, receiving geometry instead of a rasterised PNG.
//!
//! Geometry is emitted in the canvas's PIXEL space (y down) — identical to what
//! RasterCanvas/PdfCanvas receive — and colours are fully resolved for the
//! active palette. Paint order is the endScene-sorted order (the embedder draws
//! calls in the order received; no priority key needed).
const std = @import("std");
const cv = @import("canvas.zig");

// ---- extern C ABI (mirrored in include/tile57.h) ---------------------------
pub const CPoint = extern struct { x: f32, y: f32 };
/// Packed 0xRRGGBBAA — see tile57_color in tile57.h.
pub const CColor = u32;

/// Multi-ring path: flat vertex array `pts` + `ring_starts[k]` = first vertex
/// index of ring k (ring k spans [ring_starts[k], ring_starts[k+1]), last runs
/// to `n`). Rings are implicitly closed.
pub const CRings = extern struct {
    pts: [*]const CPoint,
    n: u32,
    ring_starts: [*]const u32,
    ring_count: u32,
};

/// The paint table. Calls arrive in final paint order; `ctx` is passed back
/// verbatim. Coordinates are canvas pixels; widths are pixels.
pub const CCanvas = extern struct {
    ctx: ?*anyopaque,
    /// Fill closed rings; even_odd != 0 selects the even-odd rule.
    fill_path: *const fn (?*anyopaque, *const CRings, CColor, c_int) callconv(.c) void,
    /// Stroke polylines `width_px` wide; dash_on/off in px (0,0 = solid).
    stroke_path: *const fn (?*anyopaque, *const CRings, f32, f32, f32, CColor) callconv(.c) void,
    /// Fill rings with a repeating RGBA8 pattern cell (w*h*4 bytes).
    fill_pattern: *const fn (?*anyopaque, *const CRings, u32, u32, [*]const u8) callconv(.c) void,
    /// Draw a shaped label as flattened outline rings (canvas px), with an
    /// optional halo (halo.a == 0 => none).
    draw_glyphs: *const fn (?*anyopaque, *const CRings, CColor, CColor, f32) callconv(.c) void,
};

// ---- the Canvas implementation --------------------------------------------
pub const CbCanvas = struct {
    c: *const CCanvas,
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator, c: *const CCanvas) CbCanvas {
        return .{ .c = c, .a = a };
    }
    pub fn asCanvas(self: *CbCanvas) cv.Canvas {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = cv.Canvas.VTable{
        .fillPath = fillPath,
        .fillPattern = fillPattern,
        .strokePath = strokePath,
        .drawGlyphRun = drawGlyphRun,
    };

    fn color(c: cv.Color) CColor {
        return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | @as(u32, c.a);
    }

    // Flatten []const []const Point -> (pts, ring_starts). Arena-allocated;
    // the pointers are valid for the duration of the callback.
    fn build(self: *CbCanvas, rings: []const []const cv.Point) !struct { CRings, []CPoint, []u32 } {
        var n: usize = 0;
        for (rings) |r| n += r.len;
        const pts = try self.a.alloc(CPoint, n);
        const starts = try self.a.alloc(u32, rings.len);
        var i: usize = 0;
        for (rings, 0..) |r, k| {
            starts[k] = @intCast(i);
            for (r) |p| {
                pts[i] = .{ .x = p.x, .y = p.y };
                i += 1;
            }
        }
        return .{ CRings{
            .pts = pts.ptr,
            .n = @intCast(n),
            .ring_starts = starts.ptr,
            .ring_count = @intCast(rings.len),
        }, pts, starts };
    }

    fn fillPath(ptr: *anyopaque, rings: []const []const cv.Point, col: cv.Color, rule: cv.FillRule) anyerror!void {
        const self: *CbCanvas = @ptrCast(@alignCast(ptr));
        const built = try self.build(rings);
        var cr = built[0];
        self.c.fill_path(self.c.ctx, &cr, color(col), if (rule == .even_odd) 1 else 0);
    }

    fn strokePath(ptr: *anyopaque, lines: []const []const cv.Point, width_px: f32, dash: ?[2]f32, col: cv.Color) anyerror!void {
        const self: *CbCanvas = @ptrCast(@alignCast(ptr));
        const built = try self.build(lines);
        var cr = built[0];
        const on: f32 = if (dash) |d| d[0] else 0;
        const off: f32 = if (dash) |d| d[1] else 0;
        self.c.stroke_path(self.c.ctx, &cr, width_px, on, off, color(col));
    }

    fn fillPattern(ptr: *anyopaque, rings: []const []const cv.Point, pattern: *const cv.Pattern) anyerror!void {
        const self: *CbCanvas = @ptrCast(@alignCast(ptr));
        const built = try self.build(rings);
        var cr = built[0];
        self.c.fill_pattern(self.c.ctx, &cr, pattern.w, pattern.h, pattern.rgba.ptr);
    }

    fn drawGlyphRun(ptr: *anyopaque, run: *const cv.GlyphRun) anyerror!void {
        const self: *CbCanvas = @ptrCast(@alignCast(ptr));
        const built = try self.build(run.rings);
        var cr = built[0];
        const halo: CColor = if (run.halo) |h| color(h) else 0;
        self.c.draw_glyphs(self.c.ctx, &cr, color(run.color), halo, run.halo_w);
    }
};
