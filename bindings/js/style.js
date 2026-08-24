// @beetlebug/tile57-style-engine — generate a MapLibre style.json from S-52
// "mariner settings" entirely client-side, by calling the chartplotter tile57
// `chartstyle.buildStyle` engine compiled to WebAssembly.
//
// The Zig engine is the single source of truth: this file only marshals settings
// in and the resulting style.json out. See ./index.d.ts for the typed surface and
// ./README.md for usage. Zero runtime dependencies.

/**
 * @typedef {'day'|'dusk'|'night'} Scheme
 * @typedef {'meters'|'feet'} DepthUnit
 * @typedef {'symbolized'|'plain'} BoundaryStyle
 */

/**
 * S-52 mariner display options. Every field is optional in {@link generateStyle}:
 * an omitted field uses the engine's canonical default (shown in
 * {@link DEFAULT_SETTINGS}). The Zig `MarinerSettings` struct is authoritative.
 * @typedef {Object} MarinerSettings
 * @property {Scheme} scheme                  Colour scheme (day/dusk/night palette).
 * @property {number} shallow_contour         SEABED01 shallow contour, metres.
 * @property {number} safety_contour          Own-ship safety contour, metres.
 * @property {number} deep_contour            SEABED01 deep contour, metres.
 * @property {number} safety_depth            SNDFRM04 bold/faint sounding split, metres.
 * @property {boolean} four_shade_water       4-shade depth (vs 2-shade) water.
 * @property {DepthUnit} depth_unit           Contour-label units.
 * @property {boolean} display_base           Show S-52 "display base" category.
 * @property {boolean} display_standard       Show "standard" category.
 * @property {boolean} display_other          Show "other" category.
 * @property {boolean} data_quality           M_QUAL data-quality overlay.
 * @property {boolean} show_inform_callouts   INFORM01 callouts.
 * @property {boolean} show_meta_bounds       Meta coverage/scale bounds.
 * @property {boolean} show_isolated_dangers_shallow  ISODGR01 in shallow water.
 * @property {BoundaryStyle} boundary_style   S-52 §8.6.1 area boundary style.
 * @property {boolean} simplified_points      Simplified vs paper-chart point symbols.
 * @property {boolean} show_full_sector_lines Full light-sector legs.
 * @property {boolean} text_names             Show name text group.
 * @property {boolean} show_light_descriptions Show light-description text.
 * @property {boolean} text_other             Show other text groups.
 * @property {boolean} date_dependent         Apply date-dependent display.
 * @property {boolean} highlight_date_dependent Highlight (CHDATD01) date features.
 * @property {string}  date_view              Pinned viewing date "YYYYMMDD" (""=today).
 */

/**
 * The canonical default mariner settings, mirroring the Zig `MarinerSettings`
 * struct + `tile57_mariner_defaults`. Provided for front-ends that need to seed a
 * settings form; the engine itself applies these for any field you omit, so you
 * never have to pass a full object.
 * @type {Readonly<MarinerSettings>}
 */
export const DEFAULT_SETTINGS = Object.freeze({
  scheme: 'day',
  shallow_contour: 2.0,
  safety_contour: 10.0,
  deep_contour: 30.0,
  safety_depth: 10.0,
  four_shade_water: true,
  depth_unit: 'meters',
  display_base: true,
  display_standard: true,
  display_other: false,
  data_quality: false,
  show_inform_callouts: false,
  show_meta_bounds: false,
  show_isolated_dangers_shallow: false,
  boundary_style: 'symbolized',
  simplified_points: false,
  show_full_sector_lines: false,
  text_names: true,
  show_light_descriptions: true,
  text_other: true,
  date_dependent: true,
  highlight_date_dependent: false,
  date_view: '',
});

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

// Resolve the bundled .wasm bytes. In Node we read the file next to this module;
// in a browser/bundler the caller can pass bytes/URL explicitly (see loadStyleEngine).
async function defaultWasmBytes() {
  const url = new URL('./style-engine.wasm', import.meta.url);
  // Node (and Bun/Deno) expose fs; browsers do not — fall back to fetch.
  if (typeof process !== 'undefined' && process.versions && process.versions.node) {
    const { readFile } = await import('node:fs/promises');
    return readFile(url);
  }
  const resp = await fetch(url);
  return new Uint8Array(await resp.arrayBuffer());
}

