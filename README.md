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
| M4 | Zig offline MVT/PMTiles baker, validated vs Go | |
| M5 | Live in-process tile generation (`libtilegen.a` + custom `FileSource`) | |
| M6 | Full Zig pipeline: ISO8211 + S-57 decode → embedded-Lua S-101 portrayal → MVT | |

See **[docs/PLAN.md](docs/PLAN.md)** for the architecture and **[docs/BUILD.md](docs/BUILD.md)**
for build/run instructions.

## Quick start

```sh
# 1. reference data (needs the Go binary) — see docs/BUILD.md
# 2. headless render to PNG (no display needed)
cmake --preset headless && ninja -C build mbgl-render
OUT="$PWD/renders/annapolis.png" LAT=38.978 LON=-76.482 ZOOM=14 RATIO=2 bash scripts/chartshot.sh

# 3. interactive window (Wayland desktop)
cmake --preset desktop && ninja -C build-desktop mbgl-glfw
build-desktop/vendor/maplibre-native/platform/glfw/mbgl-glfw \
  -s style/chart-day.json -x -76.482 -y 38.978 -z 14
```
