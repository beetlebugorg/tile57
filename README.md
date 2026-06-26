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
| M3 | Interactive pan/zoom window serving live Zig tiles (`chartplotter`) | ✅ done |
| M4 | Zig MVT + gzip + PMTiles + projection/clip, differential-tested vs Go | ✅ done |
| M5 | Live in-process tile generation (`libchartplotter.a` + custom `FileSource`) | ✅ done |
| M6a–c | Zig ISO 8211 + S-57 decode + topology → **live cell→MVT→MapLibre** | ✅ done |
| M6d | Embedded-Lua **S-101 portrayal** (real IHO rules + Feature Catalogue) → live S-101 ECDIS chart from a raw cell | ✅ core done (~96% of features; wrecks/clearances polish remain) |

See **[docs/PLAN.md](docs/PLAN.md)** for the architecture, **[docs/BUILD.md](docs/BUILD.md)**
for build/run instructions, **[docs/API.md](docs/API.md)** for the
`libchartplotter` C ABI, and **[CHANGELOG.md](CHANGELOG.md)** for recent changes.

## Build

Full details (presets, env knobs, troubleshooting) live in
**[docs/BUILD.md](docs/BUILD.md)**. The short version:

### 0. Get the code + MapLibre Native

```sh
git clone <this-repo> chartplotter-native
cd chartplotter-native
git submodule update --init --recursive     # MapLibre Native (~1.6 GB) +
                                            # the official IHO S-101 catalogue
                                            # (Portrayal Catalogue + Feature
                                            # Catalogue; ~350 MB for the FC repo)
```

The S-101 catalogue (rules, symbols, color profiles, feature catalogue) is
vendored as submodules under `vendor/` — the Zig portrayal engine and the
asset/tile generation use it directly. You still need the Go reference repo as a
sibling (`../chartplotter` or `../chartplotter-go`) for its binary, which bakes
the PMTiles + emits the S-52 client assets (sprites/colors/glyphs).

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

**Zig 0.16.0** — required for the Zig tile generator (`tilegen/` →
`libchartplotter.a`) and our hosts (`chartplotter`, `chartplotter-render`). Not
needed for the upstream `mbgl-render`/`mbgl-glfw` PMTiles paths. Install from
[ziglang.org/download](https://ziglang.org/download/) (pin 0.16.0) and put it on
`PATH`; CMake finds it automatically. Lua 5.4 is vendored under
`tilegen/vendor/lua` and built into `libchartplotter.a` (no system Lua needed).

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

### 3b. Interactive window → pan/zoom (live Zig tiles)

`chartplotter` (M3) opens a real pannable/zoomable window whose vector tiles come
from the in-process Zig generator (`libchartplotter.a`) — the same source the
headless `chartplotter-render` uses, but interactive. It takes a PMTiles archive
**or** a raw `.000` ENC cell (live generation).

```sh
# macOS (Metal):                          Linux (Wayland):
cmake --preset macos-desktop              # cmake --preset desktop
ninja -C build-macos-desktop chartplotter   # ninja -C build-desktop chartplotter

# run it (frames the data extent if lat/lon/zoom omitted):
build-macos-desktop/chartplotter \
  reference/tiles/annapolis.pmtiles \     # or a raw .000 cell for live generation
  style/chart-zig-day.json 38.978 -76.487 13
```

Drag pans, scroll zooms. The first `mbgl-core` build is large (~15 min on 8
cores; `ccache` makes rebuilds fast). Requires Zig (see prerequisites).

The upstream `mbgl-glfw` demo also builds, for rendering any style directly:
`ninja -C build-desktop mbgl-glfw` then
`build-desktop/vendor/maplibre-native/platform/glfw/mbgl-glfw -s style/chart-zig-day.json -x -76.482 -y 38.978 -z 14`.

### 3c. Live Zig generation → PNG (tiles generated from a raw S-57 cell)

Renders straight from a `.000` ENC cell — no pre-baked PMTiles — using the Zig
tile generator (`libchartplotter.a`) behind a custom MapLibre `FileSource`.
Requires Zig (see prerequisites).

```sh
ninja -C build chartplotter-render  # or build-macos; builds libchartplotter.a via zig
build/chartplotter-render \
  ../chartplotter-go/testdata/US4MD81M.000 \  # a raw S-57 cell (or a .pmtiles)
  style/chart-zig-day.json \                  # zigtiles:// source
  38.97 -76.49 12 renders/from_cell.png
```

`chartplotter-render` auto-detects a PMTiles archive vs a raw S-57 cell, and runs
the embedded-Lua S-101 portrayal (real IHO rules) over the cell. The live path
emits `areas`, `area_patterns`, `lines`, `complex_lines`, `point_symbols`,
`soundings` and `text` — depth shading, contours, coastline, soundings, symbols
and labels (light sectors / SCAMIN declutter variants are next — see
`specs/s101-port.md`).
