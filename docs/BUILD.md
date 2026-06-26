# Building & running chartplotter-native

The renderer is platform-specific: **Metal** on macOS, **OpenGL/EGL** on Linux.
CMake is the top-level integrator; it builds MapLibre Native (vendored) and
drives `zig build` for the tile generator.

## What the build produces

Our targets (built only when Zig 0.16 is found):

| Target | Kind | What it is |
|--------|------|-----------|
| `libchartplotter.a` | static lib | the Zig tile generator + its C ABI (`include/chartplotter.h`). Linked into the hosts below. Built from `tilegen/` via `scripts/zig-build-lib.sh`. |
| `chartplotter-render` | executable | headless host: renders a chart to a PNG. Takes a PMTiles archive **or** a raw `.000` S-57 cell (live generation). The verify path on headless boxes. |
| `chartplotter` | executable | interactive GLFW window: pan/zoom a live chart. Same tile source, but in a real window. Only built with the desktop presets. |

MapLibre Native's own demo tools also build and are occasionally useful, but are
**not** part of our code: `mbgl-render` (generic style → PNG) and `mbgl-glfw`
(generic style in a window).

## Presets

| Preset | Build dir | Renderer | Our binaries | Use |
|--------|-----------|----------|--------------|-----|
| `headless` | `build/` | Linux surfaceless EGL | `chartplotter-render` | CI / displayless verify |
| `desktop`  | `build-desktop/` | Linux OpenGL + GLFW + Wayland | `chartplotter`, `chartplotter-render` | interactive pan/zoom |
| `macos`    | `build-macos/` | macOS Metal (headless) | `chartplotter-render` | CI / verify on Mac |
| `macos-desktop` | `build-macos-desktop/` | macOS Metal + GLFW | `chartplotter`, `chartplotter-render` | interactive pan/zoom |

## Prerequisites

- **Fetch the submodules first**: `git submodule update --init --recursive`
  (MapLibre Native, ~1.6 GB into `vendor/maplibre-native/`, plus the official
  IHO S-101 Portrayal/Feature catalogues under `vendor/`).
- CMake ≥ 3.25, Ninja, a C++20 compiler.
- **Zig 0.16.0** — required for the tile generator and all three of our targets.
  Install from [ziglang.org/download](https://ziglang.org/download/) (pin
  0.16.0) and put it on `PATH`; CMake finds it (it also checks `~/.local/bin`
  and `~/.local/share/zig-0.16.0`). Lua 5.4 is vendored under `tilegen/vendor/lua`
  and built into `libchartplotter.a` — no system Lua needed.
- macOS: Xcode + command-line tools; `brew install ninja cmake libuv` (libuv
  backs the darwin run loop). Metal works out of the box.
- Linux: Clang, and for the desktop window `glfw3`, `wayland-client`,
  `wayland-egl`, `wayland-cursor`, `libxkbcommon`, `libepoxy` (standard on Arch).
- First build of `mbgl-core` is large (~15 min on 8 cores). `ccache` (picked up
  automatically if installed) makes rebuilds fast.

## Reference data + styles (one command)

Our hosts render tiles + assets produced by the Go reference impl, plus generated
styles. `gen-reference.sh` picks the right prebuilt Go binary for your OS/arch
(`../chartplotter-go/dist/chartplotter_<os>_<arch>_s101`), emits assets, bakes
`annapolis.pmtiles`, and generates the styles (full S-52: symbols, text,
soundings, patterns, depth-shading, Day/Dusk/Night):

```sh
scripts/gen-reference.sh           # assets + tiles + styles
scripts/gen-style.sh               # just the styles, if reference data exists
```

Reference data and the generated styles are gitignored (machine-specific — the
styles embed an absolute PMTiles path). Regenerate after cloning. After a `git
pull`, `scripts/dev-rebuild.sh` regenerates styles and rebuilds our targets in
whichever build dir exists.

## chartplotter-render → PNG (headless; PMTiles or a live S-57 cell)

```sh
# Linux:                                   macOS:
cmake --preset headless                    # cmake --preset macos
ninja -C build chartplotter-render         # ninja -C build-macos chartplotter-render

# From a baked PMTiles archive:
build/chartplotter-render \
  reference/tiles/annapolis.pmtiles \
  style/chart-zig-day.json \
  38.978 -76.487 14 renders/annapolis.png 1024 768 2

# Straight from a raw S-57 cell — no pre-baked tiles (live generation + S-101):
build/chartplotter-render \
  ../chartplotter-go/testdata/US4MD81M.000 \
  style/chart-zig-day.json \
  38.97 -76.49 12 renders/from_cell.png
```

