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
`explore`, `cells`, `catalog`, `features`, `inspect`, `cell`, `objlcount`,
`version`, `help`.

:::info Tiles are MLT by default
Bakes encode [MapLibre Tiles](https://github.com/maplibre/maplibre-tile-spec)
(MLT) by default; rendering them needs **MapLibre GL JS ≥ 5.12** (which decodes
MLT natively — the generated styles carry the source `encoding` hint). The
engine can also encode Mapbox Vector Tiles for consumers without an MLT decoder.
:::

The chart also renders in your terminal, as a Unicode grid with
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

/* Open each baked archive as a chart, then a compositor over the charts. */
tile57 *chart = NULL;
tile57_error err;
if (tile57_open("out/tiles/US5MD1MC.pmtiles", &chart, &err) != TILE57_OK) {
    fprintf(stderr, "%s\n", err.message);
}
tile57_compose *src = NULL;
tile57_compose_open(&chart, 1, "out/partition.tpart", &src, &err);

uint8_t *tile; size_t n; bool owned;
if (tile57_compose_serve(src, z, x, y, &tile, &n, &owned, &err) == TILE57_OK) {
    if (tile)       { /* … serve the decompressed MLT tile … */ tile57_free(tile, n); }
    else if (owned) { /* owned but empty — a cell's bake is still in flight */ }
    else            { /* not owned — open ocean; cache as blank */ }
}
tile57_compose_close(src);   /* the compositor borrows its charts… */
tile57_close(chart);         /* …so close them after it */
```

Link against `libtile57.a`. The `partition.tpart` sidecar (NULL to skip) lets the
compositor load the ownership partition instead of rebuilding it. The same
`tile57` chart handle renders finished PNGs/PDFs, reads metadata (bounds, scale,
coverage, SCAMIN), and answers the cursor pick; raw S-57 reading (cell
inventory, feature extraction) is handle-free via `tile57_s57_*`. See the
[C API](./c-api.md).

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

The Zig `Chart` renders views, queries features, and reads metadata. Tile
production (bake each cell, then compose on demand) is exposed through the
[C ABI](./c-api.md). See the [Zig API](./zig-api.md).

## ENC_ROOT and updates

Open an ENC_ROOT (many cells, each with its sequential `.001`, `.002` … updates)
with `Chart.openPath` (Zig) or scan it with `tile57_s57_cells` (C) — a single
call that walks a whole on-disk catalogue, applying each cell's updates. Baking
(`tile57 bake` / `tile57_bake_tree`) turns it into the per-cell archives the
compositor serves.

See the [**Architecture**](./architecture.md) page for how the engine fits
together.
