//! The render engine's shared contracts and pixel machinery, one module:
//!
//!   surface  — the SEMANTIC seam every output format implements (color
//!              tokens, symbol names, S-52 meta). MVT/MLT serialize these
//!              verbatim; pixel surfaces resolve them.
//!   noop     — the discard surface (engine-only benchmarking).
//!   resolve  — the resolver: token -> RGB at a palette + the mariner display
//!              gates, mirroring the live MapLibre style semantics.
//!   canvas   — the PRIMITIVE seam pixel surfaces paint through (resolved
//!              colors + flattened geometry only; ≈ the original Go
//!              RenderSurface). One new pixel format = one new Canvas.
//!   raster   — RasterCanvas: scanline-AA software rasterizer (RGBA8).
//!   png      — RGBA8 -> PNG encoder (pure std, deterministic bytes).
//!   pixel    — PixelSurface: the resolve-and-draw Surface implementation
//!              (buffers ops, sorts by display_priority, paints through a Canvas).
//!   ascii    — AsciiSurface: the chart as a Unicode text grid (optional
//!              ANSI-256 color). The worked example of adding a backend.
//!   declutter— the label collision authority EVERY surface resolves through,
//!              so a crowded chart declutters the same way on all of them.
//!
//! Rule: nothing in this module imports s57, s101, or portray. If a surface
//! needs a fact the Surface calls don't carry, that's an engine bug — extend
//! the contract, never back-channel.

pub const surface = @import("surface.zig");
pub const noop = @import("noop.zig");
pub const inspect = @import("inspect.zig"); // recording surface (the `tile57 explore` learning tool)
pub const query = @import("query.zig"); // point-query surface (cursor object-query / pick)
pub const resolve = @import("resolve.zig");
pub const canvas = @import("canvas.zig");
pub const raster = @import("raster.zig");
pub const png = @import("png.zig");
pub const pixel = @import("pixel.zig");
pub const ascii = @import("ascii.zig");
pub const tess = @import("tess.zig");
pub const paint = @import("paint.zig");
pub const gpu = @import("gpu.zig");
pub const kitty = @import("kitty.zig");
pub const symbols = @import("symbols.zig");
pub const sndfrm = @import("sndfrm.zig");
pub const font = @import("font.zig");
pub const pdf = @import("pdf.zig");
pub const cb_canvas = @import("cb_canvas.zig");
pub const vector = @import("vector.zig");
pub const declutter = @import("declutter.zig");
pub const labelcache = @import("labelcache.zig"); // per-tile label-candidate memo (the view label pass)

test {
    _ = paint;
    _ = gpu;
    _ = surface;
    _ = tess;
    _ = vector;
    _ = declutter;
    _ = labelcache;
    _ = noop;
    _ = inspect;
    _ = resolve;
    _ = canvas;
    _ = raster;
    _ = png;
    _ = pixel;
    _ = ascii;
    _ = symbols;
    _ = sndfrm;
    _ = font;
    _ = pdf;
}
