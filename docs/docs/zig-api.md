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

Open a **chart** from bytes, a path, or cells, then fetch tiles by `(z, x, y)`:

```zig
const tile57 = @import("tile57");

// A PMTiles archive, or a raw S-57 cell portrayed live (auto-sniffed).
var chart = try tile57.Chart.openBytes(cell_bytes, .auto, null);
defer chart.deinit();

if (try chart.tile(z, x, y)) |bytes| {   // decompressed tile bytes, or null if empty
    defer tile57.freeBytes(bytes);
    // … hand to your renderer …
}
```

`Chart` methods:

| Method | Purpose |
|--------|---------|
| `openBytes(bytes, format, rules_dir)` | open one chart from bytes (PMTiles or S-57 cell). |
| `openPath(path, rules_dir, pick_attrs)` | open an on-disk ENC_ROOT dir (or a single `.000`) as a streaming chart. |
| `openCells(cells, rules_dir, pick_attrs)` | open a multi-cell ENC_ROOT from bytes (each cell's `.001…` updates applied). |
| `openCellsStreaming(metas, reader, user, rules_dir, pick_attrs)` | low-memory ENC_ROOT: read each cell's bytes on demand, free on eviction. |
| `tile(z, x, y) -> ?[]u8` | the tile's decompressed bytes, in the chart's tile encoding (null = empty). |
| `tileType()` / `setTileFormat(fmt)` | the encoding `tile` returns (MVT/MLT); opt a live cell-backed chart into MLT. |
| `renderView(lon, lat, zoom, w, h, palette, settings, output)` | render a view through the native S-52 pixel path — PNG or PDF. |
| `renderAscii(lon, lat, zoom, cols, rows, palette, settings, ansi)` | the same view as a terminal text grid. |
| `cellsJson()` / `featuresJson(classes)` | per-cell metadata / GeoJSON feature query (the `cells` / `features` CLI). |
| `bounds() -> ?[4]f64` | geographic extent `[w, s, e, n]`, if known. |
| `anchor()` | a good initial camera (lat, lon, zoom) on real data. |
| `bands() -> u32` | bitmask of navigational bands present. |
| `zoomRange()` | the min/max zoom the chart serves. |
| `scamin() -> ![]u32` | the distinct SCAMIN denominators present (the live SCAMIN manifest). |
| `format() -> Format` | the resolved backend (after `.auto`). |
| `clearCache()` | drop the in-memory tile cache. |
| `deinit()` | release the chart and its cached tiles. |

`tile57.Format` is `.auto` / `.pmtiles` / `.s57_cell`. `rules_dir` is the S-101
portrayal rules directory for live S-57 cells; `null` (or `""`) uses the rules
embedded in the binary (or `TILE57_S101_RULES` if set), so no on-disk catalogue
is required; a path overrides with an on-disk catalogue. Free any bytes returned
by `tile` / `bakeArchive` with `tile57.freeBytes`.

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
| `tile57.style.build` (`chartstyle.buildStyle`) | patch a MapLibre style template with mariner settings + colortables. |
| `tile57.style.Mariner` | the S-52 mariner display options struct. |
| `tile57.assets` | colortables / linestyles / style.json / manifest generation. |
| `tile57.sprite` | S-101 sprite + area-fill pattern atlases (SVG raster). |
| `tile57.chartstyle` | the mariner-driven style-patching module. |

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
| `tile57.formats.s100` | S-100/S-101 catalogue + adaptation |

`tile57.version` is the package version string (`"0.1.0"`), matching
`build.zig.zon` and `tile57_version()`.
