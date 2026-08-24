// The engine, off the main thread. Every tile57 call is synchronous wasm and
// a bake can hold the CPU for seconds — run here, the page stays live and a
// loader can actually animate. The page talks RPC: {id, op, args} in,
// {id, ok, result} | {id, ok: false, error} out, with large byte buffers
// transferred rather than copied.
//
// One op is one engine call. The page orchestrates multi-cell work (bake this
// cell, then that one) so progress falls out of the message flow itself.

import { MemFS, WasiShim } from "./wasi-shim.mjs";
import { Tile57 } from "./tile57.mjs";

let t = null;
const fsys = new MemFS("/enc");

const ops = {
  async init({ wasmUrl }) {
    const mod = await WebAssembly.compileStreaming(fetch(wasmUrl));
    const wasi = new WasiShim(fsys);
    const inst = await WebAssembly.instantiate(mod, wasi.imports());
    wasi.start(inst);
    t = new Tile57(inst.exports);
    t.warmup();
    return { version: t.version() };
  },

  // Everything the WebGPU renderer needs, baked once: the ABI layout, the
  // four atlas PNGs at the page's pixel ratio, and the colortables the halo
  // and clear colours come from.
  gpuAssets({ pixelRatio }) {
    const r = {
      layout: t.abiGpuLayout(),
      spritePng: t.bakeSpriteMln(pixelRatio, 0).png,
      glyphPng: t.bakeGlyphSdf(0).png,
      glyphBoldPng: t.bakeGlyphSdf(1).png,
      glyphItalicPng: t.bakeGlyphSdf(2).png,
      colortables: t.colortablesDefault(),
    };
    return [r, [r.spritePng.buffer, r.glyphPng.buffer, r.glyphBoldPng.buffer, r.glyphItalicPng.buffer]];
  },

  // The S-52 colour tables ({day, dusk, night} token maps) — the page themes
  // its own chrome from them, so the UI colours are the spec's, not ours.
  palette() { return JSON.parse(t.colortablesDefault()); },

  addFile({ path, bytes }) { fsys.add(path, bytes); },

  // Drop a file or subtree from the tree — a zip or a cell's extracted files
  // free as soon as their bake is done, so a big batch stays flat in memory.
  remove({ path }) {
    fsys.remove(path.startsWith(fsys.root + "/") ? path.slice(fsys.root.length + 1) : path);
  },

  // Read one file back out of the tree (transferred) — how the page shuttles
  // zip-extracted cell files from this worker to a bake-pool worker.
  readFile({ path }) {
    const rel = path.startsWith(fsys.root + "/") ? path.slice(fsys.root.length + 1) : path;
    const data = fsys.read(rel);
    if (!data) throw new Error(`${path}: not found`);
    const bytes = data.slice();
    return [bytes, [bytes.buffer]];
  },

  zipList({ path }) { return t.zipList(path); },
  zipExtract({ path, names, outPaths }) {
    // zip_extract writes to the CALLER's paths and creates no directories.
    for (const p of outPaths) {
      const rel = p.startsWith(fsys.root + "/") ? p.slice(fsys.root.length + 1) : p;
      fsys.mkdirs(rel.replace(/\/[^/]*$/, ""));
    }
    return t.zipExtract(path, names, outPaths);
  },

  bakeCell({ path }) {
    const arc = t.bakeChartBytes(path);
    return arc ? [arc, [arc.buffer]] : null;
  },

  openChartBytes({ bytes }) {
    const handle = t.chartOpenBytes(bytes);
    return { handle, info: t.chartGetInfo(handle) };
  },
  closeChart({ handle }) { t.chartClose(handle); },
  composeOpen({ handles }) { return t.composeOpen(handles); },
  composeClose({ handle }) { t.composeClose(handle); },

  png({ compose, chart, lon, lat, zoom, w, h }) {
    const png = compose
      ? t.composePng(compose, lon, lat, zoom, w, h)
      : t.chartPng(chart, lon, lat, zoom, w, h);
    return [png, [png.buffer]];
  },

  // Build a scene, batch it, and hand the page plain draw-ready data: the
  // three buffers and the pattern cells COPIED out of wasm memory (and
  // transferred), the draw list as objects.
  gpuScene({ compose, chart, lon, lat, zoom, w, h, pixelRatio, atlasHave, halo }) {
    const scene = compose
      ? t.composeGpuScene(compose, lon, lat, zoom, w, h, pixelRatio)
      : t.chartGpuScene(chart, lon, lat, zoom, w, h, pixelRatio);
    const r = {
      vertex: scene.vertexBytes().slice(),
      index: scene.indexBytes().slice(),
      quad: scene.quadBytes().slice(),
      patterns: scene.patternList().map(({ w, h, rgba }) => ({ w, h, rgba: rgba.slice() })),
      draws: t.gpuBatch(scene, { atlasHave, halo }),
    };
    scene.free();
    const transfer = [r.vertex.buffer, r.index.buffer, r.quad.buffer, ...r.patterns.map((p) => p.rgba.buffer)];
    return [r, transfer];
  },
};

onmessage = async (e) => {
  const { id, op, args } = e.data;
  try {
    let result = await ops[op](args ?? {});
    let transfer = [];
    if (Array.isArray(result) && result.length === 2 && Array.isArray(result[1])) {
      [result, transfer] = result;
    }
    postMessage({ id, ok: true, result }, transfer);
  } catch (err) {
    postMessage({ id, ok: false, error: String(err?.message ?? err) });
  }
};
