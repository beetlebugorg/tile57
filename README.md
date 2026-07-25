<h1 align="center">tile57</h1>

<p align="center">
  <b>⚓ An S-101 / S-57 chart engine: vector tiles, S-52 styles, PNG and PDF.</b><br>
  tile57 reads native IHO <b>S-101</b> ENC charts — and legacy <b>S-57</b> cells — and turns
  them into vector tiles (MLT or MVT) with a matching MapLibre S-52 style, or renders finished
  charts directly to PNG and PDF — one Zig library with a C ABI, compiled natively or to WASM.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  &nbsp;·&nbsp;
  📚 <b><a href="docs/docs/intro.md">Docs →</a></b>
</p>

---

> [!WARNING]
> **Not for navigation.** This is not a certified or tested navigation product. Do not rely
> on it for real-world navigation. See [Known limitations](docs/docs/limitations.md).

---

**tile57** reads native IHO **S-101** ENC charts (S-100 Part 10a) *and* legacy
NOAA/IHO **S-57** ENC cells — the format is detected from the `.000` file itself —
and generates **vector tiles** by `(z, x, y)`: MapLibre Tiles (MLT, the default;
MapLibre GL JS ≥ 5.12 decodes them natively) or Mapbox Vector Tiles. A native
S-101 dataset feeds the portrayal engine directly; an S-57 cell is converted to
the S-101 model first. Either way, the official IHO **S-101 Portrayal Catalogue**
runs in embedded Lua to produce S-52 nautical portrayal. Alongside the tiles it
emits a **MapLibre GL style** and the portrayal **assets** it references — colour
tables, line styles, and the sprite + area-fill pattern atlases — so a renderer
like [MapLibre](https://github.com/maplibre/maplibre-native) can draw a chart
directly.

It holds only its working set:

- **Lazy, per-cell work.** A multi-cell ENC_ROOT is indexed cheaply (band + bbox);
  cells are parsed and portrayed only when a requested tile needs them, then held
  under an LRU bound. A **streaming** open reads a cell's bytes on demand (and
  frees them on eviction), so a host holds only the working set — not the whole
  catalogue.
- **Per-cell bakes.** Each ENC cell bakes to its own PMTiles at its compilation
  scale, so a bake holds one cell at a time; the runtime compositor stitches the
  cells by `(z, x, y)` on demand.
- **Pure-Zig core.** The foundational format/encode packages have no libc; only
  the Lua portrayal + sprite rasterizer pull in C.

## Pipeline

Both source formats converge on the same S-101 feature records — a native S-101
dataset produces them directly; an S-57 cell is adapted into them:

```
S-101 ENC (.000)              S-57 ENC cell (.000)
   │ ISO 8211 decode             │ ISO 8211 decode          src/iso8211/
   ▼                             ▼
S-100 spatial + feature       S-57 feature + geometry       src/s57/  ·  src/s101/
   records                       model
   │ assemble to S-101           │ adapt S-57 → S-101        (native.zig / adapter.zig)
   └──────────────┬──────────────┘
                  ▼
S-101 feature records
   │  S-101 portrayal (embedded Lua)     src/portray/ + rules
   ▼
portrayal instruction stream             src/s101/ (instructions)
   │  scene generation                   src/scene/  (project + clip + draw calls)
   ▼
render Surface ──► MVT / MLT tiles (src/tiles/)  +  MapLibre style.json + assets
             └───► PNG raster / vector PDF / terminal text (src/render/)
```

A native S-101 chart is read straight into the S-101 model — its in-band code
tables already carry the S-101 class and attribute names — so no conversion runs;
its `.001…` update files are applied on load. An S-57 cell is read into the S-57
model and adapted (a best-effort, S-65-guided step; see
[limitations](docs/docs/limitations.md)). The stages are separate Zig modules —
`iso8211`, `s57`, `s101`, `tiles`, `render`, `scene`, `style` — pure Zig with no
libc; only the Lua portrayal (`portray`) and the sprite rasterizer (`sprite`) pull
in C. See [the architecture docs](docs/docs/architecture.md).

