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

## Bake an ENC_ROOT

```zig
// Band-streamed: peak memory tracks the largest single band, not the whole archive.
const pmtiles_bytes = try tile57.bakeArchive(/* … */);
defer tile57.freeBytes(pmtiles_bytes);
```

`tile57.bakeArchive` bakes a whole ENC_ROOT into one PMTiles archive, zoom-banded
per cell by compilation scale; `tile57.Progress` is the optional progress
callback type.

## Style + portrayal assets

```zig
// MapLibre style from a template + mariner S-52 display settings + colortables.
const json = try tile57.style.build(/* … */);     // tile57.style.Mariner settings
```

| Surface | What it does |
|---------|--------------|
| `tile57.style.build` (`style.buildFromTemplate`) | build a MapLibre style from a template + mariner settings + colortables. |
| `tile57.style.Mariner` | the S-52 mariner display options struct (`style.mariner.Settings`). |
| `tile57.style` | color tables, line styles, and style.json generation. |
| `tile57.sprite` | S-101 sprite + area-fill pattern atlases (SVG raster). |
| `tile57.style.mariner` | the S-52 mariner settings model and expression builders. |

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
