---
id: getting-started
title: Getting Started
sidebar_position: 3
---

# Getting Started

This guide bakes a chart with the `tile57` CLI and fetches a tile from the
engine, from both Zig and C. It assumes you have finished
[Installation](./installation.md) (Zig 0.16, submodules, `zig build`).

## 1. Bake a chart with the CLI

The `tile57` binary is the offline tool. It bakes ENC cells to PMTiles and emits
the portrayal assets a renderer needs:

```sh
zig build                          # builds zig-out/bin/tile57
T=zig-out/bin/tile57

# A self-contained bundle: tiles + style + assets + manifest
$T bundle CELL.000 -o out/

# A whole ENC_ROOT, band-streamed into one PMTiles archive
$T bake-root /path/to/ENC_ROOT -o chart.pmtiles

# Just the portrayal assets (from the embedded catalogue — no path needed)
$T assets     -o assets/   # colortables + linestyles + sprite + patterns
$T sprite-mln -o assets/   # the MapLibre sprite sheet
# (pass a /path/to/PortrayalCatalog to use an on-disk catalogue instead)

# Inspect / summarise
$T inspect chart.pmtiles        # zoom range + tile counts
$T cell    CELL.000             # summarise an S-57 cell
$T version
```

Run `tile57 help` for the full subcommand list (`bake`, `bake-root`, `bundle`,
`assets`, `sprite`, `pattern`, `sprite-mln`, `style`, `inspect`, `cell`,
`version`, `help`).

A **bundle** is a relocatable directory in which the tiles and the portrayal that
renders them travel together:

```
out/
  manifest.json             pins schema_version, couples the two halves
  tiles/chart.pmtiles       the DATA half — S-52 colour tokens, palette-independent
  assets/colortables.json   token -> hex per day/dusk/night (the only RGB)
  assets/style-{day,dusk,night}.json  MapLibre style layers, colours pre-resolved
```

## 2. Fetch a tile from Zig

Add tile57 as a dependency and `@import("tile57")`:

```zig
const tile57 = @import("tile57");

// Open a source: a PMTiles archive, or a raw S-57 cell portrayed live.
var src = try tile57.Source.openBytes(cell_bytes, .auto, null);
defer src.deinit();

if (try src.tile(z, x, y)) |mvt| {     // decompressed MVT bytes (or null if empty)
    defer tile57.freeBytes(mvt);
    // … hand mvt to your renderer …
}
```

`Source.openCells` / `Source.openCellsStreaming` open a whole ENC_ROOT;
`tile57.bakeArchive` bakes one to a PMTiles archive; `tile57.assets`,
`tile57.sprite`, and `tile57.style.build` generate the style + assets. See the
[Zig API](./zig-api.md).

## 3. Fetch a tile from C

The same engine sits behind a thin C ABI ([`include/tile57.h`](../../include/tile57.h)):

```c
#include "tile57.h"

tile57_source *s = tile57_source_open(data, len, TILE57_FORMAT_AUTO, NULL);

uint8_t *mvt; size_t n;
if (tile57_tile_get(s, z, x, y, &mvt, &n) == TILE57_TILE_OK) {
    /* … render the decompressed MVT bytes … */
    tile57_tile_free(mvt, n);
}
tile57_source_close(s);
```

Link against `libtile57.a`. The format is auto-detected
(`TILE57_FORMAT_AUTO`): PMTiles first, then a raw S-57 cell generated live. See
the [C API](./c-api.md) for the ENC_ROOT, streaming, bake, style, and
asset-generation entry points.

## ENC_ROOT and updates

Open an ENC_ROOT (many cells, each with its sequential `.001`, `.002` … updates)
with `Source.openCells` / `tile57_source_open_cells`, or its streaming variant
for large catalogues. The host walks the directory and reads the files (Zig 0.16
gates filesystem access behind `std.Io`); the engine parses, applies the updates,
and serves the best-available scale band per tile.

See the [**Architecture**](./architecture.md) page for how the engine fits
together.
