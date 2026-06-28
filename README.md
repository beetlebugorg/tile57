<h1 align="center">tile57</h1>

<p align="center">
  <b>⚓ A high-performance, low-memory S-57 → MVT vector-tile + S-52 style engine.</b><br>
  tile57 turns IHO S-57 ENC cells into Mapbox Vector Tiles plus a MapLibre S-52
  style and its portrayal assets — embeddable from Zig or C.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  &nbsp;·&nbsp;
  📚 <b><a href="docs/docs/intro.md">Docs →</a></b>
</p>

---

> [!WARNING]
> **Not for navigation.** This project is coded almost entirely with AI (Claude).
> It is an experiment in building a large, complex specification (IHO S-101) with
> AI, and a personal learning tool — not a certified or tested product. Do not rely
> on it for real-world navigation. See [Known limitations](docs/docs/limitations.md).

---

**tile57** decodes NOAA/IHO **S-57** ENC cells and generates **Mapbox Vector
Tiles** by `(z, x, y)`, running the official IHO **S-101 Portrayal Catalogue** in
embedded Lua to produce S-52 nautical portrayal. Alongside the tiles it emits a
**MapLibre GL style** and the portrayal **assets** it references — colour tables,
line styles, and the sprite + area-fill pattern atlases — so a renderer like
[MapLibre](https://github.com/maplibre/maplibre-native) can draw a chart directly.

It is **high-performance and low-memory** by design:

- **Lazy, per-cell work.** A multi-cell ENC_ROOT is indexed cheaply (band + bbox);
  cells are parsed and portrayed only when a requested tile needs them, then held
  under an LRU bound. A **streaming** open reads a cell's bytes on demand (and
  frees them on eviction), so a host holds only the working set — not the whole
  catalogue.
- **Band-streamed bakes.** Baking an ENC_ROOT to one PMTiles archive streams
  band-by-band (finest → coarsest, best-band dedup), so peak memory tracks the
  largest single band.
- **Pure-Zig core.** The foundational format/encode packages have no libc; only
  the Lua portrayal + sprite rasterizer pull in C.

## Pipeline

```
S-57 ENC cell (.000)
   │  ISO 8211 decode                    engine/src/iso8211/   (pkg: iso8211)
   ▼
S-57 feature + geometry model            engine/src/s57/       (pkg: s57)
   │  S-101 portrayal (embedded Lua)     engine/src/portray/ + engine/src/s100/ (pkg: s100)
   ▼
portrayal instruction stream
   │  adapt + project + clip + encode    engine/src/{s57_mvt,tile,mvt,pmtiles}/
   ▼
Mapbox Vector Tiles  +  MapLibre style.json  +  colortables / linestyles / sprite / patterns
```

The foundational stages are standalone Zig packages — **`iso8211`**, **`s57`**,
**`s100`** — so they compose independently and stay libc-free.

## Use it from Zig

Add tile57 as a dependency, then `@import("tile57")`:

```zig
const tile57 = @import("tile57");

var src = try tile57.Source.openBytes(cell_bytes, .auto, null); // PMTiles or S-57 cell
defer src.deinit();
if (try src.tile(z, x, y)) |mvt| {        // decompressed MVT bytes
    defer tile57.freeBytes(mvt);
    // … hand to your renderer …
}
```

`Source.openCells` / `openCellsStreaming` open a whole ENC_ROOT; `bakeArchive`
bakes one to PMTiles; `assets` + `sprite` generate the style assets.

## Use it from C

The same engine behind a thin C ABI ([`include/tile57.h`](include/tile57.h)):

```c
tile57_source *s = tile57_source_open(data, len, TILE57_FORMAT_AUTO, NULL);
uint8_t *mvt; size_t n;
if (tile57_tile_get(s, z, x, y, &mvt, &n) == TILE57_TILE_OK) {
    /* … render mvt … */ tile57_tile_free(mvt, n);
}
tile57_source_close(s);
```

`libtile57.a` also exposes the ENC_ROOT bake, the MapLibre style builder, and the
asset/atlas generators. See [the C API docs](docs/docs/c-api.md).

## The `tile57` CLI

The offline tool bakes charts and emits portrayal assets:

```sh
cd engine && zig build                       # builds engine/zig-out/bin/tile57
tile57 bundle CELL.000 -o out/               # tiles + style + assets + manifest
tile57 bake-root ENC_ROOT -o chart.pmtiles   # band-streamed whole-catalogue bake
tile57 assets   PortrayalCatalog -o assets/  # colortables + linestyles + sprite + patterns
tile57 sprite-mln PortrayalCatalog -o assets/# the MapLibre sprite sheet
```

## Build

The Zig engine + CLI need only **Zig 0.16**:

```sh
git submodule update --init --recursive   # vendored S-101 catalogue
cd engine && zig build && zig build test
```

Full instructions: [docs/installation](docs/docs/installation.md).

## Documentation

Docs source lives in [`docs/`](docs/): [intro](docs/docs/intro.md),
[getting started](docs/docs/getting-started.md), the
[C API](docs/docs/c-api.md), the [architecture](docs/docs/architecture.md), and the
[tile schema](docs/docs/tile-schema.md). See also [`CHANGELOG.md`](CHANGELOG.md).

## License

tile57's own code is [MIT](LICENSE) © Jeremy Collins. It embeds the IHO S-101
Portrayal Catalogue (© IHO) and vendors nanosvg (zlib) + stb_image_write (public
domain). NOAA ENC charts are U.S. public domain and **not for navigation**.
