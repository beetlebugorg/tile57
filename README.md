<h1 align="center">tile57</h1>

<p align="center">
  <b>⚓ Official nautical charts, ready to draw.</b><br>
  tile57 reads IHO <b>S-101</b> and <b>S-57</b> charts and gives a renderer what it
  needs: vector tiles with a matching MapLibre S-52 style, a draw-ready GPU scene,
  pixel draw calls, or finished PNG and PDF. It also reads <b>raster charts</b> —
  satellite photos and RNC sheets — and draws the official chart on top of them.
  It reports the objects under a point, and the text and pictures a chart carries.
  One Zig library with a C ABI.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  &nbsp;·&nbsp;
  📚 <b><a href="docs/docs/intro.md">Docs →</a></b>
</p>

---

> [!WARNING]
> **Not for navigation.** This is not a certified navigation product. Do not use it
> to navigate. Refer to [Known limitations](docs/docs/limitations.md).

---

Hydrographic offices publish charts as S-101 and S-57 datasets. Those formats
carry the survey, not a picture of it. tile57 reads them and produces the picture,
in the form your renderer wants: vector tiles, a draw-ready GPU scene, pixel draw
calls, or a finished page. It also answers questions about the chart — which
objects sit under a point, what the chart states about them, and the notes and
diagrams it carries.

## Why it is different

- **The portrayal is official, not an imitation.** tile57 runs the IHO **S-101
  Portrayal Catalogue** against the feature records in the chart. No symbol is a
  look-alike. You get depth areas and contours, buoys and beacons with correct
  symbols, lights with sector lines, soundings, and place names.
- **It reads the format the world is moving to.** A native S-101 chart feeds the
  portrayal engine directly. tile57 converts an S-57 chart to the same S-101 model
  first, so everything above the conversion sees one model.
- **It renders more than tiles.** The same engine writes PNG, PDF, and a callback
  stream your own renderer can paint. It also answers cursor picks.
- **It feeds a GPU directly.** tile57 portrays a whole view into one draw-ready
  scene: vertex and quad buffers, a uniform block, and ranges already sorted into
  paint order. A host uploads it once, then walks the ranges. Geometry stays
  north-up in world space and the host applies the view rotation, so a course-up
  view that turns continuously never rebuilds its scene. The repo ships reference
  shaders for Metal, Direct3D and Vulkan.
- **It combines raster charts and satellite photos with the official chart.**
  Add your own satellite photos as MBTiles, or an RNC sheet as BSB/KAP. tile57
  draws them below the official chart. The official chart then removes its solid
  blue and yellow areas, so you can see the photo through them. All the depth
  contours, buoys, lights and soundings stay on top. If your chart is old, you
  see the place as it is today, and you read the official marks over it. On a
  GPU this happens pixel by pixel, so the chart keeps its colors everywhere the
  photo does not reach. tile57 also quilts many RNC sheets into one map. For
  each area it uses the sheet with the correct scale for your zoom. Where two
  sheets cover the same water at that scale, it uses the newer edition. This is
  the rule it uses for official charts. See [Raster charts](docs/docs/raster-charts.md).
- **It embeds anywhere.** The core is pure Zig with a C ABI.

## Start here

```sh
git submodule update --init --recursive       # the vendored S-101 catalogue
zig build                                     # writes zig-out/bin/tile57

tile57 bake ENC_ROOT -o out/                  # every chart -> its own archive
tile57 png ENC_ROOT --view -76.48,38.974,15 --size 1600x1200 -o chart.png

tile57 raster info photos.mbtiles             # what the file really contains
tile57 bake harbour.KAP -o out/               # an RNC sheet -> the same archive
tile57 png ENC_ROOT --over-image --view -76.48,38.974,15 -o over.png
```

The first command bakes a catalogue. The second draws a chart straight to a PNG.
The last one removes the chart's solid areas, so you can draw it over a photo.

## What you can get

| Output | Call | What it is |
|---|---|---|
| **Vector tiles** | `tile57_compose_tile` | MapLibre Tiles (MLT) or Mapbox Vector Tiles, by `(z, x, y)` |
| **Style + assets** | `tile57_style_build`, `tile57_bake_assets` | A MapLibre GL style, colour tables, line styles, sprite and pattern atlases |
| **PNG** | `tile57_chart_png` | A finished raster view |
| **PDF** | `tile57_chart_pdf` | A vector page, 1 px = 1 pt |
| **Draw calls** | `tile57_chart_canvas` | Pixel-space paint calls for your own rasterizer |
| **Tagged geometry** | `tile57_chart_surface` | World-space geometry, each call tagged with its S-57 class |
| **GPU scene** | `tile57_chart_gpu_scene` | Draw-ready vertex, quad and range buffers, plus the sprite and SDF atlases |
| **Pick** | `tile57_chart_query` | The objects under a point, with their attributes |
| **Notes and diagrams** | `tile57_aux_get` | The text and picture files a chart's features point at |
| **Raster charts** | `tile57_raster_chart_*` | Tiles from a satellite photo file or a BSB/KAP RNC sheet |
| **Quilted RNC** | `tile57_compose_rasters` | Many RNC sheets as one quilted map |

MLT is the default tile encoding. MapLibre GL JS 5.12 and later decode it natively.

---

