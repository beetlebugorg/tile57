# tile57 for JavaScript

The full [tile57](https://github.com/beetlebugorg/tile57) chart engine,
compiled to WebAssembly, with JavaScript bindings for the browser and node.
It bakes official S-57/S-101 charts to PMTiles archives, composes them, and
renders vector tiles, PNG views, and draw-ready WebGPU scenes, all with no
server.

**See it run:** the [live demo](https://beetlebugorg.github.io/tile57/demo)
is a chart viewer in one page, built entirely from this package's modules.
[`demo.html`](./demo.html) is its source and the reference host.

> **Not for navigation.** This is not a certified navigation product.

## Quick start

```js
import { createEngine } from "tile57";

const { engine, fs } = await createEngine("./tile57-engine.wasm");
fs.add("US5BDRAB/US5BDRAB.000", cellBytes);            // an S-57 cell

const archive = engine.bakeChartBytes("/enc/US5BDRAB/US5BDRAB.000");
const chart = engine.chartOpenBytes(archive);           // open from bytes
const png = engine.chartPng(chart, -73.18, 41.16, 14, 1600, 1200);
```

`Tile57` wraps the whole C API (bake, chart, compose, GPU scenes, style),
one call per method. See the
[WebAssembly docs](https://beetlebugorg.github.io/tile57/wasm) for the host
contract and the full surface.

## The pieces

| Module | What it is |
|---|---|
| `tile57.mjs` | The engine wrapper over the wasm exports |
| `wasi-shim.mjs` | A dependency-free WASI host with a writable in-memory file tree |
| `gpu-renderer.mjs` | WebGPU over the engine's draw-ready scenes; live pan/zoom/rotate |
| `engine-worker.mjs` | The engine in a Web Worker, one call per RPC message |
| `bake-pool.mjs` | Parallel cell bakes across a pool of engine workers |
| `chart-library.mjs` | Baked archives persisted in the browser (OPFS) |

## Building the wasm

The engine wasm is a build artifact, not committed:

```sh
npm run build       # zig build wasm-engine + copy (needs Zig 0.16)
npm run smoke       # bake + compose + render under node's WASI host
```

## The style-only engine

`tile57/style` is a much smaller module for front-ends that render baked
tiles themselves: it turns S-52 mariner settings into a complete MapLibre
style.json, client-side.

```js
import { loadStyleEngine } from "tile57/style";

const styleEngine = await loadStyleEngine();
const style = styleEngine.buildStyle({ colorScheme: "dusk", safetyContour: 5 });
```

Types are in [`style.d.ts`](./style.d.ts); `examples/` shows it standalone
and inside a MapLibre page.

## License

MIT, per the [repository license](../../LICENSE). The engine embeds the IHO
S-101 Portrayal Catalogue (© IHO). NOAA ENC charts are U.S. public domain and
**not for navigation**.
