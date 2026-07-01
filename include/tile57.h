/* tile57.h — public C ABI for libtile57.
 *
 * libtile57 is an embeddable nautical-chart tile engine. You open a chart
 * from a path or in-memory bytes (a PMTiles archive or a raw S-57 ENC cell) and it
 * serves decompressed Mapbox Vector Tiles by (z, x, y). The bytes are produced by the
 * Zig tile generator (the engine/ sources) and consumed by any MVT
 * renderer — in this repo, MapLibre Native via the bundled ChartTileSource
 * adapter (app/chart_tile_source.*), but the ABI itself is renderer-agnostic.
 *
 * Lifetime: a tile57_chart must OUTLIVE every renderer/adapter still holding it.
 *   In the MapLibre hosts the chart is captured by a long-lived FileSource and
 *   is intentionally never closed before process exit (closing first would be a
 *   use-after-free during Map teardown). Call tile57_chart_close only once nothing
 *   can still call tile57_chart_tile on it.
 *
 * Threading: a tile57_chart is NOT internally synchronized. Do not call into the
 *   same chart from multiple threads concurrently (the tile cache is mutated by
 *   tile57_chart_tile without a lock). Distinct charts are independent.
 *
 * Memory: tile57_chart_tile allocates *out; release it with tile57_free, passing the
 *   same length. All pointers are POD across the seam.
 *
 * The S-101 portrayal self-test / bring-up entry points live in a separate
 * header, tile57_diag.h (developer tooling, not part of the embedding API).
 */
#ifndef TILE57_H
#define TILE57_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Library version. tile57_version() returns the string form, e.g. "0.1.0". */
#define TILE57_VERSION_MAJOR 0
#define TILE57_VERSION_MINOR 1
#define TILE57_VERSION_PATCH 0
const char *tile57_version(void);

/* Opaque chart handle. */
typedef struct tile57_chart tile57_chart;

/* One ENC cell for tile57_bake_pmtiles: the base .000 bytes plus its
 * sequential update files (.001, .002, … in order). `updates`/`update_lens` are
 * parallel arrays of length `update_count`; pass update_count = 0 (and NULL
 * arrays) for a base-only cell. All bytes are copied.
 *
 * `name` is the source cell name (e.g. "US4MD81M"), emitted as the `cell` pick-
 * report property on every feature from this cell (see the pick attributes below).
 * NULL/"" = omit it. The field is appended last, so a host that zero-inits the
 * struct (or was compiled before this field existed) gets the NULL (no-badge)
 * behaviour and stays ABI-compatible for the original fields. */
typedef struct {
    const uint8_t *base;
    size_t base_len;
    const uint8_t *const *updates;
    const size_t *update_lens;
    size_t update_count;
    const char *name;
} tile57_cell;

/* ---- pick-report attributes ---------------------------------------------
 *
 * Every emitted MVT feature carries the per-feature cursor-pick / inspector
 * properties used by the S-52 §10.8 pick report: `class` (object-class acronym),
 * `cell` (source cell name, from tile57_cell.name / the bundle's file stem),
 * and `s57` (a JSON object string of the feature's full S-57 attribute set,
 * acronym -> value). These default ON. The `s57` blob is the bulk of a feature's
 * size, so a lean deployment that doesn't need pick/inspect can drop ALL three by
 * passing omit_pick_attrs != 0 to the open/bake call below. omit_pick_attrs == 0
 * (the zero-initialised default) keeps them — so existing callers that pass 0 get
 * the pick report for free. */

/* Open an on-disk ENC_ROOT directory (or a single .000 file) as a streaming chart:
 * the engine enumerates the cells + peeks each one's bbox/scale at open, then reads
 * cell bytes on demand (working set only), so RSS tracks what tiles need, not the
 * whole ENC_ROOT. Rules are the library's embedded catalogue. NULL/failure -> NULL.
 * (chart-api.md) */
tile57_chart *tile57_chart_open(const char *path);

/* Open one in-memory ENC cell (base .000 bytes) as a resident chart. Bytes are copied.
 * NULL/failure -> NULL. (chart-api.md) */
