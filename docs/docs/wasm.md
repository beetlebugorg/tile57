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
  browser, a small WASI shim provides them (for example
  `@bjorn3/browser_wasi_shim`, with an in-memory file system).
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

## Smoke test

`bindings/wasm/engine-smoke.mjs` drives the real pipeline under node's WASI
host — bake S-57 cells, open the archives from bytes, compose them, fetch a
vector tile, render a PNG view:

```sh
zig build wasm-engine
node bindings/wasm/engine-smoke.mjs <ENC_ROOT> \
    US5BDRAB/US5BDRAB.000 US5BDRBB/US5BDRBB.000 --png out.png
```

## The style-only module

`zig build wasm` still builds the separate, much smaller style engine
(`style-engine.wasm`): only `tile57_style_build` for turning S-52 mariner
settings into a MapLibre style.json, with no WASI dependency. A front-end that
renders baked tiles itself needs only that module.
