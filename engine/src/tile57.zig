//! tile57 — the public Zig API for the S-57 → MVT vector-tile + S-52 style engine.
//!
//! tile57 turns IHO S-57 ENC cells into Mapbox Vector Tiles plus a MapLibre
//! S-52 style and its portrayal assets (colour tables, line styles, sprite +
//! pattern atlases). It is high-performance and low-memory by design: cells are
//! indexed cheaply and parsed/portrayed lazily per requested tile, multi-cell
//! bakes stream band-by-band, and the foundational format/encode packages are
//! pure Zig (no libc).
//!
//! This module is the curated public surface. Add it as a dependency and
//! `@import("tile57")`. The C ABI in include/tile57.h is a thin shim over the
//! same Zig API (see capi.zig).
//!
//! Surface:
//!   - High-level engine: `Source` (open → tile), `bakeArchive`, `buildStyle`   [Phase 2]
//!   - Portrayal assets:  `assets` (colortables, linestyles, sprite/pattern)
//!   - Style patching:    `chartstyle`
//!   - Tiling:            `mvt`, `tile`, `pmtiles`, `bake_enc`, `s57_mvt`
//!   - Raw formats:       `formats.{iso8211, s57, s100}`

const std = @import("std");

/// Library version (matches build.zig.zon and tile57_version()).
pub const version = "0.1.0";

// ---- portrayal asset + style generation ----------------------------------
pub const assets = @import("assets"); // colortables / linestyles / style / manifest
pub const chartstyle = @import("chartstyle"); // mariner-driven MapLibre style patching

// ---- tiling / encoding ---------------------------------------------------
pub const mvt = @import("mvt"); // Mapbox Vector Tile encode/decode
pub const tile = @import("tile"); // web-mercator tiling + clipping
pub const pmtiles = @import("pmtiles"); // PMTiles read/write
pub const bake_enc = @import("bake_enc"); // banded multi-cell ENC_ROOT → PMTiles
pub const s57_mvt = @import("s57_mvt"); // S-57 feature → MVT tile

// ---- raw S-57 / S-100 formats (advanced) ---------------------------------
pub const formats = struct {
    pub const iso8211 = @import("iso8211"); // ISO/IEC 8211 records
    pub const s57 = @import("s57"); // S-57 ENC cell parser + geometry
    pub const s100 = @import("s100"); // S-100/S-101 catalogue + adaptation
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(formats);
}
