---
id: wasm
title: WebAssembly
sidebar_position: 10
---

# WebAssembly

Try it first: the [live demo](/demo) is the browser demo below, embedded in
these docs. Drop a NOAA ENC zip on it and the page bakes and renders the
charts itself.

The full engine compiles to one wasm module:

```sh
zig build wasm-engine
# -> zig-out/bin/tile57-engine.wasm
```

The module carries the complete [C API](c-api.md) — bake, chart, compose,
style, raster — plus the embedded Lua portrayal engine, the S-101 catalogue,
and the label fonts. A JS host can bake charts and serve tiles fully
client-side: a chartplotter with no server.

## The host contract

- **Target**: `wasm32-wasi`. The module imports only `wasi_snapshot_preview1`
  functions. In node, the built-in `node:wasi` host provides them. In a
  browser, `bindings/js/wasi-shim.mjs` provides them: a dependency-free shim
  with an in-memory file tree for the source cells.
- **Reactor model**: the module has no `_start`. Call the exported
  `_initialize` once after instantiation, then call the `tile57_*` exports.
- **Exception handling**: Lua and libtess2 keep their setjmp/longjmp error
  paths through the wasm exception-handling instructions. The engine that runs
  the module must implement the exception-handling proposal. All current
  browsers and node do.
- **Input buffers**: two wasm-only exports move bytes across the boundary.
  `tile57_wasm_alloc(len)` returns an offset in linear memory; the host writes
  input bytes there and passes the offset to a `tile57_*` call.
  `tile57_wasm_free(ptr)` releases it. Engine *outputs* still go through
  `tile57_free`, like every other host.

## Differences from a native host

- The engine is single-threaded. Calls that accept a `workers` count run
  serial.
- Open-by-path copies the file into linear memory. There is no mmap, so a
  browser host with large chart libraries opens archives with
  `tile57_chart_open_bytes` and keeps residency under its own control.
- SQLite (raster charts) is built single-thread (`SQLITE_THREADSAFE=0`).

## The JS package

`bindings/js` is the JavaScript face of the engine: an npm-style package
named `tile57` whose main export is the full engine. `tile57.mjs` wraps the
exports one-to-one (linear-memory allocation, C strings, out-parameters, the
`tile57_error` decode); `createEngine` in `index.mjs` stands one up in a
browser or node; the worker, bake-pool, GPU-renderer, and chart-library
modules are the pieces the demo composes. The style-only engine ships as the
`tile57/style` subpath.

## Smoke test

`bindings/js/engine-smoke.mjs` drives the real pipeline under node's WASI
host — bake S-57 cells, open the archives from bytes, compose them, fetch a
vector tile, render a PNG view:

```sh
zig build wasm-engine
node bindings/js/engine-smoke.mjs <ENC_ROOT> \
    US5BDRAB/US5BDRAB.000 US5BDRBB/US5BDRBB.000 --png out.png
```

## WebGPU

`bindings/js/gpu-renderer.mjs` renders the engine's draw-ready GPU scenes
(`tile57_*_gpu_scene`) with WebGPU. Its WGSL is a port of the reference
shaders in `shaders/` over the same vertex, quad, and uniform layouts; hold
every change against them. The engine batches the ranges
(`tile57_gpu_batch`), the renderer uploads the buffers once per scene, and a
pan or zoom redraws from uniforms alone — the view stays live between scene
rebuilds.

## Browser demo

`bindings/js/demo.html` is a complete in-page chartplotter, embedded in
these docs as the [live demo](/demo) (the docs workflow builds the engine
and stages the app; `src/pages/demo.jsx` frames it). Drop S-57 charts on it —
`.000` cells with their update files, or an exchange-set `.zip` straight
from [NOAA's ENC downloads](https://charts.noaa.gov/ENCs/ENCs.shtml). The
charts never leave the page: baking and rendering happen in the browser.

Drag to pan (a fast release flicks), wheel to zoom, double-click to zoom
in; Shift-drag or a two-finger twist rotates the view and the compass
control resets north-up; arrow keys pan and `+`/`-` zoom. Scenes build
larger than the viewport (`?margin=K`), so a pan, zoom, or turn shows chart
from the standing scene while a sharper one streams in. It renders with
WebGPU where the browser has it, and falls back to PNG views (`?png=1`
forces the fallback; the HUD names the reason when the fallback engages).
WebGPU needs a secure context — `https://`, or `localhost` for a local
server.

The demo runs the engine in a Web Worker (`engine-worker.mjs`): a bake holds
the CPU for seconds, and off the main thread the map and the loader stay
live. The page drives one engine call per RPC message — a dropped zip is
listed, then extracted and baked cell by cell, so the loader shows real
per-cell progress.

Batches bake in parallel: one wasm instance is single-threaded, so the page
spins up a small pool of extra engine workers (`bake-pool.mjs`, sized from
the machine's cores; `?workers=N` overrides) and fans the cells across them.
The primary engine worker keeps the charts, the compositor, and rendering;
pool slots only turn cell bytes into archive bytes, and close when the batch
ends.

Baked archives persist: each cell lands in the browser's origin-private file
system as it finishes (`chart-library.mjs`, with a metadata sidecar), so a
page load catalogs the library instead of re-baking, and the 🗑 control
clears it. The engine keeps only the charts the current view needs resident:
each rebuild picks the charts whose bounds intersect the view at a suitable
compilation scale, opens them from the library, composes that subset, and
evicts least-recently-used charts beyond a small cap — a whole district on
disk stays a handful of charts in memory.

Serve a directory that holds the page, the `.mjs` modules, and the engine:

```sh
zig build wasm-engine
mkdir demo && cd demo
ln -s ../bindings/js/{demo.html,tile57.mjs,wasi-shim.mjs,gpu-renderer.mjs,engine-worker.mjs} .
ln -s ../zig-out/bin/tile57-engine.wasm .
python3 -m http.server 8080
# open http://localhost:8080/demo.html and drop charts on it
```

`?cells=US5BDRAB/US5BDRAB.000` preloads cells from an `enc/` tree beside the
page.

## The style-only module

`zig build wasm` still builds the separate, much smaller style engine
(`style-engine.wasm`): only `tile57_style_build` for turning S-52 mariner
settings into a MapLibre style.json, with no WASI dependency. A front-end that
renders baked tiles itself needs only that module.
