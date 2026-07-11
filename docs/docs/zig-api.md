---
id: zig-api
title: Zig API
sidebar_position: 5
---

# Zig API

The engine is a Zig package named **`tile57`** (v0.3.0, requires Zig 0.16).
Add it as a dependency and `@import("tile57")` for the curated public surface
(`src/tile57.zig`). The [C ABI](./c-api.md) is a thin shim over this same API,
and both share the same shape: **bake, then compose** (or bake, then render) —
source charts bake once to per-chart archives, and every output is produced
from baked archives.

:::note
Add it as a **path dependency** on a local clone (submodules initialised) —
`zig fetch` by URL/hash is currently broken because the package's declared
`.paths` omit `vendor/` and `include/`. See
[Installation](./installation.md).
:::

## Bake

Bake each chart to its own PMTiles at its compilation scale — the input the
compositor serves from. Free any returned bytes with `tile57.freeBytes`.

```zig
// Bake an ENC_ROOT: each chart -> <out>/tiles/<STEM>.pmtiles + <out>/partition.tpart.
// Incremental: an archive already newer than its whole input is skipped.
const n = try tile57.bake.tree(io, "/enc/ENC_ROOT", "/out", null, 4, null, null);
```

| Surface | What it does |
|---------|--------------|
| `tile57.bake.chartBytes(path, rules)` | bake one chart (+ updates) to PMTiles bytes. |
| `tile57.bake.chartsParallel(...)` / `bake.chartsToFiles(...)` | bake many charts in parallel, to memory / to files. |
| `tile57.bake.tree(io, in, out, ...)` | walk an ENC_ROOT, bake each chart to a mirrored path (incremental). |
| `tile57.bake.pmtilesMetadata(a, bytes)` | read an archive's metadata JSON (embedded coverage + scamin). |
| `tile57.bake.Progress` | the optional progress-callback type. |

Reading raw S-57 source data (a chart inventory, GeoJSON feature extraction)
goes through a streaming `Chart` — see `openPath` below.

## Render: the `Chart`

A `Chart` is one open chart: metadata, feature extraction, the S-52 cursor
pick, and view renders — with no composition. Tiles across many charts come
from the compositor (next section).

```zig
const tile57 = @import("tile57");

// A baked archive, mmap'd (never fully resident).
var chart = try tile57.Chart.openPmtilesPath(io, "US5MD1MC.pmtiles");
defer chart.deinit();

const bbox = chart.bounds();   // geographic extent [w, s, e, n], or null
// … chart.renderView(…) / chart.queryPoint(…) …
```

What a chart can do depends on how it was opened:

| Open | Backend | Serves |
|------|---------|--------|
| `openPmtilesPath(io, path)` | baked archive, mmap'd | metadata (embedded coverage + scale), query, view renders (tile replay), raw tiles via `pmtilesReader()`. |
| `openBytes(bytes, .pmtiles, …)` | baked archive, copied | the same, from memory. |
| `openBytes(cell_bytes, .auto, rules_dir)` | ONE live S-57 chart, fully portrayed | metadata, query, view renders with the S-101 rules evaluated live. |
| `openPath(path, rules_dir, pick_attrs)` | streaming ENC_ROOT (or a single `.000`) | metadata + extraction ONLY: `chartsJson`, `featuresJson`, `scamin`, bounds. Charts are enumerated up front and parsed on demand, so a whole catalogue opens instantly. No view renders, no tiles. |
| `openCharts(charts, …)` / `openChartsStreaming(metas, reader, …)` | the same, from in-memory charts / a host reader callback | as `openPath`. |

`Chart` methods:

