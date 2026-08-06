//! Raster charts — a chart made of pictures, one module:
//!
//!   mbtiles     — the community MBTiles reader (vendored SQLite)
//!   bsb         — BSB/KAP decode: the discontinued NOAA raster charts
//!   bakebsb     — the KAP bake: one sheet -> the per-chart archive shape
//!   rasterchart — RasterChart: one open raster chart, whatever it came from
//!
//! A raster chart is a georeferenced pyramid of picture tiles: satellite imagery
//! the mariner supplies, an RNC baked from a BSB/KAP sheet, or another vendor's
//! chart rendered to tiles. It is a peer of `Chart`, not a subtype — it serves
//! tiles and nothing else: no features, no portrayal, no pick, no view output.
//!
//! Links libc (SQLite). Kept out of the pure package set so `zig build test`
//! stays libc-free and the `tiles` module stays pure std.

pub const mbtiles = @import("mbtiles.zig");
pub const bsb = @import("bsb.zig");
pub const bakebsb = @import("bakebsb.zig");
pub const rasterchart = @import("rasterchart.zig");

pub const RasterChart = rasterchart.RasterChart;
pub const Info = rasterchart.Info;
pub const Error = rasterchart.Error;
pub const Encoding = mbtiles.Encoding;
pub const Scheme = mbtiles.Scheme;
pub const ErrMsg = mbtiles.ErrMsg;

test {
    _ = mbtiles;
    _ = bsb;
    _ = bakebsb;
    _ = rasterchart;
}
