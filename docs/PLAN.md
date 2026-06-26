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
  CMake. The Zig tile generator is a leaf static lib (`libtilegen.a`) exposing a
  hand-written C ABI (`include/tilegen.h`), plus a standalone Zig CLI baker.
- **Tile delivery: live in-process is the target.** `libtilegen.a` generates one
  tile's MVT bytes on demand; a custom `mbgl::FileSource` (scheme `zigtiles://`)
  hands them to MapLibre. Cache with an in-memory LRU + disk cache. The offline
  CLI baker is kept too (cheap, and the differential-test driver vs Go).
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
| M0 | MapLibre `mbgl-render` builds (headless EGL) | none | in progress |
| M1 | Pan/zoom the Annapolis chart from `reference/tiles/annapolis.pmtiles` + minimal ported `style.json` (areas + lines) | none | next |
| M2 | S-52 fidelity: sprites/symbols, glyphs+text, soundings, day/dusk/night, depth-shading, SCAMIN | none | |
| M3 | Own minimal window (clone GLFWView); interactive pan/zoom | none | |
| M4 | Zig offline baker (`tile`+`mvt`+`pmtiles`), validated vs Go | Zig CLI | |
| M5 | Live in-process generation via custom `FileSource` + C ABI | Zig lib + glue | |
| M6 | Full Zig pipeline: ISO8211+S-57 decode -> embedded-Lua S-101 -> MVT | Zig | |

## Environment notes

- This dev box is a headless TTY with DRM render nodes (`/dev/dri/renderD128`)
  and Mesa EGL -> offscreen GPU rendering works (`scripts/chartshot.sh`).
- Toolchain: cmake 4.3, clang 22, ninja. No ccache, no passwordless sudo.
  **Zig 0.16.0** to be installed for M4+.
- `MLN_WITH_WERROR=OFF` (clang 22 is bleeding-edge), GLFW off in the headless
  build (enable with Wayland dev libs for the desktop window).

## Layout

```
CMakeLists.txt              top-level integrator
style/build_style.py        generates style/chart-*.json from colortables.json
style/chart-day.json        M1 minimal static style (areas + lines, day palette)
scripts/chartshot.sh        offscreen render -> renders/*.png (verify)
reference/                  parity oracle (gitignored data)
  chartplotter-go/          symlink to ../chartplotter-go
  tiles/annapolis.pmtiles   Go-baked chart (765 tiles)
  assets/                   colortables/linestyles/sprite/patterns (Go-emitted)
vendor/maplibre-native/     embedded MapLibre Native (gitignored; submodule TODO)
app/                        thin C++ host (M3+) + custom FileSource (M5)
include/tilegen.h           C ABI shared Zig<->C++
tilegen/                    Zig static lib + CLI baker (M4+)
tests/mvt_parity/           Go-vs-Zig differential geometry tests (M4+)
```
