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
in a real desktop window. A **Zig tile generator** (`libtile57`) turns NOAA
**S-57** ENC cells into S-52 marine chart tiles — running the official IHO
**S-101 Portrayal Catalogue** in embedded Lua — and the **`libchartplotter`**
widget draws them with
**[MapLibre Native](https://github.com/maplibre/maplibre-native)** (Metal on
macOS, OpenGL/EGL on Linux). Tiles are generated live and in-process behind a
custom MapLibre `FileSource`, so it renders straight from a raw `.000` cell — or a
whole **ENC_ROOT** directory (every cell + its `.001…` updates, overlaid).
Reading a pre-baked PMTiles archive works too.

It is the native sibling of
[**chartplotter-go**](https://github.com/beetlebugorg/chartplotter), which bakes the
same charts into PMTiles for the browser. The Go project is the parity oracle; the
Zig pipeline mirrors it stage for stage.

## How it works

```
S-57 ENC cell (.000)
   │  ISO 8211 decode                 engine/src/iso8211/   (pkg: iso8211)
   ▼
S-57 feature + geometry model         engine/src/s57/       (pkg: s57)
   │  S-101 portrayal (embedded Lua)  engine/src/portray/ (pkg) + engine/src/s100/ (pkg: s100)
   ▼
Primitive instruction stream
   │  project + clip + encode         engine/src/{s57_mvt,tile,mvt}/  (packages)
   ▼
Mapbox Vector Tiles  ─────────────▶   MapLibre Native  (ChartTileSource FileSource)
```

The foundational stages are standalone Zig packages — **`iso8211`**, **`s57`**,
**`s100`** — mirroring the Go oracle's `pkg/iso8211`, `pkg/s57`, `pkg/s100`, so the
two implementations line up package for package.

Two libraries: **`libtile57`** is the tile pipeline (`tile57_*`,
`include/tile57.h`); **`libchartplotter`** is the headless chart renderer
(`chartplotter_*`, `include/chartplotter.h`) that draws a chart to a PNG. The
interactive window is a separate **Qt6** app — `chartplotter-qt` (`app/qt`), built
on the [QMapLibre](https://github.com/maplibre/maplibre-native-qt) widget.
See the [C APIs](https://beetlebugorg.github.io/chartplotter-native/c-api).

## Build

Needs CMake, Ninja, a C++20 compiler, and **Zig 0.16**. Fetch the submodules
(MapLibre Native + the IHO S-101 catalogue), then build:

```sh
git submodule update --init --recursive
scripts/gen-reference.sh                       # tiles + assets + styles (needs ../chartplotter-go)

cmake --preset headless                        # or: macos
ninja -C build chartplotter-render
build/chartplotter-render \
  ../chartplotter-go/testdata/US4MD81M.000 \   # a cell, a .pmtiles, or an ENC_ROOT dir
  style/chart-zig-day.json 38.97 -76.49 12 renders/from_cell.png
```

Full instructions are in the
[**docs**](https://beetlebugorg.github.io/chartplotter-native/installation).

## What the build produces

| Target | What it is |
|--------|-----------|
| `libchartplotter.a` | the headless chart **renderer** (chart → PNG), `chartplotter_*` |
| `libtile57.a` | the Zig S-57 **tile generator** + its `tile57_*` C ABI |
| `chartplotter-render` | headless host: chart → PNG (PMTiles, an S-57 cell, or an ENC_ROOT) |
| `chartplotter-qt` | interactive **Qt6** chart window (QMapLibre); build via `scripts/build-qmaplibre.sh` |
| `chartplotter-bake` | offline CLI: bake a cell/ENC_ROOT to PMTiles, or emit a self-contained **chart bundle** (tiles + portrayal assets + manifest) |

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
