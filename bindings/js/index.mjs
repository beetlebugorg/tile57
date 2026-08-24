// tile57 for JavaScript: the full chart engine, compiled to WebAssembly.
//
// The engine bakes S-57/S-101 charts to PMTiles archives, composes them, and
// renders tiles, PNG views, and draw-ready WebGPU scenes - in the browser or
// in node. `createEngine` stands one up in the current context; the other
// exports are the pieces a real app composes:
//
//   - Tile57            the C-API wrapper (bake, chart, compose, gpu, style)
//   - MemFS, WasiShim   the WASI host with an in-memory file tree
//   - GpuRenderer       WebGPU over the engine's draw-ready scenes
//   - makeRpc, BakePool run the engine in Web Workers, bake cells in parallel
//   - ChartLibrary      persist baked archives in the browser (OPFS)
//
// bindings/js/demo.html is the reference host: a chartplotter in one page.
// The style-only engine (a much smaller wasm) lives under "tile57/style".

export { Tile57 } from "./tile57.mjs";
export { MemFS, WasiShim } from "./wasi-shim.mjs";
export { GpuRenderer, ATLAS, lonLatToWorld, worldToLonLat, scaleDenom } from "./gpu-renderer.mjs";
export { makeRpc } from "./worker-rpc.mjs";
export { BakePool } from "./bake-pool.mjs";
export { ChartLibrary } from "./chart-library.mjs";

import { Tile57 } from "./tile57.mjs";
import { MemFS, WasiShim } from "./wasi-shim.mjs";

/** Instantiate the engine on the current thread. `wasm` is the module bytes,
 * a compiled WebAssembly.Module, or a URL/path string; the returned `fs` is
 * the engine's file tree (add source cells there, under `root`). For long
 * bakes, prefer engine-worker.mjs so the engine runs off the main thread. */
export async function createEngine(wasm, { root = "/enc" } = {}) {
  let module = wasm;
  if (typeof wasm === "string" || wasm instanceof URL) {
    module = typeof process !== "undefined" && process.versions?.node
      ? await WebAssembly.compile(await (await import("node:fs/promises")).readFile(wasm))
      : await WebAssembly.compileStreaming(fetch(wasm));
  } else if (!(wasm instanceof WebAssembly.Module)) {
    module = await WebAssembly.compile(wasm);
  }
  const fs = new MemFS(root);
  const wasi = new WasiShim(fs);
  const instance = await WebAssembly.instantiate(module, wasi.imports());
  wasi.start(instance);
  return { engine: new Tile57(instance.exports), fs };
}
