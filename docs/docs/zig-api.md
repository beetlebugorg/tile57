---
id: zig-api
title: Zig API
sidebar_position: 4
---

# Zig API

The engine is a real Zig package named **`tile57`** (v0.1.0, requires Zig 0.16).
Add it as a dependency and `@import("tile57")` for the curated public surface
(`src/tile57.zig`). The [C ABI](./c-api.md) is a thin shim over this same
API.

## The high-level engine: `Source`

Open a chart **source** from bytes or cells, then fetch tiles by `(z, x, y)`:

```zig
const tile57 = @import("tile57");

// A PMTiles archive, or a raw S-57 cell portrayed live (auto-sniffed).
var src = try tile57.Source.openBytes(cell_bytes, .auto, null);
defer src.deinit();

if (try src.tile(z, x, y)) |mvt| {     // decompressed MVT bytes, or null if empty
    defer tile57.freeBytes(mvt);
    // … hand to your renderer …
}
```

`Source` methods:

| Method | Purpose |
|--------|---------|
| `openBytes(bytes, format, rules_dir)` | open one chart (PMTiles or S-57 cell). |
| `openCells(cells, rules_dir)` | open a multi-cell ENC_ROOT (each cell's `.001…` updates applied). |
| `openCellsStreaming(metas, reader, user, rules_dir)` | low-memory ENC_ROOT: read each cell's bytes on demand, free on eviction. |
| `tile(z, x, y) -> ?[]u8` | the tile's decompressed MVT bytes (null = empty). |
| `bounds() -> ?[4]f64` | geographic extent `[w, s, e, n]`, if known. |
| `anchor()` | a good initial camera (lat, lon, zoom) on real data. |
| `bands() -> u32` | bitmask of navigational bands present. |
| `zoomRange()` | the min/max zoom the source serves. |
| `format() -> Format` | the resolved backend (after `.auto`). |
| `clearCache()` | drop the in-memory tile cache. |
| `deinit()` | release the source and its cached tiles. |

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
| `tile57.s57_mvt` | S-57 feature → MVT tile |

## Raw formats (advanced)

The pure-Zig foundational parsers under `tile57.formats`:

| Module | Role |
|--------|------|
| `tile57.formats.iso8211` | ISO/IEC 8211 records |
| `tile57.formats.s57` | S-57 ENC cell parser + geometry |
| `tile57.formats.s100` | S-100/S-101 catalogue + adaptation |

`tile57.version` is the package version string (`"0.1.0"`), matching
`build.zig.zon` and `tile57_version()`.
