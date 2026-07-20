//! Symbol geometry for the pixel path: pre-parsed, pre-flattened catalogue
//! symbol outlines the PixelSurface replays onto a Canvas at draw time
//! (scale/rotation applied per call) — true vector symbols, no bitmap blits.
//!
//! The render module stays pure, so it never parses SVG itself: a SymbolStore
//! (implemented over nanosvg in the sprite module, or a test fake) hands over
//! ready Symbol values. Geometry is in the catalogue's user units (mm for
//! S-101), with the S-52 pivot at `pivot` — the engine's `scale` argument
//! (screen px per 0.01 mm, e.g. 0.02835 ≈ 2.835 px/mm) maps units to pixels.

const std = @import("std");
const cv = @import("canvas.zig");

/// One styled subgroup of a symbol: closed/open contours sharing a fill and/or
/// stroke. Fills use the EVEN-ODD rule — the S-101 danger glyphs are compound
/// paths whose inner subpath is a hole, and nonzero winding fills it solid
/// (the same rule the sprite atlas rasterizer forces).
pub const StyledPath = struct {
    fill: ?cv.Color = null,
    stroke: ?struct { color: cv.Color, width: f32 } = null,
    /// Flattened contours in symbol user units.
    contours: []const []const cv.Point,
};

pub const Symbol = struct {
    paths: []const StyledPath,
    /// The S-52 pivot point in the symbol's (viewBox-normalized) user space —
    /// drawSymbol places THIS point at the anchor and rotates around it.
    pivot: cv.Point,
};

/// Half-extent of a symbol's outline about its pivot, scaled by `k` (the same
/// `scale * 100 * dev` a mark is drawn at). A sprite quad spans ±this around the
/// anchor, and the pivot-centred atlas cell drawn onto it reproduces the vector
/// placement. ONE definition, so the callback path (VectorSurface.emitSprite)
/// and the GPU-scene path size a symbol identically.
pub fn halfExtent(s: *const Symbol, k: f64) [2]f32 {
    var hw: f64 = 0;
    var hh: f64 = 0;
    for (s.paths) |p| for (p.contours) |contour| for (contour) |c| {
        hw = @max(hw, @abs((c.x - s.pivot.x) * k));
        hh = @max(hh, @abs((c.y - s.pivot.y) * k));
    };
    return .{ @floatCast(hw), @floatCast(hh) };
}

/// The lookup seam: name -> parsed symbol / rendered pattern cell (null =
/// unknown; the caller decides the fallback). Implementations own caching and
/// the returned memory.
pub const SymbolStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (*anyopaque, name: []const u8) ?*const Symbol,
        /// An S-101 AreaFill's seamless repeat cell, rasterized at `px_per_mm`
        /// device density (the canvas's screen scale).
        getPattern: *const fn (*anyopaque, name: []const u8, px_per_mm: f32) ?*const cv.Pattern,
    };

    pub fn get(self: SymbolStore, name: []const u8) ?*const Symbol {
        return self.vtable.get(self.ptr, name);
    }
    pub fn getPattern(self: SymbolStore, name: []const u8, px_per_mm: f32) ?*const cv.Pattern {
        return self.vtable.getPattern(self.ptr, name, px_per_mm);
    }
};

/// Flatten one nanosvg cubic-bezier run (npts = 1 + 3n floats-pairs, as the
/// sprite module's tg_svg_parse_paths stream carries them) into a polyline.
/// Fixed 12-step subdivision per cubic: deterministic, and ample for chart
/// glyphs (a few mm at ~3 px/mm).
pub fn flattenCubics(a: std.mem.Allocator, pts: []const f32, closed: bool) ![]cv.Point {
    const SUB = 12;
    if (pts.len < 2) return &.{};
    const n_curves = (pts.len / 2 - 1) / 3;
    var out = try std.ArrayList(cv.Point).initCapacity(a, 1 + n_curves * SUB + 1);
    out.appendAssumeCapacity(.{ .x = pts[0], .y = pts[1] });
    var c: usize = 0;
    while (c < n_curves) : (c += 1) {
        const o = c * 6;
        const p0x = pts[o];
        const p0y = pts[o + 1];
        const c1x = pts[o + 2];
        const c1y = pts[o + 3];
        const c2x = pts[o + 4];
        const c2y = pts[o + 5];
        const p1x = pts[o + 6];
        const p1y = pts[o + 7];
        var s: usize = 1;
        while (s <= SUB) : (s += 1) {
            const t = @as(f32, @floatFromInt(s)) / SUB;
            const u = 1 - t;
            const b0 = u * u * u;
            const b1 = 3 * u * u * t;
            const b2 = 3 * u * t * t;
            const b3 = t * t * t;
            out.appendAssumeCapacity(.{
                .x = b0 * p0x + b1 * c1x + b2 * c2x + b3 * p1x,
                .y = b0 * p0y + b1 * c1y + b2 * c2y + b3 * p1y,
            });
        }
    }
    if (closed) {
        const first = out.items[0];
        const last = out.items[out.items.len - 1];
        if (first.x != last.x or first.y != last.y) out.appendAssumeCapacity(first);
    }
    return out.toOwnedSlice(a);
}

test "flattenCubics: line-as-cubic stays straight, closed ring closes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A straight segment encoded as a cubic (control points on the line).
    const pts = [_]f32{ 0, 0, 1, 1, 2, 2, 3, 3 };
    const line = try flattenCubics(a, &pts, false);
    try std.testing.expectEqual(@as(usize, 13), line.len);
    for (line) |p| try std.testing.expectApproxEqAbs(p.x, p.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), line[line.len - 1].x, 1e-5);

    const ring = try flattenCubics(a, &pts, true);
    try std.testing.expectEqual(ring[0].x, ring[ring.len - 1].x);
}
