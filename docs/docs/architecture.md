---
id: architecture
title: Architecture
sidebar_position: 6
---

# Architecture

This page explains how tile57 turns an S-57 chart cell into vector tiles, how the
codebase is layered, and the memory design that keeps it small.

## The pipeline

A chart cell flows through these stages, all inside the engine:

```
S-57 ENC cell (.000)
   │  decode the binary container     src/s57/iso8211.zig
   ▼
S-57 feature + geometry model         src/s57/       (module: s57)
   │  apply S-101 portrayal           src/portray/ + embedded Lua 5.4
   ▼                            (vendor/S-101_Portrayal-Catalogue)
portrayal instruction stream
   │  adapt to drawing primitives     src/s100/      (module: s100)
   ▼
scene generation                      src/scene/  (project + clip + draw calls)
   ▼
render Surface                        src/render/surface.zig
   ├─► tile surfaces:  MVT / MLT encode + PMTiles    src/tiles/
   │        + MapLibre style.json + portrayal assets src/assets/, src/sprite/
   └─► pixel surfaces: PNG raster · vector PDF · terminal text (src/render/)
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
5. **Generate the scene.** Each primitive is projected to web-mercator tile
   coordinates, clipped (extent 4096, buffer 64), and emitted as *draw calls* on a
   **Surface** — the backend seam described below.

### The Surface contract

Every output format implements one vtable — `Surface`
(`src/render/surface.zig`). The engine emits *semantic* draw calls (S-52 colour
tokens, symbol names, raw depths, per-feature display metadata); what happens
next depends on the listening backend: the **tile surface** serializes the
semantics into MVT/MLT tiles for a client renderer, the **pixel surface**
resolves them (tokens → RGB, symbol names → vector outlines) and paints PNG
raster or deterministic vector PDF, and the **ASCII surface** lowers them to a
Unicode terminal grid (with optional ANSI colour, or real pixels inline via the
kitty graphics protocol). One engine, pluggable outputs — see
[The Rendering Engine](./rendering.md).

### Tile formats: MLT by default, MVT on request

Bakes encode **MLT** ([MapLibre Tile](https://github.com/maplibre/maplibre-tile-spec))
by default; MapLibre GL JS ≥ 5.12 decodes it natively via the vector source
`encoding` option, and the generated styles carry that hint. Pass
`--format mvt` (CLI) to bake Mapbox Vector Tiles for consumers without an MLT
decoder. `tile57_chart_info.tile_type` reports which encoding a chart's tiles
use, so a host hints its renderer correctly.

### Band handoff (coverage-clipped ownership)

Overlapping cells of different compilation scales are resolved per tile to the
best band. Rather than *carry* a coarser cell's features down into a finer band's
tiles (the old `smax`-tagged carry-down), the compositor clips each cell to the
**ownership partition**: at every tile the finer cell's M_COVR coverage wins the
ground it holds, and a coarser cell renders only where no finer cell covers it.
Band boundaries hand off without holes or double-draws, and there is no
per-feature handoff tag for the style to gate.

### Overscale indication (`oscl`)

Per S-52 §10.1.10, every contributing cell's coverage polygon is baked as an
`OVERSC01` vertical-line hatch tagged `oscl` = the cell's compilation-scale
denominator. The hatch shows only while the display is *finer* than `1:oscl`,
and the style sandwiches it between the overscaled and at-scale fill passes so
finer opaque data occludes a coarser cell's hatch. The `show_overscale`
mariner toggle (default on) drives its visibility.

## The Zig modules

The stages are separate Zig modules (see `build.zig`), most of them pure (no
libc/Lua) and target-agnostic:

| Module | Role |
|--------|------|
| `s57` | S-57 ENC cell parser + geometry model (includes the ISO/IEC 8211 decoder, `src/s57/iso8211.zig`) |
| `s100` | S-100/S-101 catalogue + portrayal adaptation |
| `portray` | the embedded-Lua S-101 runner (links libc) |
| `tiles` | MVT + MLT encoders, gzip, the PMTiles container, web-mercator tile math |
| `render` | the Surface contract, the resolver (colours, display gates), and the pixel machinery (Canvas, PNG, PDF, ASCII) |
| `scene` | S-57 → tile-surface scene generation + the banded ENC_ROOT baker (`bake_enc.zig`) |
| `assets` | colortables / linestyles / style / manifest generation (includes `chartstyle.zig`, the mariner-driven style builder) |
| `sprite` | S-101 sprite + area-fill pattern atlases (SVG raster; links libc) |
| `engine` | the pure packages re-exported as one import (the test root) |
| `tile57` | the curated public surface (`src/tile57.zig`) |

`portray` and `sprite` are the only modules that link libc, and neither is
imported by the pure test build. The C ABI (`src/capi.zig`) is a thin shim over
the same Zig API as the `tile57` module.

## The layering: chart / compose / style

The public surface composes the packages into high-level entry points:

- **`Chart`** — open a chart from a path (`openPath`), from bytes (`openBytes`), or
  as a multi-cell ENC_ROOT (`openCells` / `openCellsStreaming`), then render and
  inspect it: `renderView` (PNG or PDF), `renderSurfaceView` (world-space GPU
  callbacks), `queryPoint` (the cursor pick), and the metadata getters. It reads a
  pre-baked **PMTiles** archive or portrays a live cell — the caller can't tell the
  difference. (`tile57_chart_render_view` / `tile57_chart_render_pdf` /
  `tile57_chart_render_surface_cb` / `tile57_chart_query` in the C ABI.)
- **Tile production** — bake each cell to its own PMTiles at its compilation scale
  (`tile57_bake_cell_bytes`), then a runtime **compositor** stitches the overlapping
  cells for any `(z, x, y)` tile on demand through an ownership partition
  (`tile57_compose_open` / `tile57_compose_serve`). `bakeArchive`
  (`scene/bake_enc.zig`) is the offline alternative — a whole ENC_ROOT to one
  band-streamed PMTiles archive.
- **`style.build`** (`assets/chartstyle.zig`) + **`assets`** / **`sprite`** —
  generate the MapLibre style and the portrayal assets it references
  (`tile57_build_style` / `tile57_bake_assets` in the C ABI).

## The memory design

tile57 is built to hold only its working set:

- **Lazy per-cell.** An ENC_ROOT is opened by scanning each cell's header for a
  cheap spatial index (band + bbox). A cell is parsed and portrayed only when a
  requested tile needs it; recently used cells are held in an LRU and evicted
  under bound. The first tile over a fresh area pays a parse/portray cost (tens of
  ms); after that it is cached.
- **Best-available band per tile.** Overlapping cells of different compilation
  scales are resolved per tile to the best band, not all overlaid blindly.
- **Streaming open.** `openCellsStreaming` (and its on-disk driver `openPath` /
  `tile57_chart_open`) take per-cell metadata (bbox + scale) plus a reader; a cell's
  bytes are read only on demand and freed on eviction. A host then holds only the
  working set's bytes, not the whole catalogue — the right choice for a large ENC_ROOT.
- **Band-streamed bakes.** `bakeArchive` streams band-by-band (finest →
  coarsest), so peak memory tracks the largest single band rather than the whole
  archive.
- **Tile cache.** Generated/decoded tiles are memoized per chart (keyed
  `z<<48 | x<<24 | y`) and released with the chart, so a long-running host bounds
  memory by closing charts it no longer renders.

## The live-composite bake

One `bake` command (`tile57 bake <cell.000 | ENC_ROOT> -o out/`) writes the
live-composite structure — per-cell tiles plus the ownership partition a runtime
compositor serves them from:

```
out/
  tiles/US5MD1MC.pmtiles    one PMTiles per cell, baked at its compilation scale
  tiles/US4MD81M.pmtiles       (M_COVR coverage embedded in each archive's metadata)
  partition.tpart           the ownership partition: which cell renders which ground
```

There is no merged archive: any `(z, x, y)` tile is composed from the overlapping
cells on demand (`tile57_compose_serve`), so re-baking one cell doesn't rewrite a
whole district. The portrayal assets are generated separately (`tile57 assets` /
`style`); the tiles carry S-52 colour **tokens**, never RGB, and both halves come
from the *same* S-101 catalogue, so they cannot drift. The tile-schema vocabulary
(`tile57/1`) is the contract a renderer checks.

See the [**Tile Schema**](./tile-schema.md) for the vector-tile layer contract.
