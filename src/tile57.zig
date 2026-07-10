//! tile57 — the public Zig API for turning S-57 ENC data into vector tiles.
//!
//! The pipeline: parse IHO S-57 cells, apply S-101 portrayal, and bake each cell
//! to its own MLT vector tiles in a PMTiles archive at its compilation scale. A
//! runtime compositor then stitches the per-cell archives into one tile for any
//! (z, x, y) on demand, using an ownership partition so cells never double-draw at
//! a seam. The same engine renders a chart to PNG or PDF, and generates the
//! MapLibre S-52 style plus its portrayal assets (color tables, line styles,
//! sprite and pattern atlases).
//!
//! This module is the curated public surface. Add it as a dependency and
//! `@import("tile57")`. The C ABI in include/tile57.h is a thin shim over the same
//! Zig API (see capi.zig). Consumers that want only one layer can depend on that
//! module directly — `iso8211`, `s57`, `s101`, `tiles`, `geometry`, `coverage`,
//! `compose`, `render`, and `style` are each standalone.
//!
//! Surface:
//!   - Chart:    `Chart` — open, then render / query / inspect
//!   - Bake:     `bake` — a cell (or a tree of cells) to per-cell PMTiles
//!   - Compose:  `compose` — per-cell archives + `partition` -> tiles on demand
//!   - Style:    `style` — the MapLibre style; `sprite` — the atlases
//!   - Tiling:   `mvt`, `mlt`, `tile`, `pmtiles`, `gzip`, `band`, `scene`
//!   - Render:   `render` — the Surface/Canvas rendering path
//!   - Formats:  `formats.{iso8211, s57, s101}`, `coverage`

const std = @import("std");

/// Library version (matches build.zig.zon and tile57_version()).
pub const version = "0.2.0";

// ---- Chart: open a chart, then render / query / inspect --------------------
const chart = @import("chart.zig");
/// An embeddable chart source: open from a path, from bytes, or as a multi-cell
/// ENC_ROOT (streaming), then render / query / inspect. See chart.zig.
pub const Chart = chart.Chart;
pub const Format = chart.Format;
pub const CellInput = chart.CellInput;
pub const Progress = chart.Progress;
/// Streaming ENC_ROOT open (read a cell's bytes on demand, low memory): see
/// Chart.openCellsStreaming.
pub const CellMeta = chart.CellMeta;
pub const CellBytes = chart.CellBytes;
pub const CellReadFn = chart.CellReadFn;
/// Free bytes returned by the render / bake entry points.
pub const freeBytes = chart.freeBytes;
/// Warm the embedded S-101 catalogue + Lua rules once, before serving.
pub const warmup = chart.warmup;

// ---- Bake: cells -> per-cell PMTiles archives ------------------------------
/// Bake each cell to its own PMTiles at its compilation scale — the input the
/// compositor serves from. Strictly one cell, one archive.
pub const bake = struct {
    pub const cellBytes = chart.bakeCellBytes; // one cell + updates -> PMTiles bytes
    pub const cellsParallel = chart.bakeCellsParallel; // N cells -> N archives, threaded
    pub const cellsToFiles = chart.bakeCellsToFiles; // N cells -> files under a dir
    pub const tree = chart.bakeTree; // walk an ENC_ROOT, bake each cell to a mirrored path
    pub const pmtilesMetadata = chart.pmtilesMetadata; // read an archive's TileJSON metadata
    pub const Progress = chart.BakeProgress;
};

// ---- Compose: per-cell archives + a partition -> any output on demand ------
/// The runtime compositor: a `ComposeSource` over per-cell archives + a
/// partition offers the SAME outputs as a Chart, composed — `ComposeSource.tile`
/// for one tile, `renderView` / `renderSurfaceView` / `queryPoint` for composed
/// views and the composed pick. (The view calls are implemented beside Chart —
/// the underlying `compose` module is a dependency leaf without the render
/// path — and surfaced here under the compose name they belong to.)
pub const compose = struct {
    const mod = @import("compose");
    pub const ComposeSource = mod.ComposeSource;
    pub const ChartArchive = mod.ChartArchive;
    pub const TileResult = mod.TileResult;
    pub const LoadedCov = mod.LoadedCov;
    pub const openComposeSourceFiles = mod.openComposeSourceFiles;
    pub const openComposeSourceCharts = mod.openComposeSourceCharts;
    pub const composeTile = mod.composeTile;
    pub const toPlaneCells = mod.toPlaneCells;
    pub const clip = mod.clip;
    /// The composed view render — PNG, PDF, or a callback canvas.
    pub const renderView = chart.renderComposeView;
    /// The composed world-space surface stream (the GPU vector twin).
    pub const renderSurfaceView = chart.renderComposeSurfaceView;
    /// The composed cursor pick (S-52 §10.8, seams included).
    pub const queryPoint = chart.composeQueryPoint;
};
/// The ownership partition and its `.tpart` sidecar (serialize / deserialize).
pub const partition = @import("geometry").partition;
/// The integer computational geometry the compositor and baker share.
pub const geometry = @import("geometry");

// ---- Style + portrayal assets ----------------------------------------------
/// MapLibre style generation: `style.json` builds a style.json, `style.Options`
/// its inputs, `style.mariner` the S-52 display settings, `style.diff` the minimal
/// mutation to retint/refilter, plus the color tables and line styles.
pub const style = @import("style");
/// The S-52 mariner display settings model (`style.mariner.Settings`).
pub const Mariner = style.mariner.Settings;
/// S-101 sprite + area-fill pattern atlases (SVG raster).
pub const sprite = @import("sprite");

// ---- Tiling / encoding -----------------------------------------------------
pub const mvt = @import("tiles").mvt; // Mapbox Vector Tile encode/decode
pub const mlt = @import("tiles").mlt; // MapLibre Tile encode/decode (the bake default)
pub const tile = @import("tiles").tile; // web-mercator tiling + clipping
pub const pmtiles = @import("tiles").pmtiles; // PMTiles read/write
pub const gzip = @import("tiles").gzip; // gzip (tile payloads, PMTiles internals)
pub const band = @import("tiles").band; // compilation-scale -> zoom-range mapping
pub const scene = @import("scene"); // S-57 + portrayal -> tile surface
pub const bake_enc = @import("scene").bake_enc; // the banded cell baker

// ---- Render surfaces -------------------------------------------------------
/// The Surface/Canvas rendering path: PNG raster, vector PDF, ASCII, and the
/// callback surfaces a GPU host drives.
pub const render = @import("render");

// ---- Raw formats (advanced) ------------------------------------------------
pub const formats = struct {
    pub const iso8211 = @import("s57").iso8211; // ISO/IEC 8211 container records
    pub const s57 = @import("s57"); // S-57 ENC cell parser + geometry
    pub const s101 = @import("s101"); // S-101 catalogue + adapter + instructions
};
/// Per-cell M_COVR coverage sidecar (carried in an archive's PMTiles metadata).
pub const coverage = @import("coverage");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(formats);
    std.testing.refAllDecls(bake);
}