tile57_chart *tile57_chart_open_bytes(const uint8_t *base, size_t len);

/* Open a baked PMTiles bundle from a file path. NULL/failure -> NULL. (chart-api.md) */
tile57_chart *tile57_chart_open_pmtiles(const char *path);

/* Fixed chart metadata (chart-api.md) — folds zoom_range/bands/bounds/anchor into one
 * getter. Bounds/anchor validity are flagged (false -> those fields are 0). */
typedef struct {
    uint8_t  min_zoom, max_zoom;
    uint32_t bands;                                       /* bitmask of navigational bands present */
    bool     has_bounds; double west, south, east, north;
    bool     has_anchor; double anchor_lat, anchor_lon, anchor_zoom;
} tile57_chart_info;
void tile57_chart_get_info(tile57_chart *chart, tile57_chart_info *out);

/* Progress callback for tile57_bake_pmtiles / tile57_bake_bundle. stage 0 =
 * loading/portraying cells, stage 1 = baking tiles. Stage 0 done/total count cells.
 * Stage 1 done/total count tiles: for tile57_bake_bundle they are PER BAND (reset
 * each band) with total = that band's planned tile count, so a host can draw a
 * per-band percentage (the count is a planned estimate from cell bboxes — the actual
 * emitted total is a little lower as empty tiles are skipped, like the Go baker's
 * planned bar). total 0 means "unknown" (the tile57_bake_pmtiles path with no planned
 * count).
 *
 * band_index / band_count locate the current band among the bands that actually
 * bake (0-based index; band_count = how many bands have cells), so the host can
 * label "band <band_index+1>/<band_count>". band_name is the band's
 * navigational-purpose name ("berthing","harbor","approach","coastal","general",
 * "overview") as a static NUL-terminated string owned by the library (valid for the
 * call; copy if retained), or NULL during a non-band-specific report. Together they
 * let the host show e.g. "Generating approach tiles (band 3/6): 84/427 (20%)". */
typedef void (*tile57_bake_progress)(void *user, uint8_t stage, size_t done, size_t total,
                                     uint8_t band_index, uint8_t band_count,
                                     const char *band_name);

/* Shared bake options for tile57_bake_pmtiles / tile57_bake_bundle. Pass NULL for
 * all defaults (embedded rules/catalogue, no band clamp, pick attrs included, no
 * progress). `catalog_dir` and `created` apply to tile57_bake_bundle only —
 * tile57_bake_pmtiles ignores them. */
typedef struct {
    const char *rules_dir;      /* NULL = embedded portrayal rules */
    const char *catalog_dir;    /* NULL = embedded S-101 catalogue (bundle only) */
    const char *created;        /* NULL = manifest "created" unset (bundle only) */
    uint8_t minzoom, maxzoom;   /* 0/0 = no band clamp */
    bool omit_pick_attrs;
    tile57_bake_progress progress;
    void *progress_user;        /* NULL = default/none */
} tile57_bake_opts;

/* Bake an ENC_ROOT's in-memory cells into ONE PMTiles archive, zoom-banded per cell
 * by compilation scale, so the result opens cheaply (tile57_chart_open_pmtiles)
 * instead of holding every cell live. `opts` may be NULL for all defaults; it reads
 * rules_dir / minzoom / maxzoom / omit_pick_attrs / progress / progress_user (the
 * catalog_dir and created fields are ignored — they apply to tile57_bake_bundle).
 * minzoom/maxzoom of 0/0 leave the per-cell bands unclamped. On success returns 1
 * with the archive in *out and *out_len (free with tile57_free); 0 if nothing
 * covered; -1 on error. Like the live open, this parses + portrays every cell, so
 * peak memory tracks the ENC_ROOT size; run it once and cache the archive. */
int tile57_bake_pmtiles(const tile57_cell *cells, size_t count,
                        const tile57_bake_opts *opts,
                        uint8_t **out, size_t *out_len);

