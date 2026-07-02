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
//!              (buffers ops, sorts by draw_prio, paints through a Canvas).
//!
//! Rule: nothing in this module imports s57, s100, or portray. If a surface
//! needs a fact the Surface calls don't carry, that's an engine bug — extend
//! the contract, never back-channel.

pub const surface = @import("surface.zig");
pub const noop = @import("noop.zig");
pub const resolve = @import("resolve.zig");
pub const canvas = @import("canvas.zig");
pub const raster = @import("raster.zig");
pub const png = @import("png.zig");
pub const pixel = @import("pixel.zig");
pub const symbols = @import("symbols.zig");
pub const sndfrm = @import("sndfrm.zig");
pub const font = @import("font.zig");
pub const pdf = @import("pdf.zig");

test {
    _ = surface;
    _ = noop;
    _ = resolve;
    _ = canvas;
    _ = raster;
    _ = png;
    _ = pixel;
    _ = symbols;
    _ = sndfrm;
    _ = font;
    _ = pdf;
}
