---
id: architecture
title: Architecture
sidebar_position: 5
---

# Architecture

This page explains how chartplotter-native turns an S-57 chart cell into vector
tiles, how those tiles reach MapLibre Native, and how the pieces of the codebase
fit together. The Go project at
[chartplotter-go](https://github.com/beetlebugorg/chartplotter) is the reference
implementation and parity oracle; the Zig pipeline mirrors it stage for stage.

## The pipeline

A chart cell flows through these stages, all inside `libtile57`:

```
S-57 ENC cell (.000)
   │  decode the binary container     engine/src/iso8211/   (pkg: iso8211)
   ▼
S-57 feature + geometry model         engine/src/s57/       (pkg: s57)
   │  apply S-101 portrayal           engine/src/portray/ (pkg) + embedded Lua 5.4
   ▼                                   (vendor/S-101_Portrayal-Catalogue)
Primitive instruction stream
   │  adapt to drawing primitives     engine/src/s100/      (pkg: s100:
   ▼                                     catalogue, s101_adapt, s101_instr)
web-mercator project + clip + encode  engine/src/{s57_mvt,mvt,tile}/ (packages)
   ▼
Mapbox Vector Tile bytes  ─────────▶  MapLibre Native  (ChartTileSource FileSource)
```

Every stage is a **standalone Zig package** mirroring the Go oracle: `iso8211`,
`s57`, `s100` map to `pkg/iso8211`/`pkg/s57`/`pkg/s100`; `gzip`, `mvt`, `tile`,
`pmtiles`, `s57_mvt`, `bake_enc`, `portray`, `assets` map to the relevant
`internal/engine/*`. Most are pure (no libc/Lua) and target-agnostic, so the same
modules compile into both the unit tests and the static-musl baker; only
`portray` (the embedded-Lua runner) links libc, and it's never imported by the
pure test build. What's left in the top-level `engine` module is just glue — the
module roots, the `tile57_*` C-ABI (`capi`), and the MVT parity test.

1. **Decode (ISO 8211).** S-57 cells use the ISO 8211 binary container format.
   The decoder reads the raw records and fields.
2. **Build the S-57 model.** Features (depth areas, buoys, coastlines, …), their
   attributes, and their geometry (assembled from the vector topology) become a
   queryable in-memory model.
3. **Apply S-101 portrayal.** The official IHO S-101 Portrayal Catalogue — the
   real Lua rule files — runs in embedded Lua 5.4 and decides how to draw each
   feature: symbol, color, line style, including conditional symbology. Zig
   implements the `Host*` query callbacks the rules call back into.
4. **Adapt the instructions.** The portrayal output (an S-101 instruction stream)
   is turned into simple drawing primitives: filled polygons, stroked lines,
   symbols, patterns, soundings, and text.
5. **Project, clip, encode.** Each primitive is projected to web-mercator tile
   coordinates, clipped to the tile (extent 4096, buffer 64), and encoded as MVT.
6. **Serve.** `tile57_tile_get` returns the tile's bytes; the `ChartTileSource`
   `FileSource` hands them to MapLibre for `zigtiles://{z}/{x}/{y}` requests.

The same `chartplotter_*` API also reads a pre-baked **PMTiles** archive instead
of generating from a cell, or a whole **ENC_ROOT** directory — every base cell
with its `.001…` updates applied (S-57 §8.4 record merge) and the cells overlaid
per tile. The renderer cannot tell the difference. The host does the directory
walk and file reads (`app/enc_root.hpp`); the library has no filesystem access.

## Design decisions

A few choices shape the whole project:

- **CMake is the top-level integrator.** MapLibre Native is embedded via
  `add_subdirectory(vendor/maplibre-native)` and built by its own CMake. The Zig
  tile generator is a leaf static library (`libtile57`, `tile57_*`) built by
  `scripts/zig-build-lib.sh`; the chart **widget** `libchartplotter`
  (`chartplotter_*`) wraps MapLibre + libtile57 and is what an app embeds. Both
  have small [C APIs](./c-api.md).
- **Live, in-process generation is the target.** `libtile57` generates one tile's
  MVT bytes on demand; the `ChartTileSource` `mbgl::FileSource` (scheme
  `zigtiles://`, inside libchartplotter) hands them to MapLibre. Tiles are memoized
  in an in-process cache. The offline CLI baker is kept too (cheap, and the
  differential-test driver).
- **Register in the unused Mbtiles slot.** Rather than patch MapLibre, the host
  registers `ChartTileSource` as the factory for `FileSourceType::Mbtiles` *before*
  the `Map` is constructed, so `zigtiles://` requests route to it.
- **Embed Lua 5.4; do not port the rules.** The ~216 IHO Lua rule files are
  executable spec — they run as-is. Only the ~30 `Host*` query functions they call
  are implemented in Zig (and a small C shim, since Lua's macros are easiest from
  C).
- **Renderer is platform-native.** Metal on macOS, OpenGL via surfaceless **EGL**
  on Linux (headless render-to-PNG works displayless).

## The renderer + the Qt viewer

`libchartplotter` (`app/chartplotter.cpp`) holds the MapLibre glue for the
**headless render path** — it registers `ChartTileSource` in the unused Mbtiles
slot, builds an `mbgl::Map` on a `HeadlessFrontend`, and exposes
`chartplotter_render_png(...)`. The thin exe `chartplotter-render`
(`app/chartplotter_render_main.cpp`) wraps it.

The **interactive window** is a separate Qt6 app, `chartplotter-qt` (`app/qt`),
built on [QMapLibre](https://github.com/maplibre/maplibre-native-qt) — the Qt6
MapLibre widget (`vendor/maplibre-native-qt`, built by
`scripts/build-qmaplibre.sh`). It loads a baked chart **bundle**'s `style.json`
(PMTiles + portrayal assets) into a `QMapLibre::MapWidget`; it links QMapLibre, not
mbgl/libtile57 directly. (It replaced an earlier GLFW/macOS-Metal MapLibre Native
window.)

`tile57` (`engine/tools/bake.zig`) is the pure-Zig CLI over the engine
for the offline path (tiles, bundles, styles).

## The offline chart bundle

The same engine also runs offline as a **chart-bundle baker**. One `bundle`
command emits a self-contained, relocatable directory in which the tiles and the
portrayal that renders them travel together:

```
chart-bundle/
  manifest.json             pins schema_version + couples the two halves
  tiles/chart.pmtiles       the DATA half — semantic colour *tokens*, palette-independent
  assets/colortables.json   the PORTRAYAL half — token -> hex per day/dusk/night (the only RGB)
  assets/style-{day,dusk,night}.json  the MapLibre style layers, colours pre-resolved per palette
```

This works because the tiles carry S-52 colour **tokens**, never RGB. The two
halves are emitted from the *same* S-101 catalogue, so they can't drift, and the
manifest stamps both with a `schema_version` (`tile57/1` — the
[tile-schema](./tile-schema.md) layer/property vocabulary) that a renderer checks
before loading. `assets/colortables.json` is byte-identical to the Go oracle's.

Baker subcommands (`tile57`):

| Subcommand | What it does |
|-----------|--------------|
| `bake <cell> -o out.pmtiles` | one cell → a PMTiles archive |
| `bake-root <ENC_ROOT> -o out.pmtiles` | a whole ENC_ROOT, zoom-banded per cell |
| `bundle <cell> -o dir/` | a self-contained bundle (tiles + assets + styles + manifest) |
| `assets <catalog-dir> -o dir/` | just the portrayal assets (colortables), independent of a cell |
| `style <catalog-dir> --scheme S -o f.json` | one MapLibre style.json, colours resolved per palette |
| `inspect` / `cell` | inspect a PMTiles archive / summarise an S-57 cell |

The `assets` module mirrors the Go oracle's `internal/engine/assets.EmitS101`.
Colortables and the **style.json layer set** ship today — `assets/style.zig`
(ported from the web `s52-style.mjs` / `chart-style.mjs`) is the sole style
generator, driven by `scripts/gen-style.sh`. Line styles, sprite/pattern atlases
(SVG raster), and glyphs (SDF) — which light up the symbol/text layers — are in
progress.

## Live tile source (the render path)

`ChartTileSource` (`app/chart_tile_source.cpp`) backs `chartplotter-render`: it
serves `zigtiles://{z}/{x}/{y}` straight from libtile57, generated in-process.
Two things make that cheap: tiles carry a stable `etag` so MapLibre returns
`notModified` and keeps its parsed tile on a re-request (no re-parse), and
libtile57 memoizes generated/decoded tiles (`engine/src/capi.zig`, key
`z<<48|x<<24|y`) so re-requests never re-decode. The Qt viewer doesn't use this
path — it renders a pre-baked bundle (PMTiles) through QMapLibre.

(The earlier GLFW / macOS-Metal interactive window — and its present-timing
saga — is retired; QMapLibre owns rendering for the window now.)

See the [**Tile Schema**](./tile-schema.md) for the vector-tile layer contract.