/* Bake a single cell.000 OR a whole ENC_ROOT directory (`input`, an on-disk path)
 * into a self-contained chart bundle written under `out_dir` — the SAME package the
 * `tile57 bake … -o out_dir/` CLI emits:
 *   out_dir/tiles/chart.pmtiles   (PMTiles with scamin + vector_layers metadata)
 *   out_dir/assets/colortables.json, linestyles.json, sprite-mln{,@2x}.{json,png}
 *   out_dir/assets/style-{day,dusk,night}.json   (per-scheme, SCAMIN-bucketed)
 *   out_dir/manifest.json         (schema_version, bbox, cells, styles)
 * The host registers chart.pmtiles and serves style-*.json verbatim. `opts` may be
 * NULL for all defaults, else it reads every field: rules_dir/catalog_dir NULL or ""
 * use the catalogue embedded in the library (no on-disk catalogue needed), a
 * non-empty path overrides from disk; created NULL/"" leaves the manifest "created"
 * unset, else stamps it (e.g. an ISO8601 string); minzoom/maxzoom of 0/0 leave the
 * per-cell bands unclamped; progress NULL uses a built-in console progress.
 * `out_cell_count` and `out_bbox` (filled west,south,east,north) are optional — pass
 * NULL to skip. Returns 1 on success, 0 if nothing was covered (no geometry), -1 on
 * error. */
int tile57_bake_bundle(const char *input, const char *out_dir,
                       const tile57_bake_opts *opts,
                       uint32_t *out_cell_count, double *out_bbox);

/* All portrayal assets in memory (the same files bake_bundle writes to disk), from the
 * library's embedded catalogue (catalog_dir NULL/"") or an on-disk one. Pairs with
 * tile57_bake_pmtiles + tile57_style_build for a full in-memory bundle. Returns 1 with
 * *out filled (free with tile57_assets_free), 0 on error. (chart-api.md) */
typedef struct {
    uint8_t *colortables;  size_t colortables_len;
    uint8_t *linestyles;   size_t linestyles_len;
    uint8_t *sprite_json;  size_t sprite_json_len;   uint8_t *sprite_png;  size_t sprite_png_len;
    uint8_t *pattern_json; size_t pattern_json_len;  uint8_t *pattern_png; size_t pattern_png_len;
} tile57_assets;
int  tile57_bake_assets(const char *catalog_dir, tile57_assets *out);
void tile57_assets_free(tile57_assets *out);

/* Release a chart and all cached tiles. Must not be called while any renderer
 * may still call tile57_chart_tile on it (see lifetime note above). */
void tile57_chart_close(tile57_chart *chart);

/* The distinct SCAMIN denominators present in the chart (the live SCAMIN manifest),
 * ascending — the host publishes these so its style builds one native fractional-
 * minzoom bucket layer per value (so features honour their 1:N min-display-scale at
 * zero per-zoom cost). A PMTiles chart reads them from the archive metadata; a cell
 * / ENC_ROOT chart scans every cell's features (parsed without portrayal; streamed
 * cells are read transiently). On success returns 1 with *out pointing at *out_len
 * int32 values; 0 if there are none; -1 on error. Free *out with
 * tile57_free((uint8_t*)*out, *out_len * sizeof(int32_t)). */
int tile57_chart_scamin(tile57_chart *chart, int32_t **out, size_t *out_len);

/* Result of tile57_chart_tile. */
typedef enum {
    TILE57_TILE_OK = 1,     /* *out / *out_len set (free with tile57_free) */
    TILE57_TILE_EMPTY = 0,  /* tile is valid but has no features */
    TILE57_TILE_ERROR = -1, /* generation / decode failure */
} tile57_tile_status;

/* Fetch tile (z, x, y) as decompressed MVT bytes. Results are cached per chart,
 * so re-requesting a tile (as renderers do) is cheap and deterministic. */
tile57_tile_status tile57_chart_tile(tile57_chart *chart, uint8_t z, uint32_t x, uint32_t y,
                           uint8_t **out, size_t *out_len);

