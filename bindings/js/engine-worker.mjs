// The engine, off the main thread. Every tile57 call is synchronous wasm and
// a bake can hold the CPU for seconds - run here, the page stays live and a
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

  // Everything the WebGPU renderer needs, baked once per scheme: the ABI
  // layout, the four atlas PNGs at the page's pixel ratio, and the
  // colortables the halo and clear colours come from. Symbols carry their
  // OWN colours, so a scheme change re-bakes the sprite atlas; the SDF glyph
  // atlases are colourless and scheme-independent.
  gpuAssets({ pixelRatio, scheme = 0 }) {
    const r = {
      layout: t.abiGpuLayout(),
      spritePng: t.bakeSpriteMln(pixelRatio, scheme).png,
      glyphPng: t.bakeGlyphSdf(0).png,
      glyphBoldPng: t.bakeGlyphSdf(1).png,
      glyphItalicPng: t.bakeGlyphSdf(2).png,
      colortables: t.colortablesDefault(),
    };
    return [r, [r.spritePng.buffer, r.glyphPng.buffer, r.glyphBoldPng.buffer, r.glyphItalicPng.buffer]];
  },

  // The sprite atlas alone, for a scheme change on a standing renderer.
  spriteAtlas({ pixelRatio, scheme = 0 }) {
    const png = t.bakeSpriteMln(pixelRatio, scheme).png;
    return [png, [png.buffer]];
  },

  // The engine's canonical default mariner settings.
  marinerDefaults() { return t.marinerDefaults(); },

  // The cursor pick + the decoded report for each feature, in one round trip.
  pick({ compose, chart, lon, lat, zoom }) {
    return t.pick({ compose, chart, lon, lat, zoom }).map((f) => ({
      ...f,
      report: (() => {
        try { return t.s57Report(f.cls, f.chart, f.s57); } catch { return null; }
      })(),
    }));
  },

  // The S-52 colour tables ({day, dusk, night} token maps) - the page themes
  // its own chrome from them, so the UI colours are the spec's, not ours.
  palette() { return JSON.parse(t.colortablesDefault()); },

  addFile({ path, bytes }) { fsys.add(path, bytes); },

  // Drop a file or subtree from the tree - a zip or a cell's extracted files
  // free as soon as their bake is done, so a big batch stays flat in memory.
  remove({ path }) {
    fsys.remove(path.startsWith(fsys.root + "/") ? path.slice(fsys.root.length + 1) : path);
  },

  // Read one file back out of the tree (transferred) - how the page shuttles
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

  // Bake one cell and describe it: the info (bounds, scale, zooms) rides
  // along so the page can catalog the chart without opening the archive.
  bakeCell({ path }) {
    const arc = t.bakeChartBytes(path);
    if (!arc) return null;
    const handle = t.chartOpenBytes(arc);
    const info = t.chartGetInfo(handle);
    t.chartClose(handle);
    return [{ archive: arc, info }, [arc.buffer]];
  },

  openChartBytes({ bytes }) {
    const handle = t.chartOpenBytes(bytes);
    return { handle, info: t.chartGetInfo(handle) };
  },
  closeChart({ handle }) { t.chartClose(handle); },
  composeOpen({ handles }) { return t.composeOpen(handles); },
  composeClose({ handle }) { t.composeClose(handle); },

  png({ compose, chart, lon, lat, zoom, w, h, mariner }) {
    const png = compose
      ? t.composePng(compose, lon, lat, zoom, w, h, mariner)
      : t.chartPng(chart, lon, lat, zoom, w, h, mariner);
    return [png, [png.buffer]];
  },

  // Build a scene, batch it, and hand the page plain draw-ready data: the
  // three buffers and the pattern cells COPIED out of wasm memory (and
  // transferred), the draw list as objects.
  gpuScene({ compose, chart, lon, lat, zoom, w, h, pixelRatio, atlasHave, halo, mariner }) {
    const scene = compose
      ? t.composeGpuScene(compose, lon, lat, zoom, w, h, pixelRatio, mariner)
      : t.chartGpuScene(chart, lon, lat, zoom, w, h, pixelRatio, mariner);
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
