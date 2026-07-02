# tile57 web demo — MapLibre GL JS + the S-52 style engine

A minimal browser demo that puts the three pieces together:

1. **`tile57 bake`** turns an S-57 ENC cell into a chart **bundle** — a PMTiles
   vector archive plus its sprite/colortables/manifest — in **MLT** (MapLibre
   Tile, the demo default) and **MVT**.
2. **MapLibre GL JS** renders it (reading the archive via the `pmtiles://` protocol;
   MLT sources use the `encoding: "mlt"` property, supported since maplibre-gl-js 5.12).
3. **`@beetlebug/tile57-style-engine`** (the tile57 chartstyle engine compiled to
   WebAssembly) generates the MapLibre **style** from S-52 *mariner settings* —
   entirely in the browser. Toggle a setting and the style is regenerated client-side.

```
ENC cell ──tile57 bake──▶ bundle/tiles/chart.pmtiles (MLT)  (+ sprite, colortables, manifest)
mariner settings ──style-engine (wasm)──▶ style.json ──▶ map.setStyle(...)
                                              ▲ source(+encoding)/sprite/glyphs wired to the served assets
```

## Run

```sh
# 1. build the tile57 CLI (once), from the repo root:
zig build

# 2. bake a cell (Annapolis shown; any .000 or ENC_ROOT works):
./bake.sh /path/to/US4MD81M.000

# 3. serve on 0.0.0.0:3000 and open it in a browser:
./serve.sh           # -> http://0.0.0.0:3000/
```

`serve.sh` vendors the engine module (`index.js` + `style-engine.wasm`) into
`./engine/` so the served root is self-contained; in a real front-end you'd
`npm install @beetlebug/tile57-style-engine` and `import` it instead.

## How the style is wired

`engine.generateStyle(settings)` returns a complete MapLibre style, but the style
engine only *substitutes the mariner-driven bits* — it doesn't know where your
tiles live. So `app.js` repoints three things at what's served here:

- `style.sources.chart` → the baked `pmtiles://…/chart-mlt/tiles/chart.pmtiles`
  (plus `encoding: "mlt"`; for the MVT bake it's `chart/tiles/chart.pmtiles`, no encoding)
- `style.sprite` → the baked `chart-mlt/assets/sprite-mln`
- `style.glyphs` → a public `Noto Sans Regular` glyph server (the font the style uses)

## Notes

- Default tile format is **MLT** (`encoding: "mlt"`, maplibre-gl-js ≥ 5.12); open
  `?fmt=mvt` for the MVT variant. `?pmtiles=<path>` points at any other archive.
- maplibre-gl 5.x + pmtiles 4.x load from a CDN (unpkg); vendor them locally for offline use.
- A single cell bakes only its scale band (e.g. Annapolis ≈ z11–13); zoom in to see data.
