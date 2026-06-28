---
id: architecture
title: Architecture
sidebar_position: 6
---

# Architecture

This page explains how tile57 turns an S-57 chart cell into vector tiles, how the
codebase is layered, and the memory design that keeps it small. The Go project at
[chartplotter-go](https://github.com/beetlebugorg/chartplotter) is the reference
implementation and parity oracle; the Zig pipeline mirrors it stage for stage.

## The pipeline

A chart cell flows through these stages, all inside the engine:

```
S-57 ENC cell (.000)
   │  decode the binary container     engine/src/iso8211/   (pkg: iso8211)
   ▼
S-57 feature + geometry model         engine/src/s57/       (pkg: s57)
   │  apply S-101 portrayal           engine/src/portray/ (pkg) + embedded Lua 5.4
   ▼                                   (vendor/S-101_Portrayal-Catalogue)
portrayal instruction stream
   │  adapt to drawing primitives     engine/src/s100/      (pkg: s100)
   ▼
web-mercator project + clip + encode  engine/src/{s57_mvt,mvt,tile,pmtiles}/
   ▼
Mapbox Vector Tile bytes  +  MapLibre style.json  +  portrayal assets
```

1. **Decode (ISO 8211).** S-57 cells use the ISO 8211 binary container format;
   the decoder reads its raw records and fields.
2. **Build the S-57 model.** Features (depth areas, buoys, coastlines, …), their
   attributes, and their geometry (assembled from the vector topology) become a
   queryable in-memory model.
3. **Apply S-101 portrayal.** The official IHO S-101 Portrayal Catalogue — the
   real Lua rule files — runs in embedded Lua 5.4 and decides how to draw each
   feature: symbol, colour, line style, conditional symbology. Zig implements the
   `Host*` query callbacks the rules call back into (plus a small C shim, since
   Lua's macros are easiest from C).
4. **Adapt the instructions.** The portrayal output is turned into simple drawing
   primitives: filled polygons, stroked lines, symbols, patterns, soundings, text.
5. **Project, clip, encode.** Each primitive is projected to web-mercator tile
   coordinates, clipped to the tile (extent 4096, buffer 64), and encoded as MVT.

## The Zig packages

Every stage is a **standalone Zig package**, most of them pure (no libc/Lua) and
target-agnostic:

| Package | Role |
|---------|------|
| `iso8211` | ISO/IEC 8211 record decode |
| `s57` | S-57 ENC cell parser + geometry model |
| `s100` | S-100/S-101 catalogue + portrayal adaptation |
| `portray` | the embedded-Lua S-101 runner (links libc) |
| `mvt` | Mapbox Vector Tile encode/decode |
| `tile` | web-mercator tiling + clipping |
| `pmtiles` | PMTiles read/write |
| `s57_mvt` | S-57 feature → MVT tile |
| `bake_enc` | banded multi-cell ENC_ROOT → PMTiles |
| `assets` | colortables / linestyles / style / manifest generation |
| `sprite` | S-101 sprite + area-fill pattern atlases (SVG raster) |
| `chartstyle` | mariner-driven MapLibre style patching |

`portray` is the only package that links libc, and it is never imported by the
pure test build. The top-level `tile57` module (`engine/src/tile57.zig`) is the
curated public surface; the C ABI (`engine/src/capi.zig`) is a thin shim over the
same Zig API.

## The layering: Source / bake / style

The public surface composes the packages into three high-level entry points:

- **`Source`** — open a chart from bytes (`openBytes`), a multi-cell ENC_ROOT
  (`openCells` / `openCellsStreaming`), then `tile(z, x, y)`. This is the live
  tile-generation path. It also reads a pre-baked **PMTiles** archive — the caller
  can't tell the difference.
- **`bakeArchive`** (`bake_enc`) — bake a whole ENC_ROOT to one PMTiles archive
  offline, band-streamed.
- **`style.build`** (`chartstyle`) + **`assets`** / **`sprite`** — generate the
  MapLibre style and the portrayal assets it references.

The same three are exposed across the C ABI (`tile57_source_*`,
`tile57_bake_cells`, `tile57_build_style`, `tile57_colortables` /
`tile57_linestyles` / `tile57_sprite_atlas` / `tile57_pattern_atlas`).

## The memory design

tile57 is built to hold only its working set:

- **Lazy per-cell.** An ENC_ROOT is opened by scanning each cell's header for a
  cheap spatial index (band + bbox). A cell is parsed and portrayed only when a
  requested tile needs it; recently used cells are held in an LRU and evicted
  under bound. The first tile over a fresh area pays a parse/portray cost (tens of
  ms); after that it is cached.
- **Best-available band per tile.** Overlapping cells of different compilation
  scales are resolved per tile to the best band, not all overlaid blindly.
- **Streaming open.** `openCellsStreaming` / `tile57_source_open_cells_streaming`
  take per-cell metadata (bbox + scale) plus a reader callback; a cell's bytes are
  read only on demand and freed on eviction. A host then holds only the working
  set's bytes, not the whole catalogue — the right choice for a large ENC_ROOT.
- **Band-streamed bakes.** `bakeArchive` streams band-by-band (finest →
  coarsest), so peak memory tracks the largest single band rather than the whole
  archive.
- **Tile cache.** Generated/decoded tiles are memoized per source (keyed
  `z<<48 | x<<24 | y`); `clearCache` / `tile57_source_clear_cache` drops it to
  bound long-running hosts.

## The offline chart bundle

One `bundle` command emits a self-contained, relocatable directory in which the
tiles and the portrayal that renders them travel together:

```
chart-bundle/
  manifest.json             pins schema_version, couples the two halves
  tiles/chart.pmtiles       the DATA half — semantic colour tokens, palette-independent
  assets/colortables.json   the PORTRAYAL half — token -> hex per day/dusk/night (the only RGB)
  assets/style-{day,dusk,night}.json  the MapLibre style layers, colours pre-resolved
```

This works because the tiles carry S-52 colour **tokens**, never RGB. Both halves
are emitted from the *same* S-101 catalogue, so they cannot drift, and the
manifest stamps both with a `schema_version` (`tile57/1` — the
[tile-schema](./tile-schema.md) vocabulary) that a renderer checks before loading.

See the [**Tile Schema**](./tile-schema.md) for the vector-tile layer contract.