/* Free ANY buffer the engine returned (tiles, style JSON, the scamin array,
 * colortables, atlases, …), passing the same length. The universal free. (chart-api.md) */
void tile57_free(void *ptr, size_t len);

/* Drop the in-memory tile cache to bound memory in long-running hosts. Safe to
 * call any time; subsequent tile57_chart_tile calls simply regenerate/decode. */
void tile57_chart_clear_cache(tile57_chart *chart);

/* ---- chart-style generation ---------------------------------------------
 *
 * tile57 ships tile generation AND style generation together: tile57_build_style
 * turns a MapLibre style template + the mariner's S-52 display options + the S-52
 * colortables into a concrete style JSON, client-side. It patches the mariner-
 * driven parts of the template (depth shading, sounding/danger symbol swaps,
 * contour-label units, the per-scheme recolour) and AND-s the display filters
 * (category, band, boundary/point style, date validity, text groups, …) onto
 * every source:"chart" layer. The template + colortables are produced by the
 * engine's asset generator; the host fills tile57_mariner from its UI. */

typedef enum { TILE57_SCHEME_DAY=0, TILE57_SCHEME_DUSK=1, TILE57_SCHEME_NIGHT=2 } tile57_scheme;
typedef enum { TILE57_DEPTH_METERS=0, TILE57_DEPTH_FEET=1 } tile57_depth_unit;
typedef enum { TILE57_BOUNDARY_SYMBOLIZED=0, TILE57_BOUNDARY_PLAIN=1 } tile57_boundary_style;

typedef struct {
    tile57_scheme scheme;
    double shallow_contour, safety_contour, deep_contour, safety_depth;
    bool four_shade_water;
    tile57_depth_unit depth_unit;
    bool display_base, display_standard, display_other;
    bool data_quality, show_inform_callouts, show_meta_bounds, show_isolated_dangers_shallow;
    tile57_boundary_style boundary_style;
    bool simplified_points, show_full_sector_lines;
    bool text_names, show_light_descriptions, text_other;
    bool date_dependent, highlight_date_dependent;
    char date_view[9]; /* "YYYYMMDD" or "" (empty -> today) */
    bool ignore_scamin; /* host ?ignoreScamin debug toggle: drop SCAMIN scale-gating
                         * so every feature shows in-band (the *_scamin layers become
                         * a single ungated layer). NOT an S-52 setting. Default false. */
    double size_scale;  /* physical-scale multiplier (host _featureSizeScale) applied to
                         * icon-size / line-width / text-size. NOT an S-52 setting.
                         * 1.0 = catalogue sizes verbatim. tile57_mariner_defaults sets 1.0. */
    const int32_t *viewing_groups_off; /* S-52 §14.5 fine-grained viewing-group control:
                         * a DENY-LIST of the raw `vg` ids the mariner turned OFF. The
                         * pointee must outlive the tile57_build_style call. NULL/len 0 ->
                         * every viewing group shown. tile57_mariner_defaults sets NULL/0. */
    uint32_t viewing_groups_off_len;
    bool scamin_filter_gate; /* scamin-layers.md: gate SCAMIN with a live client-driven
                         * filter instead of per-value bucket layers — one *_scamin layer
                         * per render-type (no minzoom buckets). The client rewrites the
                         * SCAMIN clause on boundary crossings. NOT an S-52 setting.
                         * tile57_mariner_defaults sets false (per-value buckets). */
} tile57_mariner;

/* Build a MapLibre style JSON from a template + mariner settings + S-52 colortables.
 * enabled_bands: NULL = no band filter (show all); else only features whose `band`
 * rank is in the array (count entries) are shown.
 * scamin: the distinct SCAMIN denominators present in the source (e.g. from
 *   tile57_chart_scamin / the TileJSON). When non-NULL with scamin_count>0 the
 *   `_scamin` source-layers are split into one per-value bucket layer with a native
 *   fractional minzoom = scaminDisplayZoom(value, scamin_lat) — the SAME gating the
 *   offline bundle style emits. NULL / count 0 -> the `_scamin` layers stay a single
 *   ungated layer (features render, but SCAMIN does not gate by value).
 * scamin_lat: representative latitude (degrees) for the bucket minzooms (the SCAMIN
 *   display cutoff is latitude-dependent); use the source's center latitude.
 * On success returns 1 with the style JSON in *out / *out_len (free with
 * tile57_free); 0 on error. */
