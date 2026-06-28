---
id: getting-started
title: Getting Started
sidebar_position: 3
---

# Getting Started

This guide builds the project and renders a chart to a PNG. (The interactive
window is a separate Qt6 app, `chartplotter-qt` — see below.) It assumes you have
finished [Installation](./installation.md) (submodules, toolchain, reference data).

## What the build produces

Built only when Zig 0.16 is found:

| Target | Kind | What it is |
|--------|------|-----------|
| `libtile57.a` | static lib | the Zig S-57 tile generator + its `tile57_*` [C ABI](./c-api.md). |
| `libchartplotter.a` | static lib | the headless chart **renderer** (chart → PNG) over MapLibre + libtile57; `chartplotter_*` [C API](./c-api.md). |
| `chartplotter-render` | executable | headless host: renders a chart to a PNG (PMTiles, an S-57 cell, or an ENC_ROOT). |
| `tile57` | executable | offline CLI: bake a cell/ENC_ROOT to PMTiles or a self-contained chart bundle. |

The interactive **Qt6 window** (`chartplotter-qt`, `app/qt`) is built separately
via `scripts/build-qmaplibre.sh` — it links the [QMapLibre](https://github.com/maplibre/maplibre-native-qt)
widget and shows a baked chart bundle. MapLibre Native's own demo tools
(`mbgl-render`) also build, but they are not part of our code.

## Presets

| Preset | Build dir | Renderer | Our binaries |
|--------|-----------|----------|--------------|
| `headless` | `build/` | Linux surfaceless EGL | `chartplotter-render` |
| `macos`    | `build-macos/` | macOS Metal (headless) | `chartplotter-render` |

## Step 1: Render a chart to a PNG (headless)

The headless host needs no display, so it works on a server or in CI.

```sh
# Linux:                                   macOS:
cmake --preset headless                    # cmake --preset macos
ninja -C build chartplotter-render         # ninja -C build-macos chartplotter-render

# From a baked PMTiles archive:
build/chartplotter-render \
  reference/tiles/annapolis.pmtiles \
  style/chart-zig-day.json \
  38.978 -76.487 14 renders/annapolis.png 1024 768 2
```

The arguments are
`<archive.pmtiles|cell.000> <style.json> <lat> <lon> <zoom> <out.png> [w h ratio]`.

## Step 2: Render straight from a raw S-57 cell (live generation)

No pre-baked tiles — the Zig library generates them on demand and runs the
embedded-Lua S-101 portrayal over the cell:

```sh
build/chartplotter-render \
  ../chartplotter-go/testdata/US4MD81M.000 \   # a raw S-57 cell
  style/chart-zig-day.json \
  38.97 -76.49 12 renders/from_cell.png
```

The format is auto-detected (`TILE57_FORMAT_AUTO`): PMTiles first, then S-57 cell.

## Step 2b: Point at an ENC_ROOT (many cells + updates)

If the path is a **directory**, it's treated as an ENC_ROOT: every `*.000` base
cell under it is loaded and overlaid, and each cell's sequential update files
(`.001`, `.002`, …) are applied. This is the usual shape of a NOAA ENC download
(`ENC_ROOT/<CELL>/<CELL>.000` + updates).

```sh
build/chartplotter-render \
  /path/to/ENC_ROOT \                  # a directory, not a file
  style/chart-zig-day.json \
  38.97 -76.45 11 renders/enc_root.png
```

Both hosts accept a directory anywhere a chart path is expected. The host walks
the directory and reads the files; the library applies the updates and overlays
the cells.

:::note Overlay, not best-available
Cells are overlaid (all drawn); there is no per-zoom "best-available" band
selection yet, so overlapping cells of different scales both render. See
[Known limitations](./limitations.md).
:::

## Step 3: Open the interactive window (Qt6)

`chartplotter-qt` opens a real pannable/zoomable window over a baked chart
**bundle**, on the [QMapLibre](https://github.com/maplibre/maplibre-native-qt)
widget. Build it once (a heavy build of QMapLibre), then point it at a bundle's
style:

```sh
scripts/build-qmaplibre.sh                 # -> build/qt/chartplotter-qt (needs Qt6)

# bake a bundle, then view it (needs a display):
engine/zig-out/bin/tile57 bundle \
  ../chartplotter-go/testdata/US5MD1MC.000 -o out
build/qt/chartplotter-qt out/assets/style-day.json 38.97 -76.49 13
```

Drag to pan, scroll to zoom. The viewer renders the bundle's PMTiles through
QMapLibre — independent of libtile57/mbgl.

## Pre-baking tiles to PMTiles

For the precache path (render fast from a ready archive, or ship a region), the
`tile57` CLI bakes a cell to a PMTiles archive offline — the native
analogue of chartplotter-go's `bake`:

```sh
cd engine && zig build       # builds engine/zig-out/bin/tile57 (pure Zig)

engine/zig-out/bin/tile57 bake \
  ../chartplotter-go/testdata/US4MD81M.000 \
  -o charts.pmtiles --minzoom 8 --maxzoom 16 \
  [US4MD81M.001 US4MD81M.002 ...]         # optional update files, applied in order

tile57 inspect charts.pmtiles  # zoom range + tile counts
tile57 version
```

The archive then renders through `chartplotter-render`; a baked **bundle** also
renders in the Qt window (`chartplotter-qt`).

:::note Baker portrayal
The baker runs the full embedded-Lua S-101 portrayal — the same rule engine as the
live library — so baked archives carry the full S-101 layer set, not the
`classify()` fallback. The rules directory resolves from `--rules`, else
`TILE57_S101_RULES`, else the vendored catalogue relative to the working
directory; if the rules can't be loaded the baker falls back to `classify()` and
says so on stderr.
:::

## S-101 self-tests

`chartplotter-render` also wraps the embedded-Lua / S-101 bring-up checks:

```sh
build/chartplotter-render --s101check   <rules-dir>   # the framework loads
build/chartplotter-render --s101run     <rules-dir>   # it executes
build/chartplotter-render --s101portray <rules-dir>   # a real DepthArea rule emits instructions
```

## Runtime knobs

- `TILE57_S101_RULES=<dir>` — S-101 portrayal rules directory for raw S-57
  cells. A fallback only: it applies when the host passes `NULL` for
  the `rules_dir` argument (the hosts auto-resolve + pass it). Defaults to the vendored
  catalogue at `vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules`.

See the [**Architecture**](./architecture.md) page for how the renderer, the Qt
viewer, and the offline baker fit together.
