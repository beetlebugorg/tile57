# chartplotter-native — architecture & milestone plan

A native (desktop) chart canvas: **MapLibre Native** (C++ renderer) draws S-52
nautical charts from vector tiles produced by a **Zig tile generator**. The Go
project at `../chartplotter-go` is the reference implementation and the parity
oracle. Platform chrome (SwiftUI / GTK4) comes later; the first goal is a window
you can pan/zoom.

## Pipeline (mirrors the Go impl)

```
S-57 ENC cell (.000)
  -> ISO 8211 decode            (Zig: iso8211.zig)        [M6]
  -> S-57 feature/geometry model (Zig: s57.zig)           [M6]
  -> S-101 portrayal (Lua rules) (Zig + embedded Lua 5.4) [M6]
  -> primitive drawing list      (Zig: portrayal/)        [M6]
  -> web-mercator project + clip (Zig: tile.zig)          [M4]
  -> Mapbox Vector Tiles         (Zig: mvt.zig)           [M4]
  -> tiles to MapLibre Native    (live in-process)        [M5]
```

Tiles carry **color tokens** (not RGB); the style resolves Day/Dusk/Night from
`colortables.json`. 11 vector layers: `areas`, `area_patterns`, `lines`,
`complex_lines` (+ their `*_scamin` SCAMIN buckets), `point_symbols`,
`soundings`, `text`. Extent 4096, buffer 64.

## Key decisions (locked)

- **Build topology:** CMake is the top-level integrator. MapLibre Native is
  embedded via `add_subdirectory(vendor/maplibre-native)` and built by its own
  CMake. The Zig tile generator is a leaf static lib (`libchartplotter.a`,
  built from `tilegen/`) exposing a hand-written C ABI (`include/chartplotter.h`,
  `cp_*`), plus a standalone Zig CLI baker.
- **Tile delivery: live in-process is the target.** `libchartplotter.a` generates
  one tile's MVT bytes on demand; the `ChartTileSource` `mbgl::FileSource` (scheme
  `zigtiles://`) hands them to MapLibre. Tiles are memoized in an in-process cache
  (`cp_source_clear_cache` bounds it). The offline CLI baker is kept too (cheap,
  and the differential-test driver vs Go).
- **MapLibre integration point:** custom `mbgl::FileSource` returning MVT bytes
  in `Response.data` (clone `pmtiles_file_source.cpp`). Native `pmtiles://` is
  the bootstrap/fallback and is what M0–M2 use against Go-baked archives.
- **S-101 rules: embed Lua 5.4** (via ziglua), do NOT port the ~216 IHO Lua
  rule files. They are executable spec; replicate the ~30 `Host*` query
  functions in Zig.
- **Renderer:** OpenGL via surfaceless **EGL** (headless verify -> PNG here;
  GLFW/Wayland window on the desktop).

## Milestones (each independently demoable)

| M  | Deliverable | Zig? | Status |
|----|-------------|------|--------|
| M0 | MapLibre `mbgl-render` builds (headless EGL) | none | ✅ done |
| M1 | Pan/zoom the Annapolis chart from `reference/tiles/annapolis.pmtiles` + minimal ported `style.json` (areas + lines) | none | ✅ done |
| M2 | S-52 fidelity: symbols, glyphs+text, soundings, area patterns, day/dusk/night, depth-shading | none | ✅ done |
| M3 | Own window (`chartplotter`, reuses GLFWView); interactive pan/zoom of live Zig tiles | C++ glue | ✅ done |
| M4 | Zig encoder core: mvt + gzip + pmtiles + tile (project/clip), differential-tested vs Go | Zig CLI | ✅ done |
| M5 | Live in-process generation via custom `FileSource` + C ABI | Zig lib + glue | ✅ done |
| M6a | ISO 8211 decoder (parses real cells) | Zig | ✅ done |
| M6b | S-57 model: dataset params, vectors, features | Zig | ✅ done |
| M6c | Topology assembly + **live cell→MVT→MapLibre** (crude classify()) | Zig | ✅ done |
| M6d | S-57 attributes (ATTF) + embedded-Lua S-101 portrayal -> full S-52 | Zig + Lua | ✅ core done (~96% of features; see specs/s101-port.md) |

## Environment notes

- This dev box is a headless TTY with DRM render nodes (`/dev/dri/renderD128`)
  and Mesa EGL -> offscreen GPU rendering works (`scripts/chartshot.sh`).
- Toolchain: cmake 4.3, clang 22, ninja, **Zig 0.16.0** (installed; required for
  the tile generator). `ccache` used if present.
- `MLN_WITH_WERROR=OFF` (clang 22 is bleeding-edge), GLFW off in the headless
  build (enable with Wayland dev libs for the desktop window).

## Layout

```
CMakeLists.txt              top-level integrator
style/build_style.py        generates style/chart-*.json from colortables.json
style/chart-zig-day.json    S-52 style backed by the zigtiles:// source
scripts/chartshot.sh        offscreen render -> renders/*.png (verify, via mbgl-render)
scripts/dev-rebuild.sh      after-pull refresh: regen styles + rebuild our hosts
reference/                  parity oracle (gitignored data)
  tiles/annapolis.pmtiles   Go-baked chart (765 tiles)
  assets/                   colortables/linestyles/sprite/patterns (Go-emitted)
vendor/maplibre-native/     embedded MapLibre Native (git submodule)
vendor/S-101_Portrayal-Catalogue/  official IHO S-101 rules (git submodule)
app/                        C++ hosts (chartplotter, chartplotter-render) +
                            ChartTileSource (the custom FileSource)
include/chartplotter.h      public C ABI (cp_*); chartplotter_diag.h = dev self-tests
tilegen/                    Zig tile generator -> libchartplotter.a + CLI baker
tests/mvt_parity/           Go-vs-Zig differential geometry tests
```
