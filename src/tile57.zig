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
//!   - High-level engine: `Chart` (open → render/inspect), `bakeArchive`, `style.build`
//!   - Portrayal assets:  `assets` (colortables, linestyles, sprite/pattern)
//!   - Style patching:    `chartstyle`
//!   - Tiling:            `mvt`, `tile`, `pmtiles`, `bake_enc`, `scene`
//!   - Raw formats:       `formats.{iso8211, s57, s101}`

const std = @import("std");

/// Library version (matches build.zig.zon and tile57_version()).
pub const version = "0.1.0";

// ---- high-level engine: open a Chart, render, bake, build a style ----
const chart = @import("chart.zig");
/// An embeddable chart source: `Chart.openBytes` / `Chart.openCells`, then
/// render / query / bake. See chart.zig.
pub const Chart = chart.Chart;
pub const Format = chart.Format;
pub const CellInput = chart.CellInput;
pub const Progress = chart.Progress;
// Streaming ENC_ROOT open (read cell bytes on demand, low memory): see
// Chart.openCellsStreaming.
pub const CellMeta = chart.CellMeta;
pub const CellBytes = chart.CellBytes;
pub const CellReadFn = chart.CellReadFn;
/// Bake an ENC_ROOT into one band-streamed PMTiles archive.
pub const bakeArchive = chart.bakeArchive;
/// Free bytes returned by the render / bake entry points.
pub const freeBytes = chart.freeBytes;

/// MapLibre style generation from a template + mariner S-52 display settings.
/// `build` is the single style builder (regenerates the full style with the mariner
/// baked in; the old template-patch pass is retired) — see assets.buildFromTemplate.
pub const style = struct {
    pub const build = assets.buildFromTemplate;
    pub const Mariner = chartstyle.MarinerSettings;
};

// ---- portrayal asset + style generation ----------------------------------
pub const assets = @import("style"); // colortables / line styles / style.json
pub const sprite = @import("sprite"); // S-101 sprite + area-fill pattern atlases
pub const chartstyle = @import("style").chartstyle; // mariner-driven MapLibre style patching

// ---- tiling / encoding ---------------------------------------------------
pub const mvt = @import("tiles").mvt; // Mapbox Vector Tile encode/decode
pub const tile = @import("tiles").tile; // web-mercator tiling + clipping
pub const pmtiles = @import("tiles").pmtiles; // PMTiles read/write
pub const bake_enc = @import("scene").bake_enc; // banded multi-cell ENC_ROOT → PMTiles
pub const scene = @import("scene"); // S-57 feature → MVT tile

// ---- raw S-57 / S-100 formats (advanced) ---------------------------------
pub const formats = struct {
    pub const iso8211 = @import("s57").iso8211; // ISO/IEC 8211 records
    pub const s57 = @import("s57"); // S-57 ENC cell parser + geometry
    pub const s101 = @import("s101"); // S-101 catalogue + adaptation + instructions
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(formats);
}