int tile57_build_style(const char *template_json, size_t template_len,
                       const tile57_mariner *m,
                       const char *colortables_json, size_t colortables_len,
                       const int32_t *enabled_bands, size_t enabled_band_count,
                       const int32_t *scamin, size_t scamin_count, double scamin_lat,
                       uint8_t **out, size_t *out_len);

/* Compute the minimal MapLibre style-mutation ops to turn the style for `old_m`
 * into the style for `new_m` — same template/colortables/bands/scamin inputs as
 * tile57_build_style, so the two styles are comparable. For a flicker-free mariner
 * toggle the host applies each op in place (map.setFilter / setPaintProperty /
 * setLayoutProperty) instead of re-setStyle-ing, leaving overlays and sources
 * untouched. The output is a JSON array; each element is one mutation:
 *   {"op":"setFilter",        "layer":<id>,"value":<filter|null>}
 *   {"op":"setPaintProperty", "layer":<id>,"property":<key>,"value":<v|null>}
 *   {"op":"setLayoutProperty","layer":<id>,"property":<key>,"value":<v|null>}
 * Only layers whose filter / a paint prop / a layout prop differ appear; an
 * unchanged toggle yields "[]". If the two mariners would produce a DIFFERENT SET
 * of layers (not expected for any current mariner field — a safety valve), the
 * result is [{"op":"rebuild"}], signalling the host to fall back to a full setStyle.
 * On success returns 1 with the op array in *out / *out_len (free with
 * tile57_free); 0 on error. */
int tile57_style_diff(const char *template_json, size_t template_len,
                      const tile57_mariner *old_m, const tile57_mariner *new_m,
                      const char *colortables_json, size_t colortables_len,
                      const int32_t *enabled_bands, size_t enabled_band_count,
                      const int32_t *scamin, size_t scamin_count, double scamin_lat,
                      uint8_t **out, size_t *out_len);

/* The S-52 colortables and base style template are baked into the library, so a
 * host can generate a complete style with no on-disk catalogue or template file:
 *   tile57_colortables_default(&ct,&ctn);
 *   tile57_style_template(scheme, "http://host/{z}/{x}/{y}", NULL,NULL,0,0, &t,&tn);
 *   tile57_build_style(t,tn, &m, ct,ctn, bands,nb, scamin,nsm,lat, &style,&sn);
 * Free each buffer with tile57_free. */

/* S-52 colortables.json (token -> hex per day/dusk/night) from the colour profile
 * baked into the library. Returns 1 with out/out_len set, 0 on error. */
int tile57_colortables_default(uint8_t **out, size_t *out_len);

/* Base MapLibre style template (layers + chart `sources` + sprite/glyph URLs) from
 * the catalogue baked into the library — no template file needed. The source lives
 * in the template; the per-change mariner patch (tile57_build_style) takes none.
 *   scheme:       a tile57_scheme (selects the per-scheme palette).
 *   source_tiles: the chart {z}/{x}/{y} tiles URL (NULL -> a default pmtiles:// source).
 *   sprite,glyphs:base URLs that enable the symbol / text layers (NULL omits them).
 *   minzoom,maxzoom: 0 -> engine defaults.
 * Returns 1 with out/out_len set (free with tile57_free), 0 on error. */
int tile57_style_template(tile57_scheme scheme, const char *source_tiles,
                          const char *sprite, const char *glyphs,
                          uint32_t minzoom, uint32_t maxzoom,
                          uint8_t **out, size_t *out_len);

/* Fill *m with the canonical default mariner settings (so a host needn't hardcode
 * them). date_view is set to "" (today). */
void tile57_mariner_defaults(tile57_mariner *m);

#ifdef __cplusplus
}
#endif

#endif /* TILE57_H */
