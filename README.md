# chartplotter-native

A native desktop marine chart canvas: **MapLibre Native** (C++ renderer) draws
S-52 nautical charts from vector tiles produced by a **Zig tile generator**.

This is the native sibling of [`chartplotter-go`](../chartplotter-go) (which bakes
NOAA S-57 ENC cells into PMTiles and renders them in the browser with MapLibre GL
JS). Here the same tile pipeline is reimplemented in Zig and the chart is drawn by
MapLibre Native in a desktop window, with platform chrome (SwiftUI / GTK4) to come.

> ⚓ **Not for navigation.** Experimental; built with AI assistance.

## Status

| Milestone | What | State |
|-----------|------|-------|
| M0 | MapLibre Native builds; headless EGL render | ✅ done |
| M1 | Annapolis chart renders from Go-baked PMTiles + ported style (areas + lines, Day/Dusk/Night) | ✅ done |
| M2 | Full S-52 fidelity: symbols, glyphs+text, soundings, area patterns, depth-shading | ✅ done |
| M3 | Own minimal interactive window (clone GLFWView) | next |
| M4 | Zig MVT + gzip + PMTiles + projection/clip, differential-tested vs Go | ✅ done |
| M5 | Live in-process tile generation (`libtilegen.a` + custom `FileSource`) | ✅ done |
| M6a–c | Zig ISO 8211 + S-57 decode + topology → **live cell→MVT→MapLibre** (crude portrayal) | ✅ done |
| M6d | S-57 attributes (✅) + embedded-Lua (✅ Lua 5.4) **S-101 portrayal** → full S-52 from live gen | 🔄 in progress |

See **[docs/PLAN.md](docs/PLAN.md)** for the architecture and **[docs/BUILD.md](docs/BUILD.md)**
for build/run instructions.

## Build

Full details (presets, env knobs, troubleshooting) live in
**[docs/BUILD.md](docs/BUILD.md)**. The short version:

### 0. Get the code + MapLibre Native

```sh
git clone <this-repo> chartplotter-native
cd chartplotter-native
git submodule update --init --recursive     # MapLibre Native (~1.6 GB)
```

Also check out the Go reference repo as a sibling (`../chartplotter-go`) — it
supplies the tiles + S-52 assets the app renders.

### 1. Prerequisites

**macOS** (Apple Silicon or Intel):
```sh
xcode-select --install                       # Clang + Metal
brew install cmake ninja libuv
pip3 install Pillow                           # for the sprite builder
```

**Linux** (Arch shown; adapt for your distro):
```sh
sudo pacman -S --needed cmake ninja clang python-pillow \
  glfw wayland libxkbcommon libepoxy        # glfw+wayland only for the window
# optional but recommended for fast rebuilds:
sudo pacman -S --needed ccache
```

**Zig 0.16.0** — only needed for the Zig tile generator (`tilegen/`, used by the
live-generation host `chartshot-zig`). Not required for the PMTiles paths above.
Install from [ziglang.org/download](https://ziglang.org/download/) (pin 0.16.0)
and put it on `PATH`; CMake finds it automatically. Lua 5.4 is vendored under
`tilegen/vendor/lua` and built into `libtilegen.a` (no system Lua needed).

### 2. Generate the reference data (tiles + assets + styles)

Builds the Go binary's output the app needs (assets, a baked `annapolis.pmtiles`,
sprite sheet, and the styles). Requires `../chartplotter-go` with its prebuilt
`dist/` binaries (or run `make build` there first):

```sh
scripts/gen-reference.sh                      # picks the right Go binary for your OS/arch
```

### 3a. Headless render → PNG (no display needed; good for CI / verifying)

```sh
# macOS:                          Linux:
cmake --preset macos              # cmake --preset headless
ninja -C build-macos mbgl-render  # ninja -C build mbgl-render

OUT="$PWD/renders/annapolis.png" LAT=38.978 LON=-76.482 ZOOM=14 RATIO=2 \
  bash scripts/chartshot.sh        # chartshot.sh finds whichever build dir exists
```

### 3b. Interactive window → pan/zoom

```sh
# macOS (Metal):                          Linux (Wayland):
cmake --preset macos-desktop              # cmake --preset desktop
ninja -C build-macos-desktop mbgl-glfw    # ninja -C build-desktop mbgl-glfw

# run it (path is <build>/vendor/maplibre-native/platform/glfw/mbgl-glfw):
build-macos-desktop/vendor/maplibre-native/platform/glfw/mbgl-glfw \
  -s style/chart-day.json -x -76.482 -y 38.978 -z 14
```

Drag pans, scroll zooms. Swap `chart-day.json` for `chart-dusk.json` /
`chart-night.json`. The first `mbgl-core` build is large (~15 min on 8 cores;
`ccache` makes rebuilds fast).

### 3c. Live Zig generation → PNG (tiles generated from a raw S-57 cell)

Renders straight from a `.000` ENC cell — no pre-baked PMTiles — using the Zig
tile generator (`libtilegen.a`) behind a custom MapLibre `FileSource`. Requires
Zig (see prerequisites).

```sh
ninja -C build chartshot-zig        # or build-macos; builds libtilegen.a via zig
build/chartshot-zig \
  ../chartplotter-go/testdata/US4MD81M.000 \  # a raw S-57 cell (or a .pmtiles)
  style/chart-zig-day.json \                  # zigtiles:// source
  38.97 -76.49 12 renders/from_cell.png
```

`chartshot-zig` auto-detects a PMTiles archive vs a raw S-57 cell. Portrayal is
currently a crude object-class→color map (S-101 Lua rules are in progress);
depth shading from DRVAL1/2 already works.
