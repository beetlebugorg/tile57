// A thin JS wrapper over the tile57-engine.wasm exports. It mirrors the C API
// one-to-one (see include/tile57.h for semantics) and only handles the
// boundary work: linear-memory allocation, C strings, out-parameters, and the
// tile57_error decode. Browser and node both run it; pair it with any WASI
// preview1 host (node:wasi, or wasi-shim.mjs in a browser).
//
// usage:
//   const engine = new Tile57(instance.exports);  // after _initialize ran
//   engine.warmup();
//   const archive = engine.bakeChartBytes("/enc/US5BDRAB/US5BDRAB.000");
//   const chart = engine.chartOpenBytes(archive);
//   const png = engine.chartPng(chart, lon, lat, zoom, 800, 600);

export class Tile57 {
  constructor(exports) {
    this.e = exports;
    // One scratch block: two 4-byte out-slots, one flag byte, the error
    // struct (status i32 + 256-byte message).
    this.scratch = exports.tile57_wasm_alloc(16 + 260);
    this.outPtr = this.scratch;
    this.outLen = this.scratch + 4;
    this.outFlag = this.scratch + 8;
    this.errPtr = this.scratch + 16;
  }

  // memory.buffer detaches on growth — always re-view.
  bytes() { return new Uint8Array(this.e.memory.buffer); }
  view() { return new DataView(this.e.memory.buffer); }

  cstr(ptr) {
    const m = this.bytes();
    let end = ptr;
    while (m[end] !== 0) end++;
    return new TextDecoder().decode(m.subarray(ptr, end));
  }
  /** Copy `bytes` into linear memory. Release with `wasmFree`. */
  alloc(bytes) {
    const p = this.e.tile57_wasm_alloc(bytes.length);
    if (!p) throw new Error("tile57_wasm_alloc failed");
    this.bytes().set(bytes, p);
    return p;
  }
  allocCString(s) {
    const b = new TextEncoder().encode(s + "\0");
    return this.alloc(b);
  }
  wasmFree(ptr) { this.e.tile57_wasm_free(ptr); }

  check(name, status) {
    if (status !== 0) throw new Error(`${name}: status ${status}: ${this.cstr(this.errPtr + 4)}`);
  }
  /** Copy an engine output buffer out of linear memory and tile57_free it. */
  takeOut() {
    const d = this.view();
    const ptr = d.getUint32(this.outPtr, true);
    const len = d.getUint32(this.outLen, true);
    if (!ptr) return null;
    const copy = this.bytes().slice(ptr, ptr + len);
    this.e.tile57_free(ptr);
    return copy;
  }

  version() { return this.cstr(this.e.tile57_version()); }
  warmup() { this.e.tile57_warmup(); }

  /** Bake one S-57 cell (a path in the WASI file tree) to archive bytes. */
  bakeChartBytes(cellPath) {
    const p = this.allocCString(cellPath);
    this.check("bake_chart_bytes", this.e.tile57_bake_chart_bytes(p, this.outPtr, this.outLen, this.errPtr));
    this.wasmFree(p);
    return this.takeOut();
  }

  /** Open a baked archive from bytes; returns the chart handle. */
  chartOpenBytes(archive) {
    const p = this.alloc(archive);
    this.check("chart_open_bytes", this.e.tile57_chart_open_bytes(p, archive.length, this.outPtr, this.errPtr));
    this.wasmFree(p);
    return this.view().getUint32(this.outPtr, true);
  }
  chartClose(chart) { this.e.tile57_chart_close(chart); }

  /** Decode tile57_info for a chart. */
  chartGetInfo(chart) {
    const info = this.e.tile57_wasm_alloc(96);
    this.e.tile57_chart_get_info(chart, info);
    const d = this.view();
    const out = {
      minZoom: d.getUint8(info), maxZoom: d.getUint8(info + 1),
      bands: d.getUint32(info + 4, true),
      hasBounds: !!d.getUint8(info + 8),
      west: d.getFloat64(info + 16, true), south: d.getFloat64(info + 24, true),
      east: d.getFloat64(info + 32, true), north: d.getFloat64(info + 40, true),
      hasAnchor: !!d.getUint8(info + 48),
      anchorLat: d.getFloat64(info + 56, true), anchorLon: d.getFloat64(info + 64, true),
      anchorZoom: d.getFloat64(info + 72, true),
      tileType: d.getUint8(info + 80),
      nativeScale: d.getInt32(info + 84, true),
      isRaster: !!d.getUint8(info + 88),
    };
    this.wasmFree(info);
    return out;
  }

  /** One vector tile from an open chart, or null where the archive has none. */
  chartTile(chart, z, x, y) {
    this.check("chart_tile", this.e.tile57_chart_tile(chart, z, x, y, this.outPtr, this.outLen, this.errPtr));
    return this.takeOut();
  }
  /** A PNG view render from an open chart (canonical mariner settings). */
  chartPng(chart, lon, lat, zoom, width, height) {
    this.check("chart_png", this.e.tile57_chart_png(chart, lon, lat, zoom, width, height, 0, this.outPtr, this.outLen, this.errPtr));
    return this.takeOut();
  }

  /** Compose open charts (BORROWED: close the compositor before them). */
  composeOpen(charts) {
    const list = this.e.tile57_wasm_alloc(4 * charts.length);
    const d = this.view();
    charts.forEach((c, i) => d.setUint32(list + 4 * i, c, true));
    this.check("compose_open", this.e.tile57_compose_open(list, charts.length, this.outPtr, this.errPtr));
    this.wasmFree(list);
    return this.view().getUint32(this.outPtr, true);
  }
  composeClose(compose) { this.e.tile57_compose_close(compose); }

  /** One composed vector tile, or null where no chart owns ground. */
  composeTile(compose, z, x, y) {
    this.check("compose_tile", this.e.tile57_compose_tile(compose, z, x, y, this.outPtr, this.outLen, this.outFlag, this.errPtr));
    return this.takeOut();
  }
  /** A PNG view render from the composite (canonical mariner settings). */
  composePng(compose, lon, lat, zoom, width, height) {
    this.check("compose_png", this.e.tile57_compose_png(compose, lon, lat, zoom, width, height, 0, this.outPtr, this.outLen, this.errPtr));
    return this.takeOut();
  }
}
