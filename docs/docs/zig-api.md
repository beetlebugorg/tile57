---
id: zig-api
title: Zig API
sidebar_position: 4
---

# Zig API

The engine is a Zig package named **`tile57`** (v0.1.0, requires Zig 0.16).
Add it as a dependency and `@import("tile57")` for the curated public surface
(`src/tile57.zig`). The [C ABI](./c-api.md) is a thin shim over this same
API.

:::note
Add it as a **path dependency** on a local clone (submodules initialised) —
`zig fetch` by URL/hash is currently broken because the package's declared
`.paths` omit `vendor/` and `include/`. See
[Installation](./installation.md).
:::

## The high-level engine: `Chart`

Open a **chart** from bytes, a path, or cells, then render views, query features,
and read metadata:

```zig
const tile57 = @import("tile57");

// A PMTiles archive, or a raw S-57 cell portrayed live (auto-sniffed).
var chart = try tile57.Chart.openBytes(cell_bytes, .auto, null);
defer chart.deinit();

const bbox = chart.bounds();   // geographic extent [w, s, e, n], or null
// … chart.renderView(…) / chart.queryPoint(…) / chart.featuresJson(…) …
```

The Zig `Chart` does not itself serve `(z, x, y)` tiles — the runtime compositor
(bake each cell, then compose on demand) is exposed through the [C ABI](./c-api.md).
`tile57.bakeArchive` bakes a whole ENC_ROOT to one PMTiles archive offline.

`Chart` methods:

| Method | Purpose |
|--------|---------|
| `openBytes(bytes, format, rules_dir)` | open one chart from bytes (PMTiles or S-57 cell). |
| `openPath(path, rules_dir, pick_attrs)` | open an on-disk ENC_ROOT dir (or a single `.000`) as a streaming chart. |
| `openCells(cells, rules_dir, pick_attrs)` | open a multi-cell ENC_ROOT from bytes (each cell's `.001…` updates applied). |
| `openCellsStreaming(metas, reader, user, rules_dir, pick_attrs)` | low-memory ENC_ROOT: read each cell's bytes on demand, free on eviction. |
| `renderView(lon, lat, zoom, w, h, palette, settings, output)` | render a view through the native S-52 pixel path — PNG or PDF. |
| `renderSurfaceView(lon, lat, zoom, w, h, palette, settings, cb)` | drive world-space surface callbacks (the GPU vector twin). |
| `renderAscii(lon, lat, zoom, cols, rows, palette, settings, ansi)` | the same view as a terminal text grid. |
| `queryPoint(lon, lat, zoom, cb)` | the S-52 cursor pick — features under a point at the view zoom. |
| `cellsJson()` / `featuresJson(classes)` | per-cell metadata / GeoJSON feature query (the `cells` / `features` CLI). |
| `coverage()` | the M_COVR data-coverage rings (a live cell only). |
| `bounds() -> ?[4]f64` | geographic extent `[w, s, e, n]`, if known. |
| `anchor()` | a good initial camera (lat, lon, zoom) on real data. |
| `bands() -> u32` | bitmask of navigational bands present. |
| `zoomRange()` | the min/max zoom the chart serves. |
| `nativeScale() -> i32` | the compilation scale 1:N (a live cell; 0 if unknown). |
| `scamin() -> ![]u32` | the distinct SCAMIN denominators present (the live SCAMIN manifest). |
| `tileType()` | the tile encoding the chart's tiles use (MVT/MLT). |
| `format() -> Format` | the resolved backend (after `.auto`). |
| `deinit()` | release the chart and its cached tiles. |

`tile57.Format` is `.auto` / `.pmtiles` / `.s57_cell`. `rules_dir` is the S-101
portrayal rules directory for live S-57 cells; `null` (or `""`) uses the rules
embedded in the binary (or `TILE57_S101_RULES` if set), so no on-disk catalogue
is required; a path overrides with an on-disk catalogue. Free any bytes returned
by the render / bake entry points with `tile57.freeBytes`.

The streaming open uses the extern types `tile57.CellMeta` (bbox + `cscl`),
`tile57.CellBytes` (the cell's base + updates, ownership transferred to the
library), and `tile57.CellReadFn` (the reader callback). Multi-cell input for
`openCells` is `tile57.CellInput`.

## Bake + compose

Baking and compositing are separate steps. `tile57.bake` writes each cell to its
own PMTiles at its compilation scale; `tile57.compose` stitches those archives
into one tile for any `(z, x, y)` on demand, using an ownership partition so cells
never double-draw at a seam.

```zig
// Bake an ENC_ROOT: each cell -> <out>/tiles/<STEM>.pmtiles + <out>/partition.tpart.
const n = tile57.bake.tree(io, "/enc/ENC_ROOT", "/out", null, 4, null, null);

// Open the compositor over the archives + partition, then serve tiles.
var src = (try tile57.compose.openComposeSourceFiles(io, gpa, paths, "/out/partition.tpart")).?;
defer src.deinit();
const result = try src.serve(gpa, 13, 2359, 3139); // result.tile: ?[]u8, result.owned: bool
```

| Surface | What it does |
|---------|--------------|
| `tile57.bake.cellBytes(path, rules)` | bake one cell (+ updates) to PMTiles bytes. |
| `tile57.bake.cellsToFiles(...)` / `bake.tree(...)` | bake many cells / a whole ENC_ROOT to files. |
| `tile57.bake.archive(...)` | the offline path: merge a slice of cells into one archive. |
| `tile57.bake.Progress` | the optional progress-callback type. |
| `tile57.compose.openComposeSourceFiles(...)` | open a `ComposeSource` over on-disk archives + a partition. |
| `tile57.compose.composeTile(...)` | compose one tile (the stateless core `serve` uses). |
| `tile57.partition` | the ownership partition and its `.tpart` sidecar (serialize / deserialize). |

## Style + portrayal assets

```zig
// MapLibre style from a template + mariner S-52 display settings + colortables.
const json = try tile57.style.buildFromTemplate(/* … */);     // tile57.Mariner settings
```

| Surface | What it does |
|---------|--------------|
| `tile57.style` | the MapLibre style: `json`, `Options`, `diff`, `buildFromTemplate`, color tables, line styles. |
| `tile57.style.mariner` | the S-52 mariner settings model and expression builders. |
| `tile57.Mariner` | the S-52 mariner display options struct (`style.mariner.Settings`). |
| `tile57.sprite` | S-101 sprite + area-fill pattern atlases (SVG raster). |

## Tiling + encoding

The mid-level packages, for callers that compose their own pipeline:

| Module | Role |
|--------|------|
| `tile57.mvt` | Mapbox Vector Tile encode/decode |
| `tile57.tile` | web-mercator tiling + clipping |
| `tile57.pmtiles` | PMTiles read/write |
| `tile57.bake_enc` | banded multi-cell ENC_ROOT → PMTiles |
| `tile57.scene` | S-57 feature → tile-surface scene generation |

## Raw formats (advanced)

The pure-Zig foundational parsers under `tile57.formats`:

| Module | Role |
|--------|------|
| `tile57.formats.iso8211` | ISO/IEC 8211 records |
| `tile57.formats.s57` | S-57 ENC cell parser + geometry |
| `tile57.formats.s101` | the S-101 catalogue, adapter, and instruction stream |

`tile57.version` is the package version string (`"0.1.0"`), matching
`build.zig.zon` and `tile57_version()`.
