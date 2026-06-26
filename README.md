<h1 align="center">chartplotter-native</h1>

<p align="center">
  <b>⚓ Marine chart tiles, generated natively in Zig.</b><br>
  A Zig engine turns NOAA S-57 ENC cells into S-52 marine chart tiles, drawn live by MapLibre Native (Metal / OpenGL) in a desktop window.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  &nbsp;·&nbsp;
  📚 <b><a href="https://beetlebugorg.github.io/chartplotter-native/">Read the docs →</a></b>
</p>

---

> [!WARNING]
> **Not for navigation.** This project is coded almost entirely with AI (Claude).
> It is an experiment in building a large, complex specification (IHO S-101) with
> AI, and a personal learning tool — not a certified or tested product. Do not rely
> on it for real-world navigation. See
> [Known limitations](https://beetlebugorg.github.io/chartplotter-native/limitations).

---

**chartplotter-native** generates **marine chart tiles** natively and draws them
in a real desktop window. A **Zig tile generator** (`libchartplotter.a`) turns
NOAA **S-57** ENC cells into S-52 marine chart tiles — running the official IHO
**S-101 Portrayal Catalogue** in embedded Lua — and
**[MapLibre Native](https://github.com/maplibre/maplibre-native)** draws them
(Metal on macOS, OpenGL/EGL on Linux). Tiles are generated live and in-process
behind a custom MapLibre `FileSource`, so it renders straight from a raw `.000`
cell; reading a pre-baked PMTiles archive works too.

It is the native sibling of
[**chartplotter-go**](https://github.com/beetlebugorg/chartplotter), which bakes the
same charts into PMTiles for the browser. The Go project is the parity oracle; the
Zig pipeline mirrors it stage for stage.

## How it works

```
S-57 ENC cell (.000)
   │  ISO 8211 decode                 tilegen/src/iso8211.zig
   ▼
S-57 feature + geometry model         tilegen/src/s57.zig
   │  S-101 portrayal (embedded Lua)  tilegen/src/portray.zig
   ▼
Primitive instruction stream
   │  project + clip + encode         tilegen/src/{s57_mvt,tile,mvt}.zig
   ▼
Mapbox Vector Tiles  ─────────────▶   MapLibre Native  (ChartTileSource FileSource)
```

The pipeline lives in `libchartplotter.a` behind a small
[C ABI](https://beetlebugorg.github.io/chartplotter-native/c-api)
(`include/chartplotter.h`, `chartplotter_*`).

## Build

Needs CMake, Ninja, a C++20 compiler, and **Zig 0.16**. Fetch the submodules
(MapLibre Native + the IHO S-101 catalogue), then build:

```sh
git submodule update --init --recursive
scripts/gen-reference.sh                       # tiles + assets + styles (needs ../chartplotter-go)

cmake --preset headless                        # or: desktop / macos / macos-desktop
ninja -C build chartplotter-render
build/chartplotter-render \
  ../chartplotter-go/testdata/US4MD81M.000 \   # a raw S-57 cell (or a .pmtiles)
  style/chart-zig-day.json 38.97 -76.49 12 renders/from_cell.png
```

Full instructions are in the
[**docs**](https://beetlebugorg.github.io/chartplotter-native/installation).

## What the build produces

| Target | What it is |
|--------|-----------|
| `libchartplotter.a` | the Zig tile generator + its C ABI |
| `chartplotter-render` | headless host: chart → PNG (PMTiles or a live S-57 cell) |
| `chartplotter` | interactive GLFW window: pan/zoom a live chart (desktop presets) |

## Documentation

Full docs (built with Docusaurus, source in [`docs/`](docs/)) live at
**[beetlebugorg.github.io/chartplotter-native](https://beetlebugorg.github.io/chartplotter-native/)**:
[installation](https://beetlebugorg.github.io/chartplotter-native/installation),
[getting started](https://beetlebugorg.github.io/chartplotter-native/getting-started),
the [C API](https://beetlebugorg.github.io/chartplotter-native/c-api),
the [architecture](https://beetlebugorg.github.io/chartplotter-native/architecture),
and the [tile schema](https://beetlebugorg.github.io/chartplotter-native/tile-schema).

See also [`CHANGELOG.md`](CHANGELOG.md).

## License

chartplotter-native's own code is [MIT](LICENSE) © Jeremy Collins. It embeds
MapLibre Native (BSD) and the IHO S-101 Portrayal Catalogue (© IHO). NOAA ENC
charts are U.S. public domain and **not for navigation**.