# Technical reference

## How it works

tile57 reads two source formats. Both are `.000` files — a *cell*, in the spec's
vocabulary — and tile57 detects which one it holds from the file itself. Both
converge on the same S-101 feature records.

```
S-101 ENC (.000)              S-57 ENC chart (.000)
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
             ├───► PNG raster / vector PDF / terminal text (src/render/)
             └───► draw-ready GPU scene (src/render/gpu.zig)  +  shaders/
```

tile57 reads a native S-101 chart straight into the S-101 model. That chart's
in-band code tables already carry the S-101 class and attribute names, so no
conversion runs. tile57 applies the chart's update files on load. tile57 reads an
S-57 chart into the S-57 model and adapts it. The adaptation follows S-65 and is
best-effort. Refer to [limitations](docs/docs/limitations.md).

Each stage is a separate Zig module: `iso8211`, `s57`, `s101`, `tiles`, `render`,
`scene`, and `style`. Those modules need no libc. Only the Lua portrayal
(`portray`) and the sprite rasterizer (`sprite`) use C. Refer to
[the architecture docs](docs/docs/architecture.md).

## How it holds memory

- **Work is lazy, and it is per chart.** tile57 indexes a multi-chart ENC_ROOT by
  band and bounding box. It parses and portrays a chart only when a requested tile
  needs it. An LRU bound caps how many it holds. A streaming open reads a chart's
  bytes on demand and frees them on eviction.
- **Each chart bakes on its own.** Each chart bakes to its own PMTiles archive at
  its compilation scale. A bake holds one chart at a time. The runtime compositor
  stitches the archives by `(z, x, y)` on demand. There is no merged archive.

## Use it from Zig

Add tile57 as a dependency, then import it:

```zig
const tile57 = @import("tile57");

// Open an ENC_ROOT directory, or a single .000 file, as a streaming chart.
var chart = try tile57.Chart.openPath("ENC_ROOT/", null, true);
defer chart.deinit();

const bbox = chart.bounds();   // geographic extent [w, s, e, n], or null
// … render a view (chart.renderView), query features, or bake an archive …
```

`Chart` renders views, queries features, and reads metadata. Refer to
[the Zig API docs](docs/docs/zig-api.md).

## Use it from C

The same engine sits behind a thin C ABI
([`include/tile57.h`](include/tile57.h)). `tile57 bake ENC_ROOT -o out/` writes one
directory per chart. `tile57_compose_tree` opens that whole tree in one call and
serves any tile on demand.

```c
// out/ holds <CHART>/<CHART>.pmtiles per chart, with the files that chart
// references, plus out/partition.tpart.
tile57_compose *c = NULL;
uint32_t charts = 0;
if (tile57_compose_tree("out/", &c, &charts, NULL) != TILE57_OK)
    return 1;

uint8_t *tile = NULL;
size_t len = 0;
if (tile57_compose_tile(c, z, x, y, &tile, &len, NULL, NULL) == TILE57_OK && tile) {
    /* … hand the decompressed MLT tile to your renderer … */
    tile57_free(tile);
}
tile57_compose_close(c);
```

A `tile57_chart` handle renders PNG and PDF views and answers metadata and object
queries. `libtile57.a` also exposes the MapLibre style builder and the asset
generators. Refer to [the C API docs](docs/docs/c-api.md).

## The `tile57` CLI

The offline tool bakes charts and emits portrayal assets. Every command takes a
native S-101 or an S-57 `.000` file, and tile57 detects the format.

```sh
tile57 bake CELL.000 -o out/                 # one chart -> out/<CELL>/<CELL>.pmtiles
tile57 bake ENC_ROOT -o out/                 # a catalogue -> one directory per chart
tile57 assets   -o assets/                   # colortables + linestyles + sprite + patterns
tile57 png ENC_ROOT --view -76.48,38.974,15 --size 1600x1200 -o chart.png
tile57 pdf ENC_ROOT --view -76.48,38.974,15 --size 1600x1200 -o chart.pdf
tile57 ascii CELL.000 --view -76.48,38.974,13 --ansi --tui    # the chart in your terminal
tile57 s101 CELL.000                         # inspect a native S-101 dataset
```

## Build

The Zig engine and the CLI need Zig 0.16 only:

```sh
git submodule update --init --recursive   # the vendored S-101 catalogue
zig build && zig build test
```

Refer to [docs/installation](docs/docs/installation.md) for full instructions.

## Documentation

The docs source is in [`docs/`](docs/): [intro](docs/docs/intro.md),
[getting started](docs/docs/getting-started.md), the
[Zig API](docs/docs/zig-api.md), the [C API](docs/docs/c-api.md),
the [architecture](docs/docs/architecture.md), and the
[tile schema](docs/docs/tile-schema.md).

## AI-First Development

This project is built with AI assistance. Use AI tools freely. The most useful
contribution is a clear set of requirements, or a rough prototype of what you
want, rather than a patch. Refer to the
[contributing guide](docs/docs/contributing.md).

## License

tile57's own code is [MIT](LICENSE) © Jeremy Collins. It embeds the IHO S-101
Portrayal Catalogue (© IHO). It vendors nanosvg (zlib) and stb_image_write (public
domain). NOAA ENC charts are U.S. public domain and **not for navigation**.
