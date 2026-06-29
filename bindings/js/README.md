# @beetlebug/tile57-style-engine

Generate a [MapLibre GL](https://maplibre.org) `style.json` for nautical (S-57 /
ENC) charts from **S-52 "mariner settings"** — colour scheme, depth units, safety
contour, display category, and the rest — **entirely client-side**.

Under the hood it runs the chartplotter **`tile57` chartstyle engine** (pure Zig)
compiled to a ~145 KB WebAssembly module. The same engine ships in the native
`libtile57` C ABI (`tile57_build_style`) and the `tile57` CLI, so the style your
front-end produces is **byte-for-byte identical** to the native build (see
[Parity](#parity)). No server round-trip, no second implementation to keep in
sync.

```
 mariner settings (JS object)
        │  JSON
        ▼
 ┌──────────────────────────────────────────────┐
 │  WebAssembly (style-engine.wasm)              │
 │                                               │
 │  settings.parse ──► chartstyle.buildStyle ──┐ │
 │     ▲                  ▲          ▲          │ │
 │  embedded           embedded   embedded      │ │
 │  template.json      colortables (S-52)       │ │
 └─────────────────────────────────────────────┼─┘
                                                │  UTF-8 style.json bytes
                                                ▼
                                   MapLibre style object  →  map.setStyle(...)
```

`buildStyle` *patches* an embedded base template: it recolours every
palette-driven property for the chosen scheme, rewrites the SEABED01 depth shading
/ SNDFRM04 sounding / danger-symbol / contour-label expressions from the contour
settings, and AND-s the client-side display filters (category, boundary & point
style, date validity, text groups, …) onto every `source:"chart"` layer.

## Install

```sh
npm install @beetlebug/tile57-style-engine
```

The package bundles `style-engine.wasm` and has **zero runtime dependencies**.

## Usage

```js
import { loadStyleEngine } from '@beetlebug/tile57-style-engine';

// Load once, reuse. generateStyle() is synchronous and cheap.
const engine = await loadStyleEngine();

const style = engine.generateStyle({
  scheme: 'night',
  depth_unit: 'feet',
  safety_contour: 15,
  deep_contour: 40,
  boundary_style: 'plain',
});

map.setStyle(style); // a MapLibre GL JS map
```

Only the fields you pass are overridden; everything else uses the engine's
canonical default (see `DEFAULT_SETTINGS`). Re-call `generateStyle` and
`map.setStyle` whenever the mariner changes a setting.

### Browsers / bundlers

`loadStyleEngine()` auto-loads the bundled `.wasm` (via `fs` in Node, `fetch` in
the browser, resolved relative to the module). If your bundler doesn't emit the
`.wasm` as an asset, pass the bytes yourself:

```js
const wasmBytes = await fetch(
  new URL('@beetlebug/tile57-style-engine/style-engine.wasm', import.meta.url),
).then((r) => r.arrayBuffer());
const engine = await loadStyleEngine({ wasmBytes });
```

### Source / sprite / glyph URLs

The embedded template's `sources`, `sprite` and `glyphs` URLs are placeholders.
Point them at your tile source and asset server before loading:

```js
const style = engine.generateStyle(settings);
style.sources.chart = { type: 'vector', tiles: ['https://…/{z}/{x}/{y}.pbf'], minzoom: 5, maxzoom: 16 };
style.sprite = 'https://…/sprite';
style.glyphs = 'https://…/{fontstack}/{range}.pbf';
map.setStyle(style);
```

## API

- **`loadStyleEngine(opts?) → Promise<StyleEngine>`** — instantiate the wasm.
  `opts.wasmBytes` / `opts.wasmModule` override the bundled file.
- **`StyleEngine#generateStyle(settings?, opts?) → object | string`** — build a
  style. `settings` is a `Partial<MarinerSettings>`. `opts.nowUnix` fixes the
  "today" date (epoch seconds) for deterministic output; `opts.asString: true`
  returns the raw JSON string.
- **`StyleEngine#template() → object`** — the embedded base template (debug/diff).
- **`generateStyle(settings?, opts?) → Promise<object|string>`** — one-shot
  convenience (loads the engine each call; prefer the class for repeated use).
- **`DEFAULT_SETTINGS`** — the canonical defaults, for seeding a settings UI.

Full types are in [`index.d.ts`](./index.d.ts). The `MarinerSettings` fields
mirror the Zig `MarinerSettings` struct and the C `tile57_mariner`.

### Mariner settings

| field | type | default | meaning |
|---|---|---|---|
| `scheme` | `'day'\|'dusk'\|'night'` | `'day'` | S-52 colour palette |
| `depth_unit` | `'meters'\|'feet'` | `'meters'` | contour-label units |
| `shallow_contour` | number (m) | `2` | SEABED01 shallow band |
| `safety_contour` | number (m) | `10` | own-ship safety contour |
| `deep_contour` | number (m) | `30` | SEABED01 deep band |
| `safety_depth` | number (m) | `10` | SNDFRM04 bold/faint sounding split |
| `four_shade_water` | boolean | `true` | 4-shade vs 2-shade water |
| `boundary_style` | `'symbolized'\|'plain'` | `'symbolized'` | area boundaries (§8.6.1) |
| `simplified_points` | boolean | `false` | simplified vs paper-chart symbols |
| `display_base/standard/other` | boolean | `true/true/false` | S-52 display category |
| `data_quality` | boolean | `false` | M_QUAL overlay |
| `show_inform_callouts` | boolean | `false` | INFORM01 callouts |
| `show_meta_bounds` | boolean | `false` | meta coverage/scale bounds |
| `show_isolated_dangers_shallow` | boolean | `false` | ISODGR01 in shallow water |
| `show_full_sector_lines` | boolean | `false` | full light-sector legs |
| `text_names` / `show_light_descriptions` / `text_other` | boolean | `true` | text groups (§14.5) |
| `date_dependent` | boolean | `true` | apply date-dependent display |
| `highlight_date_dependent` | boolean | `false` | highlight CHDATD01 features |
| `date_view` | string | `''` | pinned date `"YYYYMMDD"` (`''` = today) |

## Example / smoke test

```sh
node examples/generate.mjs
```

Generates styles for several setting combinations and asserts the output is a
valid MapLibre style with the expected layers and mariner patches.

## Parity

The wasm engine and the native build are the **same Zig source** compiled for two
targets. `bindings/scripts/parity-check.sh` generates a style with both for a
range of settings (and a fixed `nowUnix`) and asserts they are **byte-identical**:

- native: `zig-out/bin/style-parity` (`chartstyle.buildStyle`, host target)
- wasm:   this package (`chartstyle.buildStyle`, `wasm32-freestanding`)

> Note: the `tile57 style` CLI is **not** the right oracle — it generates the base
> *template* (`assets.styleJson`), it does not apply mariner settings. The mariner
> patcher is `chartstyle.buildStyle`, which both this module and the
> `style-parity` oracle call, hence the dedicated parity tool.

## Building from source

The committed `style-engine.wasm` is reproducible from the repo (Zig 0.16):

```sh
bindings/scripts/gen-assets.sh   # regenerate embedded template + colortables (optional)
bindings/scripts/build-wasm.sh   # zig build wasm  →  bindings/js/style-engine.wasm
bindings/scripts/parity-check.sh # verify wasm == native, byte-for-byte
```

## How it works / why WASM

The S-52 portrayal logic is intricate and must **never drift** from the byte-exact
Zig source of truth shared by the tile generator and the native renderer.

- **Pure-TS port** — would duplicate that logic in a second language and inevitably
  drift; every S-52 fix would need porting twice.
- **Native addon (N-API)** — ties the package to a platform/ABI, needs prebuilds,
  and doesn't run in the browser (the whole point: client-side styling).
- **WASM (this approach)** — reuses the *exact* Zig `buildStyle`, runs in both Node
  and the browser, is tiny (~145 KB), needs no native toolchain at install time,
  and is provably identical to the native output.
```
