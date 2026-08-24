// Type declarations for @beetlebug/tile57-style-engine.
// The runtime lives in index.js; the Zig MarinerSettings struct is authoritative.

export type Scheme = 'day' | 'dusk' | 'night';
export type DepthUnit = 'meters' | 'feet';
export type BoundaryStyle = 'symbolized' | 'plain';

/** A MapLibre GL style document (kept loose; pass straight to `map.setStyle`). */
export type MapLibreStyle = Record<string, unknown>;

/**
 * S-52 mariner display options. Mirrors the Zig `MarinerSettings` struct
 * (src/chartstyle/chartstyle.zig) and the C `tile57_mariner` (include/tile57.h).
 */
export interface MarinerSettings {
  /** Colour scheme (S-52 day/dusk/night palette). */
  scheme: Scheme;
  /** SEABED01 shallow contour, metres. */
  shallow_contour: number;
  /** Own-ship safety contour, metres. */
  safety_contour: number;
  /** SEABED01 deep contour, metres. */
  deep_contour: number;
  /** SNDFRM04 bold/faint sounding split, metres. */
  safety_depth: number;
  /** 4-shade depth (vs 2-shade) water. */
  four_shade_water: boolean;
  /** Contour-label units. */
  depth_unit: DepthUnit;
  /** Show S-52 "display base" category. */
  display_base: boolean;
  /** Show "standard" category. */
  display_standard: boolean;
  /** Show "other" category. */
  display_other: boolean;
  /** M_QUAL data-quality overlay. */
  data_quality: boolean;
  /** INFORM01 information callouts. */
  show_inform_callouts: boolean;
  /** Meta coverage/scale bounds. */
  show_meta_bounds: boolean;
  /** ISODGR01 isolated dangers in shallow water. */
  show_isolated_dangers_shallow: boolean;
  /** S-52 §8.6.1 area boundary style. */
  boundary_style: BoundaryStyle;
  /** Simplified vs paper-chart point symbols. */
  simplified_points: boolean;
  /** Full light-sector legs. */
  show_full_sector_lines: boolean;
  /** Show name text group. */
  text_names: boolean;
  /** Show light-description text. */
  show_light_descriptions: boolean;
  /** Show other text groups. */
  text_other: boolean;
  /** Apply date-dependent display (S-52 §10.4.1.1). */
  date_dependent: boolean;
  /** Highlight (CHDATD01) date-dependent features. */
  highlight_date_dependent: boolean;
  /** Pinned viewing date "YYYYMMDD" ("" = today). */
  date_view: string;
}

/** The canonical default mariner settings (mirrors the Zig struct defaults). */
export const DEFAULT_SETTINGS: Readonly<MarinerSettings>;

export interface GenerateOptions {
  /** Epoch seconds for "today" when no `date_view` is pinned. Default: now. */
  nowUnix?: number;
  /** Return the raw JSON string instead of a parsed object. Default: false. */
  asString?: boolean;
}

export interface LoadOptions {
  /** Raw .wasm bytes (e.g. from fetch). Overrides the bundled file. */
  wasmBytes?: BufferSource;
  /** A precompiled WebAssembly.Module. Overrides bytes + the bundled file. */
  wasmModule?: WebAssembly.Module;
}

/** A loaded, reusable style engine. `generateStyle` is synchronous. */
export class StyleEngine {
  private constructor(instance: WebAssembly.Instance);
  /** The embedded base template (pre-patch), parsed. */
  template(): MapLibreStyle;
  /** Build a MapLibre style for the given (partial) mariner settings. */
  generateStyle(settings?: Partial<MarinerSettings>, opts?: GenerateOptions): MapLibreStyle;
  generateStyle(settings: Partial<MarinerSettings>, opts: GenerateOptions & { asString: true }): string;
}

/** Instantiate the WebAssembly style engine (load once, reuse). */
export function loadStyleEngine(opts?: LoadOptions): Promise<StyleEngine>;

/** One-shot: load + generate a single style. Prefer loadStyleEngine for reuse. */
export function generateStyle(settings?: Partial<MarinerSettings>, opts?: GenerateOptions): Promise<MapLibreStyle>;
export function generateStyle(settings: Partial<MarinerSettings>, opts: GenerateOptions & { asString: true }): Promise<string>;
