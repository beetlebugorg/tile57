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

## The widget + hosts

`libchartplotter` (`app/chartplotter.cpp`) holds the MapLibre glue — it registers
`ChartTileSource` in the unused Mbtiles slot, builds the `Map`, and exposes:

- `chartplotter_render_png(...)` — headless, via MapLibre's `HeadlessFrontend`.
- `chartplotter_view_open/run/close(...)` — an interactive window, reusing
  MapLibre's `GLFWView` (compiled in only with GLFW; the desktop presets).

The executables are thin mains over it: `chartplotter-render`
(`app/chartplotter_render_main.cpp`) and `chartplotter`
(`app/chartplotter_main.cpp`). `chartplotter-bake` (`engine/tools/bake.zig`) is a
separate pure-Zig CLI over `libtile57` for the offline precache path.

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