Args: `<archive.pmtiles|cell.000> <style.json> <lat> <lon> <zoom> <out.png> [w h
ratio]`. The format is auto-detected (`CP_FORMAT_AUTO`). For a raw cell it runs
the embedded-Lua S-101 portrayal (real IHO rules) over the cell.

`chartplotter-render` also wraps the S-101 bring-up self-tests:
`--s101check <rules-dir>` (framework loads), `--s101run <rules-dir>` (it
executes), `--s101portray <rules-dir>` (a real DepthArea rule emits instructions).

## chartplotter → interactive pan/zoom window (live Zig tiles)

```sh
# Linux (Wayland):                         macOS (Metal):
cmake --preset desktop                     # cmake --preset macos-desktop
ninja -C build-desktop chartplotter        # ninja -C build-macos-desktop chartplotter

# defaults to framing the data extent if lat/lon/zoom are omitted:
build-desktop/chartplotter \
  reference/tiles/annapolis.pmtiles \      # or a raw .000 cell for live generation
  style/chart-zig-day.json 38.978 -76.487 13
```

Drag pans, scroll zooms. On a Linux X11 session instead of Wayland, reconfigure
with `-DMLN_WITH_WAYLAND=OFF -DMLN_WITH_X11=ON`.

## Runtime knobs

- `CHARTPLOTTER_S101_RULES=<dir>` — S-101 portrayal rules directory, used for raw
  S-57 cells. A fallback only: it applies when the host passes `NULL` for
  `cp_source_open`'s `rules_dir` (both hosts do). Defaults to the vendored
  catalogue at `vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules`.
- `CHART_CONTINUOUS=1` (interactive window) — present every frame instead of the
  default on-demand rendering. An escape hatch for displays where the on-demand
  path goes idle-blank; not normally needed.
- `chartshot.sh` env knobs (the upstream `mbgl-render` path): `STYLE OUT LAT LON
  ZOOM W H RATIO BEARING DEBUG=1`.

## Upstream MapLibre demo tools (not our code)

```sh
ninja -C build mbgl-render                 # generic style → PNG
OUT="$PWD/renders/annapolis.png" LAT=38.978 LON=-76.482 ZOOM=14 RATIO=2 \
  bash scripts/chartshot.sh                # drives mbgl-render

ninja -C build-desktop mbgl-glfw           # generic style in a window
build-desktop/vendor/maplibre-native/platform/glfw/mbgl-glfw \
  -s style/chart-zig-day.json -x -76.482 -y 38.978 -z 14
```

## macOS interactive rendering notes (`chartplotter`)

Getting the GLFW window smooth on macOS (Apple Silicon / Metal / ProMotion) took
some doing. What matters, and why:

- **Conditional tile requests (the flicker fix).** `ChartTileSource`
  (`app/chart_tile_source.cpp`) tags each tile with an `etag` and returns
  `notModified` when MapLibre re-requests an unchanged tile. Without this,
  MapLibre re-requested + **re-parsed** tiles 15-60×/sec, and each re-parse
  re-uploaded to the GPU → constant flicker (even at 100-300fps).
- **In-process tile cache** (`tilegen/src/capi.zig`): generated/decoded tiles are
  memoized (z<<48|x<<24|y), so re-requests never re-decode.
- **Async present** (`app/metal_backend.mm`): `presentDrawable` + `commit`, like
  MapLibre's own macOS SDK (`MLNMapView+Metal`). `presentsWithTransaction` +
  `waitUntilScheduled`/`waitUntilCompleted` were tried and all stalled/flickered
  on the GLFW (non-CADisplayLink) loop — don't reintroduce them.
- **`nextDrawable` nil-guard + `setAllowsNextDrawableTimeout(false)`**: stops the
  whole-screen blank when the drawable pool is briefly exhausted on fast pan.
- **On-demand render** (default): pan/zoom changes the camera every frame so it
  still presents every frame (smooth); idle stops (low CPU), last frame retained.
  `CHART_CONTINUOUS=1` forces present-every-frame if a display needs it.
