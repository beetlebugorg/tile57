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

  /** Bake every chart in an exchange-set zip to <outDir>/<CELL>/<CELL>.pmtiles
   * in the WASI file tree (updates applied from the archive). Returns how many
   * charts were baked. */
  bakeZip(zipPath, outDir) {
    const zp = this.allocCString(zipPath);
    const op = this.allocCString(outDir);
    this.check("bake_zip", this.e.tile57_bake_zip(zp, op, 1, 0, 0, this.outPtr, this.errPtr));
    this.wasmFree(zp);
    this.wasmFree(op);
    return this.view().getUint32(this.outPtr, true);
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

  // ---- draw-ready GPU scenes (see the tile57.h GPU section) ---------------

  /** {vertex, quad, range, uniforms} struct sizes the engine compiled with.
   * Compare against the constants the renderer assumes. */
  abiGpuLayout() {
    const v = this.e.tile57_abi_gpu_layout();
    return { vertex: v & 0xff, quad: (v >>> 8) & 0xff, range: (v >>> 16) & 0xff, uniforms: (v >>> 24) & 0xff };
  }

  // Decode a tile57_gpu_scene struct into wasm-memory views. The views BORROW
  // linear memory: use them before free(), and re-take them after any call
  // that can grow the memory.
  sceneView(sp) {
    const d = this.view();
    const s = {
      vertices: d.getUint32(sp, true), vertexCount: d.getUint32(sp + 4, true),
      indices: d.getUint32(sp + 8, true), indexCount: d.getUint32(sp + 12, true),
      quads: d.getUint32(sp + 16, true), quadCount: d.getUint32(sp + 20, true),
      ranges: d.getUint32(sp + 24, true), rangeCount: d.getUint32(sp + 28, true),
      patterns: d.getUint32(sp + 32, true), patternCount: d.getUint32(sp + 36, true),
    };
    const self = this;
    return {
      ...s,
      vertexBytes: () => self.bytes().subarray(s.vertices, s.vertices + s.vertexCount * 32),
      indexBytes: () => self.bytes().subarray(s.indices, s.indices + s.indexCount * 4),
      quadBytes: () => self.bytes().subarray(s.quads, s.quads + s.quadCount * 44),
      patternList: () => {
        const dv = self.view(), out = [];
        for (let i = 0; i < s.patternCount; i++) {
          const p = s.patterns + 16 * i;
          const w = dv.getUint32(p, true), h = dv.getUint32(p + 4, true);
          const rgba = dv.getUint32(p + 8, true), len = dv.getUint32(p + 12, true);
          out.push({ w, h, rgba: self.bytes().subarray(rgba, rgba + len) });
        }
        return out;
      },
      free: () => { self.e.tile57_gpu_scene_free(sp); self.wasmFree(sp); },
    };
  }

  /** Portray a chart view into draw-ready GPU buffers. Call .free() on the
   * result once uploaded. */
  chartGpuScene(chart, lon, lat, zoom, width, height, pixelRatio) {
    const sp = this.e.tile57_wasm_alloc(44);
    this.check("chart_gpu_scene", this.e.tile57_chart_gpu_scene(chart, lon, lat, zoom, width, height, 0, pixelRatio, sp, this.errPtr));
    return this.sceneView(sp);
  }
  /** The composed twin of chartGpuScene. */
  composeGpuScene(compose, lon, lat, zoom, width, height, pixelRatio) {
    const sp = this.e.tile57_wasm_alloc(44);
    this.check("compose_gpu_scene", this.e.tile57_compose_gpu_scene(compose, lon, lat, zoom, width, height, 0, pixelRatio, sp, this.errPtr));
    return this.sceneView(sp);
  }

  /** Batch a scene's ranges into draw calls (tile57_gpu_batch). `atlasHave`
   * is a bitmask over the tile57_gpu_atlas ids the host uploaded; `halo` is
   * the palette background RGBA (0..1) for SDF label halos. */
  gpuBatch(scene, { textOn = true, soundOn = true, excludeOpaque = false, atlasHave = 0, halo = [1, 1, 1, 1] } = {}) {
    const op = this.e.tile57_wasm_alloc(20);
    {
      const d = this.view();
      d.setUint8(op, textOn ? 1 : 0);
      d.setUint8(op + 1, soundOn ? 1 : 0);
      d.setUint8(op + 2, excludeOpaque ? 1 : 0);
      d.setUint8(op + 3, atlasHave);
      for (let i = 0; i < 4; i++) d.setFloat32(op + 4 + 4 * i, halo[i], true);
    }
    const cap = scene.rangeCount;
    const dp = this.e.tile57_wasm_alloc(Math.max(1, cap * 36));
    const n = this.e.tile57_gpu_batch(scene.ranges, scene.rangeCount, op, dp, cap);
    if (n > cap) throw new Error("gpu_batch: draw buffer too small");
    const d = this.view(), draws = [];
    for (let i = 0; i < n; i++) {
      const p = dp + 36 * i;
      draws.push({
        first: d.getUint32(p, true), count: d.getUint32(p + 4, true),
        prim: d.getUint8(p + 8), pipeline: d.getUint8(p + 9), atlas: d.getUint8(p + 10),
        pattern: d.getUint32(p + 12, true), catMaskOr: d.getUint32(p + 16, true),
        color: [0, 1, 2, 3].map((j) => d.getFloat32(p + 20 + 4 * j, true)),
      });
    }
    this.wasmFree(op);
    this.wasmFree(dp);
    return draws;
  }

  // Read a tile57_assets struct field pair; copy out of linear memory.
  assetField(ap, off) {
    const d = this.view();
    const ptr = d.getUint32(ap + off, true), len = d.getUint32(ap + off + 4, true);
    return ptr ? this.bytes().slice(ptr, ptr + len) : null;
  }

  /** The MapLibre-style symbol atlas {json, png} for a scheme (0 day, 1 dusk,
   * 2 night), rasterized at pixelRatio. Pass the SAME pixelRatio to the
   * gpu-scene calls, or the UVs will not index the texture. */
  bakeSpriteMln(pixelRatio, scheme = 0) {
    const ap = this.e.tile57_wasm_alloc(48);
    this.check("bake_sprite_mln", this.e.tile57_bake_sprite_mln(0, pixelRatio, scheme, ap, this.errPtr));
    const out = { json: this.assetField(ap, 16), png: this.assetField(ap, 24) };
    this.e.tile57_assets_free(ap);
    this.wasmFree(ap);
    return out;
  }

  /** The SDF label-glyph atlas {json, png} for a face: 0 regular, 1 bold,
   * 2 italic. The png is the RGBA signed-distance field the SDF pipeline
   * samples. */
  bakeGlyphSdf(face = 0) {
    const ap = this.e.tile57_wasm_alloc(48);
    this.check("bake_glyph_sdf", this.e.tile57_bake_glyph_sdf_face(ap, face, this.errPtr));
    const out = { json: this.assetField(ap, 16), png: this.assetField(ap, 24) };
    this.e.tile57_assets_free(ap);
    this.wasmFree(ap);
    return out;
  }

  /** The embedded S-52 colortables JSON (all three palettes). */
  colortablesDefault() {
    this.check("colortables_default", this.e.tile57_colortables_default(this.outPtr, this.outLen, this.errPtr));
    return new TextDecoder().decode(this.takeOut());
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