## Use it from Zig

Add tile57 as a dependency, then `@import("tile57")`:

```zig
const tile57 = @import("tile57");

// Open an on-disk ENC_ROOT directory (or a single .000 file) as a streaming chart.
var chart = try tile57.Chart.openPath("ENC_ROOT/", null, true);
defer chart.deinit();

const bbox = chart.bounds();   // geographic extent [w, s, e, n], or null
// … render a view (chart.renderView), query features, or bake an archive …
```

`Chart` renders views, queries features, and reads metadata. The runtime tile
path — bake each cell, then compose by `(z, x, y)` on demand — is exposed through
the [C ABI](include/tile57.h). See [the Zig API docs](docs/docs/zig-api.md).

## Use it from C

The same engine behind a thin C ABI ([`include/tile57.h`](include/tile57.h)).
Tiles are made one way — bake each cell to its own PMTiles, then compose on
demand — the structure `tile57 bake ENC_ROOT -o out/` writes:

```c
// out/ holds tiles/<CELL>.pmtiles (one per cell) + partition.tpart
const char *paths[] = { "out/tiles/US5MD1MC.pmtiles" };
tile57_compose_source *src = tile57_compose_open(paths, 1, "out/partition.tpart");

uint8_t *tile; size_t n;
if (tile57_compose_serve(src, z, x, y, &tile, &n) == 1) {   /* decompressed MLT */
    /* … hand the tile to your renderer … */
    tile57_free(tile, n);
}
tile57_compose_close(src);
```

A separate `tile57_chart` handle renders finished PNG/PDF views and answers
metadata + object queries; `libtile57.a` also exposes the MapLibre style builder
and the asset/atlas generators. See [the C API docs](docs/docs/c-api.md).

## The `tile57` CLI

The offline tool bakes charts and emits portrayal assets:

Any `.000` — native S-101 or S-57 — works everywhere; the format is auto-detected.

```sh
zig build                                    # builds zig-out/bin/tile57
tile57 bake CELL.000 -o out/                 # one cell -> out/tiles/<CELL>.pmtiles + partition.tpart
tile57 bake ENC_ROOT -o out/                 # whole catalogue -> per-cell tiles/ + partition.tpart
tile57 assets   -o assets/                   # colortables + linestyles + sprite + patterns
tile57 png ENC_ROOT --view -76.48,38.974,15 --size 1600x1200 -o chart.png
tile57 pdf ENC_ROOT --view -76.48,38.974,15 --size 1600x1200 -o chart.pdf
tile57 ascii CELL.000 --view -76.48,38.974,13 --ansi --tui    # the chart in your terminal
tile57 s101 CELL.000                         # inspect a native S-101 dataset
```

## Build

The Zig engine + CLI need only **Zig 0.16**:

```sh
git submodule update --init --recursive   # vendored S-101 catalogue
zig build && zig build test
```

Full instructions: [docs/installation](docs/docs/installation.md).

## Documentation

Docs source lives in [`docs/`](docs/): [intro](docs/docs/intro.md),
[getting started](docs/docs/getting-started.md), the
[Zig API](docs/docs/zig-api.md), the [C API](docs/docs/c-api.md),
the [architecture](docs/docs/architecture.md), and the
[tile schema](docs/docs/tile-schema.md).

## AI-First Development

This project is built with AI assistance. We encourage contributors to use AI tools for
development and to contribute by providing clear requirements and/or a prototype of what
they'd like rather than code. See the [contributing guide](docs/docs/contributing.md).

## License

tile57's own code is [MIT](LICENSE) © Jeremy Collins. It embeds the IHO S-101
Portrayal Catalogue (© IHO) and vendors nanosvg (zlib) + stb_image_write (public
domain). NOAA ENC charts are U.S. public domain and **not for navigation**.