| Method | Purpose |
|--------|---------|
| `renderView(lon, lat, zoom, w, h, palette, settings, output, cb)` | render a view through the native S-52 pixel path — PNG, PDF, or a callback canvas. |
| `renderSurfaceView(lon, lat, zoom, w, h, palette, settings, cb)` | drive world-space surface callbacks (the GPU vector twin). |
| `renderAscii(lon, lat, zoom, cols, rows, palette, settings, ansi)` | the same view as a terminal text grid. |
| `queryPoint(lon, lat, zoom, cb)` | the S-52 cursor pick — features under a point at the view zoom. |
| `chartsJson()` / `featuresJson(classes)` | per-chart metadata / GeoJSON feature extraction (the `cells` / `features` CLI). |
| `coverage()` | the M_COVR data-coverage rings (a live chart, or the copy a per-chart bake embeds in its archive metadata). |
| `bounds() -> ?[4]f64` | geographic extent `[w, s, e, n]`, if known. |
| `anchor()` | a good initial camera (lat, lon, zoom) on real data. |
| `bands() -> u32` | bitmask of navigational bands present. |
| `zoomRange()` | the min/max zoom the chart covers. |
| `nativeScale() -> i32` | the compilation scale 1:N (a live chart or an archive's embedded metadata; 0 if unknown). |
| `scamin() -> ![]u32` | the distinct SCAMIN denominators present (the live SCAMIN manifest). |
| `tileType()` | the tile encoding the chart's tiles use (MVT/MLT). |
| `format() -> Format` | the resolved backend (after `.auto`). |
| `pmtilesReader()` / `decodedCoverage()` | the archive reader (raw per-archive tiles — the primitive for writing your own compositor) + the decoded per-chart coverage; what the built-in compositor borrows. |
| `deinit()` | release the chart and its cached tiles. |

`tile57.Format` is `.auto` / `.pmtiles` / `.s57`. `rules_dir` is the S-101
portrayal rules directory for live S-57 charts; `null` (or `""`) uses the rules
embedded in the binary (or `TILE57_S101_RULES` if set), so no on-disk catalogue
is required; a path overrides with an on-disk catalogue.

The streaming open uses the extern types `tile57.ChartMeta` (bbox + `cscl`),
`tile57.ChartBytes` (the chart's base + updates, ownership transferred to the
library), and `tile57.ChartReadFn` (the reader callback). Multi-chart input for
`openCharts` is `tile57.ChartInput`.

## Compose

The runtime compositor stitches per-chart archives into one seamless chart:
any `(z, x, y)` tile on demand through the ownership partition (charts never
double-draw where they meet), and the same view outputs as a single chart,
composed.

```zig
// Open the compositor over the archives + partition, then compose tiles.
var src = (try tile57.compose.ComposeSource.openFiles(io, gpa, paths, "/out/partition.tpart")).?;
defer src.deinit();
const result = try src.tile(gpa, 13, 2359, 3139); // result.tile: ?[]u8, result.owned: bool

// The composed view outputs live beside the Chart ones:
const png = try tile57.compose.renderView(src, lon, lat, 13.5, 1600, 1200, .day, &settings, .png, null);
```

A host that already holds open charts composes over them instead — the
compositor borrows each chart's mmap'd reader + decoded coverage, so the charts
must outlive it:

```zig
const archives = [_]tile57.compose.ChartArchive{
    .{ .reader = chart.pmtilesReader().?, .cov = chart.decodedCoverage().? },
};
var src = (try tile57.compose.ComposeSource.open(gpa, &archives, null)).?;
```

| Surface | What it does |
|---------|--------------|
| `ComposeSource.openFiles(io, gpa, paths, part)` | open a `ComposeSource` over on-disk archives + a partition. |
| `ComposeSource.open(gpa, archives, part)` | the same over borrowed `ChartArchive`s (already-open charts). |
| `ComposeSource.tile(gpa, z, x, y)` | compose one tile on demand (raw MLT + the ownership flag). |
| `tile57.compose.renderView(src, ...)` | the composed view render — PNG, PDF, or a callback canvas. |
| `tile57.compose.renderSurfaceView(src, ...)` | the composed world-space surface stream. |
| `tile57.compose.queryPoint(src, lon, lat, zoom, cb)` | the composed cursor pick, across chart boundaries. |
| `tile57.compose.tile(...)` | the stateless core `ComposeSource.tile` uses. |
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
| `tile57.mvt` / `tile57.mlt` | Mapbox Vector Tile / MapLibre Tile encode/decode |
| `tile57.tile` | web-mercator tiling + clipping |
| `tile57.pmtiles` | PMTiles read/write |
| `tile57.band` | compilation-scale → zoom-range mapping |
| `tile57.bake_enc` | banded multi-chart ENC_ROOT → PMTiles |
| `tile57.scene` | S-57 feature → tile-surface scene generation |
| `tile57.render` | the Surface/Canvas rendering path (PNG, PDF, ASCII, callbacks) |

## Raw formats (advanced)

The pure-Zig foundational parsers under `tile57.formats`:

| Module | Role |
|--------|------|
| `tile57.formats.iso8211` | ISO/IEC 8211 records |
| `tile57.formats.s57` | the S-57 chart parser + geometry |
| `tile57.formats.s101` | the S-101 catalogue, adapter, and instruction stream |

`tile57.coverage` is the per-chart M_COVR coverage sidecar (carried in an
archive's PMTiles metadata). `tile57.version` is the package version string
(`"0.3.0"`), matching `build.zig.zon` and `tile57_version()`.
