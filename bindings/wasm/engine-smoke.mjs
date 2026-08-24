// Smoke test for the full-engine wasm reactor (zig build wasm-engine).
//
// Runs the real chartplotter pipeline inside node's WASI host: bake S-57
// cells to per-chart PMTiles archives, open each archive from bytes, and —
// with two or more cells — compose them and serve tiles from the composite.
// This is the same call sequence a browser chartplotter makes; only the WASI
// shim differs.
//
// usage: node engine-smoke.mjs <ENC_ROOT> <cell-rel-path>... [--png out.png]
//   e.g. node engine-smoke.mjs ~/Charts/enc-src/ALL/ENC_ROOT \
//          US5BDRAB/US5BDRAB.000 US5BDRBB/US5BDRBB.000 --png smoke.png

import { WASI } from "node:wasi";
import fs from "node:fs";

const args = process.argv.slice(2);
let pngOut = null;
const pngFlag = args.indexOf("--png");
if (pngFlag !== -1) {
  pngOut = args[pngFlag + 1];
  args.splice(pngFlag, 2);
}
const [encRoot, ...cells] = args;
if (!encRoot || cells.length === 0) {
  console.error("usage: node engine-smoke.mjs <ENC_ROOT> <cell-rel-path>... [--png out.png]");
  process.exit(2);
}

const wasmPath = new URL("../../zig-out/bin/tile57-engine.wasm", import.meta.url);
const wasi = new WASI({ version: "preview1", preopens: { "/enc": encRoot } });
const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
wasi.initialize(inst); // reactor: run the wasi/libc constructors once
const E = inst.exports;

// memory.buffer detaches on growth — always re-view.
const u8 = () => new Uint8Array(E.memory.buffer);
const dv = () => new DataView(E.memory.buffer);

function cstr(ptr) {
  const m = u8();
  let end = ptr;
  while (m[end] !== 0) end++;
  return new TextDecoder().decode(m.subarray(ptr, end));
}
function allocCString(s) {
  const b = new TextEncoder().encode(s);
  const p = E.tile57_wasm_alloc(b.length + 1);
  u8().set(b, p);
  u8()[p + b.length] = 0;
  return p;
}

// One scratch block for out-params + the tile57_error (status i32 + 256 msg).
const scratch = E.tile57_wasm_alloc(16 + 260);
const outPtr = scratch, outLen = scratch + 4, errPtr = scratch + 16;
function check(name, status) {
  if (status !== 0) throw new Error(`${name}: status ${status}: ${cstr(errPtr + 4)}`);
}
const readOut = () => [dv().getUint32(outPtr, true), dv().getUint32(outLen, true)];

console.log("version:", cstr(E.tile57_version()));
E.tile57_warmup();

// ---- bake each cell, open each archive from bytes ------------------------
const charts = [];
for (const cell of cells) {
  const t0 = performance.now();
  check("bake_chart_bytes", E.tile57_bake_chart_bytes(allocCString("/enc/" + cell), outPtr, outLen, errPtr));
  const [arcPtr, arcLen] = readOut();
  if (arcLen === 0) throw new Error(`${cell}: bake produced no archive`);
  check("chart_open_bytes", E.tile57_chart_open_bytes(arcPtr, arcLen, outPtr, errPtr));
  charts.push(dv().getUint32(outPtr, true));
  E.tile57_free(arcPtr);
  console.log(`${cell}: baked ${arcLen} bytes in ${(performance.now() - t0).toFixed(0)} ms`);
}

// ---- union bounds -> the view ---------------------------------------------
const info = E.tile57_wasm_alloc(96);
let west = 180, south = 90, east = -180, north = -90, maxz = 0;
for (const chart of charts) {
  E.tile57_chart_get_info(chart, info);
  const d = dv();
  if (d.getUint8(info + 8)) {
    west = Math.min(west, d.getFloat64(info + 16, true));
    south = Math.min(south, d.getFloat64(info + 24, true));
    east = Math.max(east, d.getFloat64(info + 32, true));
    north = Math.max(north, d.getFloat64(info + 40, true));
  }
  maxz = Math.max(maxz, d.getUint8(info + 1));
}
const lat = (south + north) / 2, lon = (west + east) / 2;
const zoom = Math.min(14, maxz);
console.log(`view ${lat.toFixed(4)},${lon.toFixed(4)} @z${zoom}`);

// ---- serve: one chart directly, or the composite over all of them --------
const composed = charts.length > 1;
let compose = 0;
if (composed) {
  const list = E.tile57_wasm_alloc(4 * charts.length);
  charts.forEach((c, i) => dv().setUint32(list + 4 * i, c, true));
  const t0 = performance.now();
  check("compose_open", E.tile57_compose_open(list, charts.length, outPtr, errPtr));
  compose = dv().getUint32(outPtr, true);
  console.log(`composed ${charts.length} charts in ${(performance.now() - t0).toFixed(0)} ms`);
}

const z = zoom;
const n = 2 ** z;
const tx = Math.floor(((lon + 180) / 360) * n);
const latR = (lat * Math.PI) / 180;
const ty = Math.floor(((1 - Math.log(Math.tan(latR) + 1 / Math.cos(latR)) / Math.PI) / 2) * n);
let t0 = performance.now();
if (composed) {
  const ownedPtr = E.tile57_wasm_alloc(1);
  check("compose_tile", E.tile57_compose_tile(compose, z, tx, ty, outPtr, outLen, ownedPtr, errPtr));
} else {
  check("chart_tile", E.tile57_chart_tile(charts[0], z, tx, ty, outPtr, outLen, errPtr));
}
const [tilePtr, tileLen] = readOut();
console.log(`tile ${z}/${tx}/${ty}: ${tileLen} bytes in ${(performance.now() - t0).toFixed(0)} ms`);
if (tilePtr) E.tile57_free(tilePtr);

t0 = performance.now();
if (composed) {
  check("compose_png", E.tile57_compose_png(compose, lon, lat, zoom, 800, 600, 0, outPtr, outLen, errPtr));
} else {
  check("chart_png", E.tile57_chart_png(charts[0], lon, lat, zoom, 800, 600, 0, outPtr, outLen, errPtr));
}
const [pngPtr, pngLen] = readOut();
console.log(`png: ${pngLen} bytes in ${(performance.now() - t0).toFixed(0)} ms`);
if (pngLen === 0) throw new Error("png render produced no bytes");
if (pngOut) {
  fs.writeFileSync(pngOut, u8().slice(pngPtr, pngPtr + pngLen));
  console.log("wrote", pngOut);
}
E.tile57_free(pngPtr);

if (composed) E.tile57_compose_close(compose); // before the charts it borrows
for (const chart of charts) E.tile57_chart_close(chart);
console.log("OK");
