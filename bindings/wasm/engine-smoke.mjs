// Smoke test for the full-engine wasm reactor (zig build wasm-engine).
//
// Runs the real pipeline inside node's WASI host: bake one S-57 cell to a
// PMTiles archive, open the archive from bytes, fetch one vector tile, and
// render one PNG view. This is the same call sequence a browser chartplotter
// makes; only the WASI shim differs.
//
// usage: node engine-smoke.mjs <ENC_ROOT> <cell-rel-path> [out.png]
//   e.g. node engine-smoke.mjs ~/Charts/enc-src/ALL/ENC_ROOT US5BDRAB/US5BDRAB.000

import { WASI } from "node:wasi";
import fs from "node:fs";

const [encRoot, cellRel, pngOut] = process.argv.slice(2);
if (!encRoot || !cellRel) {
  console.error("usage: node engine-smoke.mjs <ENC_ROOT> <cell-rel-path> [out.png]");
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
function allocBytes(bytes) {
  const p = E.tile57_wasm_alloc(bytes.length);
  if (!p) throw new Error("tile57_wasm_alloc failed");
  u8().set(bytes, p);
  return p;
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
  if (status !== 0) {
    throw new Error(`${name}: status ${status}: ${cstr(errPtr + 4)}`);
  }
}
const readOut = () => [dv().getUint32(outPtr, true), dv().getUint32(outLen, true)];

console.log("version:", cstr(E.tile57_version()));
E.tile57_warmup();

// ---- bake: S-57 cell -> per-chart PMTiles archive ------------------------
const cellPath = allocCString("/enc/" + cellRel);
let t0 = performance.now();
check("bake_chart_bytes", E.tile57_bake_chart_bytes(cellPath, outPtr, outLen, errPtr));
const [arcPtr, arcLen] = readOut();
console.log(`baked: ${arcLen} bytes in ${(performance.now() - t0).toFixed(0)} ms`);
if (arcLen === 0) throw new Error("bake produced no archive");

// ---- open the archive from bytes (no file system involved) ---------------
check("chart_open_bytes", E.tile57_chart_open_bytes(arcPtr, arcLen, outPtr, errPtr));
const chart = dv().getUint32(outPtr, true);
E.tile57_free(arcPtr);

// ---- info -> pick the anchor view ----------------------------------------
const info = E.tile57_wasm_alloc(96);
E.tile57_chart_get_info(chart, info);
const d = dv();
const minz = d.getUint8(info), maxz = d.getUint8(info + 1);
const hasAnchor = d.getUint8(info + 48) !== 0;
// No anchor in the archive -> view the bounds center at a harbor-ish zoom.
const anchorLat = hasAnchor ? d.getFloat64(info + 56, true) : (d.getFloat64(info + 24, true) + d.getFloat64(info + 40, true)) / 2;
const anchorLon = hasAnchor ? d.getFloat64(info + 64, true) : (d.getFloat64(info + 16, true) + d.getFloat64(info + 32, true)) / 2;
const anchorZoom = hasAnchor ? d.getFloat64(info + 72, true) : Math.min(14, maxz);
console.log(`info: z${minz}-${maxz} scale 1:${d.getInt32(info + 84, true)} view ${anchorLat.toFixed(4)},${anchorLon.toFixed(4)} @z${anchorZoom.toFixed(1)}`);

// ---- one vector tile at the anchor ---------------------------------------
const z = Math.max(minz, Math.min(maxz, Math.round(anchorZoom)));
const n = 2 ** z;
const tx = Math.floor(((anchorLon + 180) / 360) * n);
const latR = (anchorLat * Math.PI) / 180;
const ty = Math.floor(((1 - Math.log(Math.tan(latR) + 1 / Math.cos(latR)) / Math.PI) / 2) * n);
t0 = performance.now();
check("chart_tile", E.tile57_chart_tile(chart, z, tx, ty, outPtr, outLen, errPtr));
const [tilePtr, tileLen] = readOut();
console.log(`tile ${z}/${tx}/${ty}: ${tileLen} bytes in ${(performance.now() - t0).toFixed(0)} ms`);
if (tilePtr) E.tile57_free(tilePtr);

// ---- one PNG view at the anchor ------------------------------------------
t0 = performance.now();
check("chart_png", E.tile57_chart_png(chart, anchorLon, anchorLat, anchorZoom, 800, 600, 0, outPtr, outLen, errPtr));
const [pngPtr, pngLen] = readOut();
console.log(`png: ${pngLen} bytes in ${(performance.now() - t0).toFixed(0)} ms`);
if (pngLen === 0) throw new Error("png render produced no bytes");
if (pngOut) {
  fs.writeFileSync(pngOut, u8().slice(pngPtr, pngPtr + pngLen));
  console.log("wrote", pngOut);
}
E.tile57_free(pngPtr);

E.tile57_chart_close(chart);
console.log("OK");
