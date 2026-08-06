//! Tile encoding + addressing, one module:
//!
//!   mvt     — Mapbox Vector Tile encode/decode (protobuf model)
//!   mlt     — MapLibre Tile encoder (same feature model as mvt)
//!   gzip    — gzip compress/decompress (tile payloads, PMTiles internals)
//!   pmtiles — PMTiles v3 archive read/write
//!   tile    — web-mercator tile math: projection, extent, clipping,
//!             simplification (the geometry side of tiling)
//!   band    — compilation-scale -> zoom-range mapping (navigational bands)
//!   png     — RGBA8 <-> PNG (the picture tiles a raster chart is made of)
//!   filemap — cross-platform read-only mmap of a file (std has no portable one)
//!
//! Pure std; the leaf bundle everything tile-shaped builds on.

pub const mvt = @import("mvt.zig");
pub const mlt = @import("mlt.zig");
pub const gzip = @import("gzip.zig");
pub const pmtiles = @import("pmtiles.zig");
pub const tile = @import("tile.zig");
pub const band = @import("band.zig");
pub const png = @import("png.zig");
pub const filemap = @import("filemap.zig");

test {
    _ = mvt;
    _ = mlt;
    _ = gzip;
    _ = pmtiles;
    _ = tile;
    _ = band;
    _ = png;
    _ = filemap;
}
