# tile57 web demo — MapLibre GL JS + the S-52 style engine

A minimal browser demo that puts the three pieces together:

1. **`tile57 bake`** turns an S-57 ENC cell into a **PMTiles** vector archive (MVT).
2. **MapLibre GL JS** renders it (reading the archive via the `pmtiles://` protocol).
3. **`@beetlebug/tile57-style-engine`** (the tile57 chartstyle engine compiled to
   WebAssembly) generates the MapLibre **style** from S-52 *mariner settings* —
   entirely in the browser. Toggle a setting and the style is regenerated client-side.

```
ENC cell ──tile57 bake──▶ chart/tiles/chart.pmtiles (+ sprite, colortables)
mariner settings ──style-engine (wasm)──▶ style.json ──▶ map.setStyle(...)
                                              ▲ source/sprite/glyphs wired to the served assets
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

- `style.sources.chart` → the baked `pmtiles://…/chart/tiles/chart.pmtiles`
- `style.sprite` → the baked `chart/assets/sprite-mln`
- `style.glyphs` → a public `Noto Sans Regular` glyph server (the font the style uses)

## Notes

- MapLibre GL JS reads **MVT**, so `bake.sh` uses `--format mvt` (MLT is for other clients).
- maplibre-gl + pmtiles load from a CDN (unpkg); vendor them locally for offline use.
- A single cell bakes only its scale band (e.g. Annapolis ≈ z11–13); zoom in to see data.
