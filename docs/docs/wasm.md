---
id: wasm
title: WebAssembly
sidebar_position: 10
---

# WebAssembly

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
  browser, `bindings/wasm/wasi-shim.mjs` provides them: a dependency-free shim
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

## The JS wrapper

`bindings/wasm/tile57.mjs` wraps the exports one-to-one for a JS host: it
handles linear-memory allocation, C strings, out-parameters, and the
`tile57_error` decode, and returns engine outputs as `Uint8Array` copies.
Browser and node both run it.

## Smoke test

`bindings/wasm/engine-smoke.mjs` drives the real pipeline under node's WASI
host — bake S-57 cells, open the archives from bytes, compose them, fetch a
vector tile, render a PNG view:

```sh
zig build wasm-engine
node bindings/wasm/engine-smoke.mjs <ENC_ROOT> \
    US5BDRAB/US5BDRAB.000 US5BDRBB/US5BDRBB.000 --png out.png
```

## WebGPU

`bindings/wasm/gpu-renderer.mjs` renders the engine's draw-ready GPU scenes
(`tile57_*_gpu_scene`) with WebGPU. Its WGSL is a port of the reference
shaders in `shaders/` over the same vertex, quad, and uniform layouts; hold
every change against them. The engine batches the ranges
(`tile57_gpu_batch`), the renderer uploads the buffers once per scene, and a
pan or zoom redraws from uniforms alone — the view stays live between scene
rebuilds.

## Browser demo

`bindings/wasm/demo.html` is a complete in-page chartplotter. Drop S-57
charts on it — `.000` cells with their update files, or an exchange-set
`.zip` (the engine bakes the whole set through the shim's writable file
tree). Drag to pan, wheel to zoom, double-click to zoom in. It renders with
WebGPU where the browser has it, and falls back to PNG views (`?png=1`
forces the fallback). Serve a directory that holds the page, the `.mjs`
modules, and the engine:

```sh
zig build wasm-engine
mkdir demo && cd demo
ln -s ../bindings/wasm/{demo.html,tile57.mjs,wasi-shim.mjs,gpu-renderer.mjs} .
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
