---
id: getting-started
title: Getting Started
sidebar_position: 3
---

# Getting Started

This guide bakes a chart with the `tile57` CLI, then serves a composed tile and
uses the engine from Zig and C. It assumes you have finished
[Installation](./installation.md) (Zig 0.16, submodules, `zig build`).

## 1. Bake a chart with the CLI

The `tile57` binary is the offline tool. It bakes ENC cells to PMTiles and emits
the portrayal assets a renderer needs:

```sh
zig build                          # builds zig-out/bin/tile57
T=zig-out/bin/tile57

# Bake a single cell OR a whole ENC_ROOT to the live-composite structure:
# per-cell tiles/<STEM>.pmtiles (native band scale, M_COVR embedded) + partition.tpart
$T bake CELL.000 -o out/
$T bake /path/to/ENC_ROOT -o out/

# Serve one composed tile on demand from that structure (the runtime compositor)
$T compose-tile out/tiles 15 9371 12534 --load-partition out/partition.tpart -o tile.mlt

# The portrayal assets a renderer needs (from the embedded catalogue — no path needed)
$T assets     -o assets/   # colortables + linestyles + sprite + patterns
$T sprite-mln -o assets/   # the MapLibre sprite sheet
# (pass a /path/to/PortrayalCatalog to use an on-disk catalogue instead)

# Render a finished chart — no browser or GPU needed
$T png CELL.000 --view -76.48,38.974,15 --size 1600x1200 -o chart.png
$T pdf CELL.000 --view -76.48,38.974,15 --size 1600x1200 -o chart.pdf

# Inspect / summarise
$T inspect out/tiles/US5MD1MC.pmtiles  # zoom range + tile counts for one cell
$T cell    CELL.000                    # summarise an S-57 cell
$T version
```

Run `tile57 help` for usage. The full subcommand list: `bake`, `compose-tile`,
`assets`, `sprite`, `pattern`, `sprite-mln`, `style`, `png`, `pdf`, `ascii`,
`cells`, `catalog`, `features`, `inspect`, `cell`, `objlcount`, `version`,
`help`.

:::info Tiles are MLT by default
Bakes encode [MapLibre Tiles](https://github.com/maplibre/maplibre-tile-spec)
(MLT) by default; rendering them needs **MapLibre GL JS ≥ 5.12** (which decodes
MLT natively — the generated styles carry the source `encoding` hint). Pass
`--format mvt` to bake Mapbox Vector Tiles for older or other consumers.
:::

And a crowd-pleaser — the chart in your terminal, as a Unicode grid with
ANSI colour, with `--tui` for an interactive pan/zoom loop (`--kitty` paints
real S-52 pixels inline on kitty-graphics terminals like Ghostty or Kitty):

```sh
$T ascii CELL.000 --view -76.48,38.974,13 --ansi --tui
```

`tile57 bake` writes a **live-composite structure** — per-cell tiles plus an
ownership partition — that a runtime compositor serves tiles from on demand:

```
out/
  tiles/US5MD1MC.pmtiles    one PMTiles per cell, baked at its compilation scale
  tiles/US4MD81M.pmtiles       (M_COVR coverage embedded in each archive's metadata)
  partition.tpart           the ownership partition: which cell renders which ground
```

There is no merged archive: any `(z, x, y)` tile is composed from the overlapping
cells on demand, so a re-bake of one cell doesn't rewrite a whole district. The
portrayal assets travel separately (`tile57 assets` / `style`); the tiles carry
S-52 colour **tokens**, never RGB, so one set of tiles renders in any palette.

## 2. Serve a tile from C

The engine sits behind a thin C ABI ([`include/tile57.h`](../../include/tile57.h)).
Open a compositor over the bake output and serve tiles by `(z, x, y)`:

```c
#include "tile57.h"

/* Open a compositor over the `tile57 bake` output (list every cell archive). */
const char *paths[] = { "out/tiles/US5MD1MC.pmtiles" };
tile57_compose_source *src = tile57_compose_open(paths, 1, "out/partition.tpart");

uint8_t *tile; size_t n;
switch (tile57_compose_serve(src, z, x, y, &tile, &n)) {
    case 1:  /* … render the decompressed MLT tile … */ tile57_free(tile, n); break;
    case 2:  /* owned but empty — a cell's bake is still in flight */ break;
    case 0:  /* not owned — open ocean; cache as blank */ break;
    default: /* -1 error */ break;
}
tile57_compose_close(src);
```

Link against `libtile57.a`. The `partition.tpart` sidecar (NULL to skip) lets the
compositor load the ownership partition instead of rebuilding it. To render a
finished PNG/PDF, read metadata, or query the feature under a point, open a
`tile57_chart` instead — `tile57_chart_open` (an on-disk ENC_ROOT or a `.000`),
`tile57_chart_open_bytes` (one in-memory cell), or `tile57_chart_open_pmtiles`
(a baked archive). See the [C API](./c-api.md).

## 3. Use the engine from Zig

Add tile57 as a dependency and `@import("tile57")`:

```zig
const tile57 = @import("tile57");

// Open an on-disk ENC_ROOT (or a single .000) for rendering + inspection.
var chart = try tile57.Chart.openPath("ENC_ROOT/", null, true);
defer chart.deinit();

const bbox = chart.bounds();   // geographic extent [w, s, e, n], or null
// … render a view (chart.renderView), query features (chart.featuresJson),
//   or read per-cell metadata (chart.cellsJson) …
```

The Zig `Chart` renders views, queries features, and reads metadata;
`tile57.bakeArchive` bakes an ENC_ROOT to one band-streamed PMTiles archive
offline. The runtime tile compositor (bake per cell, compose on demand) is
exposed through the [C ABI](./c-api.md). See the [Zig API](./zig-api.md).

## ENC_ROOT and updates

Open an ENC_ROOT (many cells, each with its sequential `.001`, `.002` … updates)
with `Chart.openPath` / `tile57_chart_open` — a single call that streams a whole
on-disk catalogue, reading each cell's bytes on demand. The engine parses, applies
the updates, and serves the best-available scale band per tile.

See the [**Architecture**](./architecture.md) page for how the engine fits
together.
