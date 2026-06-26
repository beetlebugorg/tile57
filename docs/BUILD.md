# Building & running chartplotter-native

Build configs (see `CMakePresets.json`). The renderer is platform-specific:
Metal on macOS, OpenGL/EGL on Linux.

| Preset | Build dir | Renderer | Output | Use |
|--------|-----------|----------|--------|-----|
| `headless` | `build/` | Linux surfaceless EGL | `mbgl-render` (PNG) | CI / displayless verify |
| `desktop`  | `build-desktop/` | Linux OpenGL + GLFW + Wayland | `mbgl-glfw` (window) | interactive pan/zoom |
| `macos`    | `build-macos/` | macOS Metal (headless) | `mbgl-render` (PNG) | CI / verify on Mac |
| `macos-desktop` | `build-macos-desktop/` | macOS Metal + GLFW | `mbgl-glfw` (window) | interactive pan/zoom |

## Prerequisites

- **First, fetch MapLibre Native** (a git submodule):
  `git submodule update --init --recursive` (clones ~1.6 GB into
  `vendor/maplibre-native/`).
- CMake ≥ 3.25, Ninja, a C++20 compiler.
- macOS: Xcode + command-line tools; `brew install ninja cmake libuv` (libuv is
  used by the darwin run loop). Metal works out of the box.
- Linux: Clang, and for the desktop window `glfw3`, `wayland-client`,
  `wayland-egl`, `wayland-cursor`, `libxkbcommon`, `libepoxy` (standard on Arch).
- First build of `mbgl-core` is large (~15 min on 8 cores). `ccache` (picked up
  automatically if installed) makes rebuilds fast.

## Reference data + styles (one command)

The native app renders tiles + assets produced by the Go reference impl, plus
generated styles. `gen-reference.sh` picks the right prebuilt Go binary for your
OS/arch (`../chartplotter-go/dist/chartplotter_<os>_<arch>_s101`), emits assets,
bakes `annapolis.pmtiles`, and generates the styles:

```sh
scripts/gen-reference.sh           # assets + tiles + styles
# or just styles (if reference data already exists):
scripts/gen-style.sh
```

Reference data and the generated styles are gitignored (they're machine-specific
— the styles embed an absolute PMTiles path). Regenerate after cloning.

(M1 style = areas + lines only. Symbols/soundings/text/patterns arrive at M2.)

## Headless render → PNG (works without a display)

```sh
# Linux:                          macOS:
cmake --preset headless           # cmake --preset macos
ninja -C build mbgl-render        # ninja -C build-macos mbgl-render

# Annapolis harbour, day palette, 2x (chartshot.sh finds whichever build exists):
OUT="$PWD/renders/annapolis.png" LAT=38.978 LON=-76.482 ZOOM=14 RATIO=2 \
  bash scripts/chartshot.sh
# env knobs: STYLE OUT LAT LON ZOOM W H RATIO BEARING DEBUG=1
```

## Desktop window → interactive pan/zoom

```sh
# Linux (Wayland):                          macOS (Metal):
cmake --preset desktop                      # cmake --preset macos-desktop
ninja -C build-desktop mbgl-glfw            # ninja -C build-macos-desktop mbgl-glfw

# the mbgl-glfw path is under <build>/vendor/maplibre-native/platform/glfw/
build-desktop/vendor/maplibre-native/platform/glfw/mbgl-glfw \
  -s style/chart-day.json -x -76.482 -y 38.978 -z 14
```

Mouse drag pans, scroll zooms. On a Linux X11 session instead of Wayland,
reconfigure with `-DMLN_WITH_WAYLAND=OFF -DMLN_WITH_X11=ON`.

## macOS interactive rendering notes (`chart-glfw-zig`)

Getting the GLFW window smooth on macOS (Apple Silicon / Metal / ProMotion) took
some doing. What matters, and why:

- **Conditional tile requests (the flicker fix).** `ZigTileSource` tags each tile
  with an `etag` and returns `notModified` when MapLibre re-requests an unchanged
  tile. Without this, MapLibre re-requested + **re-parsed** tiles 15-60×/sec, and
  each re-parse re-uploaded to the GPU → constant flicker (even at 100-300fps).
  See `app/zig_tile_source.cpp`.
- **In-memory tile cache** (`tilegen/src/capi.zig`): generated/decoded tiles are
  memoized (z<<48|x<<24|y), so re-requests never re-decode.
- **Async present** (`app/metal_backend.mm`): `presentDrawable` + `commit`, like
  MapLibre's own macOS SDK (`MLNMapView+Metal`). `presentsWithTransaction` +
  `waitUntilScheduled`/`waitUntilCompleted` were tried and all stalled/flickered
  on the GLFW (non-CADisplayLink) loop — don't reintroduce them.
- **`nextDrawable` nil-guard + `setAllowsNextDrawableTimeout(false)`**: stops the
  whole-screen blank when the drawable pool is briefly exhausted on fast pan.
- **On-demand render** (default): pan/zoom changes the camera every frame so it
  still presents every frame (smooth); idle stops (low CPU), last frame retained.

Runtime escape hatches: `CHART_CONTINUOUS=1` (present every frame), `CHART_ASYNC=1`
(generate tiles on a worker thread), `CHART_ONDEMAND` is now the default.