/**
 * A loaded style engine. Cheap to keep around and reuse; `generateStyle` is
 * synchronous and allocation-light.
 */
export class StyleEngine {
  /** @param {WebAssembly.Instance} instance @private */
  constructor(instance) {
    /** @private */ this._x = instance.exports;
  }

  /** Re-read the (possibly grown/detached) linear memory as a Uint8Array. @private */
  get _mem() {
    return new Uint8Array(this._x.memory.buffer);
  }

  /**
   * The embedded base MapLibre template (before any mariner patching), as an
   * object. Useful for debugging / diffing what the engine starts from.
   * @returns {object}
   */
  template() {
    const ptr = this._x.style_template_ptr();
    const len = this._x.style_template_len();
    return JSON.parse(textDecoder.decode(this._mem.subarray(ptr, ptr + len)));
  }

  /**
   * Build a fresh MapLibre style.json for the given mariner settings.
   * @param {Partial<MarinerSettings>} [settings] Only the fields you want to
   *   change; omitted fields use the engine default.
   * @param {{ nowUnix?: number, asString?: boolean }} [opts]
   *   nowUnix: epoch seconds used to resolve "today" when no date_view is pinned
   *   (default: now). asString: return the raw JSON string instead of an object.
   * @returns {object|string} The MapLibre style.
   */
  generateStyle(settings = {}, opts = {}) {
    if (settings === null || typeof settings !== 'object') {
      throw new TypeError('settings must be an object');
    }
    const nowUnix = opts.nowUnix ?? Math.floor(Date.now() / 1000);
    const json = JSON.stringify(settings);
    const bytes = textEncoder.encode(json);

    const x = this._x;
    const inPtr = bytes.length ? x.style_alloc(bytes.length) : 0;
    if (bytes.length && inPtr === 0) throw new Error('style engine: wasm OOM (settings alloc)');
    try {
      if (bytes.length) this._mem.set(bytes, inPtr);
      const ok = x.style_build(inPtr, bytes.length, nowUnix);
      if (ok !== 1) throw new Error('style engine: buildStyle failed');

      const outPtr = x.style_result_ptr();
      const outLen = x.style_result_len();
      // Copy out before freeing; decode from the (current) memory view.
      const out = textDecoder.decode(this._mem.subarray(outPtr, outPtr + outLen));
      x.style_free(outPtr, outLen);
      return opts.asString ? out : JSON.parse(out);
    } finally {
      if (bytes.length && inPtr !== 0) x.style_free(inPtr, bytes.length);
    }
  }
}

/**
 * Instantiate the WebAssembly style engine.
 * @param {{ wasmBytes?: BufferSource, wasmModule?: WebAssembly.Module }} [opts]
 *   Provide bytes (e.g. from fetch) or a precompiled module for browsers/bundlers
 *   that don't support reading the bundled file. If omitted, the engine loads the
 *   .wasm bundled next to this module (Node: fs; browser: fetch).
 * @returns {Promise<StyleEngine>}
 */
export async function loadStyleEngine(opts = {}) {
  let instance;
  if (opts.wasmModule) {
    instance = await WebAssembly.instantiate(opts.wasmModule, {});
  } else {
    const bytes = opts.wasmBytes ?? (await defaultWasmBytes());
    ({ instance } = await WebAssembly.instantiate(bytes, {}));
  }
  return new StyleEngine(instance);
}

/**
 * One-shot convenience: load the engine and generate a single style. For repeated
 * calls, prefer {@link loadStyleEngine} once and reuse the {@link StyleEngine}.
 * @param {Partial<MarinerSettings>} [settings]
 * @param {{ nowUnix?: number, asString?: boolean }} [opts]
 * @returns {Promise<object|string>}
 */
export async function generateStyle(settings = {}, opts = {}) {
  const engine = await loadStyleEngine();
  return engine.generateStyle(settings, opts);
}
