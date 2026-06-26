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

A chart cell flows through these stages, all inside `libchartplotter.a`:

```
S-57 ENC cell (.000)
   │  decode the binary container     engine/src/iso8211.zig
   ▼
S-57 feature + geometry model         engine/src/s57.zig
   │  apply S-101 portrayal           engine/src/portray.zig + embedded Lua 5.4
   ▼                                   (vendor/S-101_Portrayal-Catalogue)
Primitive instruction stream
   │  adapt to drawing primitives     engine/src/s101_adapt.zig, s101_instr.zig
   ▼
web-mercator project + clip + encode  engine/src/s57_mvt.zig, mvt.zig, tile.zig
   ▼
Mapbox Vector Tile bytes  ─────────▶  MapLibre Native  (ChartTileSource FileSource)
```

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
6. **Serve.** `chartplotter_tile_get` returns the tile's bytes; the `ChartTileSource`
   `FileSource` hands them to MapLibre for `zigtiles://{z}/{x}/{y}` requests.

The same `chartplotter_*` API also reads a pre-baked **PMTiles** archive instead of
generating from a cell — the renderer cannot tell the difference.

## Design decisions

A few choices shape the whole project:

- **CMake is the top-level integrator.** MapLibre Native is embedded via
  `add_subdirectory(vendor/maplibre-native)` and built by its own CMake. The Zig
  tile generator is a leaf static library (`libchartplotter.a`) with a
  hand-written [C ABI](./c-api.md), built by `scripts/zig-build-lib.sh`.
- **Live, in-process generation is the target.** `libchartplotter.a` generates one
  tile's MVT bytes on demand; the `ChartTileSource` `mbgl::FileSource` (scheme
  `zigtiles://`) hands them to MapLibre. Tiles are memoized in an in-process cache.
  The offline CLI baker is kept too (cheap, and the differential-test driver).
- **Register in the unused Mbtiles slot.** Rather than patch MapLibre, the host
  registers `ChartTileSource` as the factory for `FileSourceType::Mbtiles` *before*
  the `Map` is constructed, so `zigtiles://` requests route to it.
- **Embed Lua 5.4; do not port the rules.** The ~216 IHO Lua rule files are
  executable spec — they run as-is. Only the ~30 `Host*` query functions they call
  are implemented in Zig (and a small C shim, since Lua's macros are easiest from
  C).
- **Renderer is platform-native.** Metal on macOS, OpenGL via surfaceless **EGL**
  on Linux (headless render-to-PNG works displayless).

## Hosts

Two C++ hosts link `libchartplotter.a`, both registering the same
`ChartTileSource`:

- **`chartplotter-render`** (`app/zig_render.cpp`) — headless, renders one PNG via
  MapLibre's `HeadlessFrontend`. The verification path on displayless boxes.
- **`chartplotter`** (`app/zig_glfw.cpp`) — interactive, reuses MapLibre's
  `GLFWView` for a pannable/zoomable window.

## Milestones

| M | Deliverable | Status |
|---|-------------|--------|
| M0 | MapLibre `mbgl-render` builds (headless EGL) | ✅ done |
| M1 | Annapolis chart from Go-baked PMTiles + ported S-52 style | ✅ done |
| M2 | S-52 fidelity: symbols, glyphs + text, soundings, area patterns, depth-shading | ✅ done |
| M3 | Own window (`chartplotter`, reuses GLFWView); interactive pan/zoom of live tiles | ✅ done |
| M4 | Zig encoder core: mvt + gzip + pmtiles + tile (project/clip), differential-tested vs Go | ✅ done |
| M5 | Live in-process generation via custom `FileSource` + C ABI | ✅ done |
| M6a | ISO 8211 decoder (parses real cells) | ✅ done |
| M6b | S-57 model: dataset params, vectors, features | ✅ done |
| M6c | Topology assembly + live cell → MVT → MapLibre (crude classify) | ✅ done |
| M6d | S-57 attributes + embedded-Lua S-101 portrayal → full S-52 | ✅ core done (~96% of features) |

## macOS interactive rendering notes

Getting the GLFW window smooth on macOS (Apple Silicon / Metal / ProMotion) took
some doing. What matters, and why:

- **Conditional tile requests (the flicker fix).** `ChartTileSource`
  (`app/chart_tile_source.cpp`) tags each tile with an `etag` and returns
  `notModified` when MapLibre re-requests an unchanged tile. Without this, MapLibre
  re-requested **and re-parsed** tiles 15–60×/sec, and each re-parse re-uploaded to
  the GPU → constant flicker (even at 100–300 fps).
- **In-process tile cache** (`engine/src/capi.zig`): generated/decoded tiles are
  memoized (`z<<48|x<<24|y`), so re-requests never re-decode.
- **Async present** (`app/metal_backend.mm`): `presentDrawable` + `commit`, like
  MapLibre's own macOS SDK (`MLNMapView+Metal`). `presentsWithTransaction` +
  `waitUntilScheduled`/`waitUntilCompleted` were all tried and all stalled or
  flickered on the GLFW (non-`CADisplayLink`) loop — do not reintroduce them.
- **`nextDrawable` nil-guard + `setAllowsNextDrawableTimeout(false)`**: stops the
  whole-screen blank when the drawable pool is briefly exhausted on fast pan.
- **On-demand render** (default): pan/zoom changes the camera every frame so it
  still presents every frame (smooth); idle stops (low CPU), last frame retained.
  `CHART_CONTINUOUS=1` forces present-every-frame if a display needs it.

See the [**Tile Schema**](./tile-schema.md) for the vector-tile layer contract.
