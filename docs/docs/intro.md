---
id: intro
title: Introduction
slug: /
sidebar_position: 1
---

# tile57

:::warning Not for navigation

This project is coded almost entirely with AI (Claude). It is an experiment in
building a large, complex specification (IHO S-101) with AI, and a personal
learning tool — not a certified or tested product. **Do not rely on it for
real-world navigation.** See [Known limitations](./limitations.md).

:::

**tile57** is a high-performance, low-memory **S-57 → MVT vector-tile + S-52
style engine**, embeddable from **Zig** or **C**. It decodes IHO/NOAA **S-57**
ENC cells and generates **Mapbox Vector Tiles** by `(z, x, y)`, running the
official IHO **S-101 Portrayal Catalogue** in embedded Lua to produce S-52
nautical portrayal. Alongside the tiles it emits a **MapLibre GL style** and the
portrayal **assets** it references — colour tables, line styles, and the sprite +
area-fill pattern atlases — so a renderer such as
[MapLibre](https://github.com/maplibre/maplibre-native) can draw a chart directly
from tile57's output.

tile57 is the engine only: it produces tiles, a style, and assets. It does not
draw to a screen — any MVT renderer can consume what it emits.

## The pipeline

```
S-57 ENC cell (.000)
   │  ISO 8211 decode                    src/iso8211/   (pkg: iso8211)
   ▼
S-57 feature + geometry model            src/s57/       (pkg: s57)
   │  S-101 portrayal (embedded Lua)     src/portray/ + src/s100/ (pkg: s100)
   ▼
portrayal instruction stream
   │  adapt + project + clip + encode    src/{s57_mvt,tile,mvt,pmtiles}/
   ▼
Mapbox Vector Tiles  +  MapLibre style.json  +  colortables / linestyles / sprite / patterns
```

## Why tile57 is fast and small

The engine is **high-performance and low-memory by design**:

- **Lazy, per-cell work.** A multi-cell ENC_ROOT is indexed cheaply (band +
  bbox); cells are parsed and portrayed only when a requested tile needs them,
  then held under an LRU bound. A **streaming** open reads a cell's bytes on
  demand (and frees them on eviction), so a host holds only the working set — not
  the whole catalogue.
- **Band-streamed bakes.** Baking an ENC_ROOT to one PMTiles archive streams
  band-by-band (finest → coarsest, best-band dedup), so peak memory tracks the
  largest single band.
- **Pure-Zig core.** The foundational format/encode packages (`iso8211`, `s57`,
  `s100`, `mvt`, `tile`, `pmtiles`) have no libc; only the Lua portrayal + the
  sprite rasterizer pull in C.

## Portrayal

tile57 runs the official IHO **S-101 Portrayal Catalogue** — the real Lua rule
files — in embedded Lua 5.4. The tiles carry S-52 colour **tokens** (never RGB),
and the generated `colortables.json` resolves those tokens to Day / Dusk / Night
hex, so a renderer can switch palette without regenerating tiles.

The companion Go project,
[**chartplotter-go**](https://github.com/beetlebugorg/chartplotter), bakes the
same charts and is the parity oracle; tile57's portrayal mirrors it stage for
stage.

## Where to go next

- [**Installation**](./installation.md) — Zig 0.16, submodules, `zig build`.
- [**Getting Started**](./getting-started.md) — bake a bundle and fetch a tile
  from Zig or C.
- [**Zig API**](./zig-api.md) — the `@import("tile57")` surface.
- [**C API**](./c-api.md) — the `tile57_*` C ABI (`include/tile57.h`).
- [**Architecture**](./architecture.md) — the pipeline and the Zig packages.
- [**Tile Schema**](./tile-schema.md) — the vector-tile layer contract.
- [**Known Limitations**](./limitations.md) — what does not render yet.
