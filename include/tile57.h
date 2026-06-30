/* tile57.h — public C ABI for libtile57.
 *
 * libtile57 is an embeddable nautical-chart tile source. You open a source
 * from in-memory bytes (a PMTiles archive or a raw S-57 ENC cell) and it serves
 * decompressed Mapbox Vector Tiles by (z, x, y). The bytes are produced by the
 * Zig tile generator (the engine/ sources) and consumed by any MVT
 * renderer — in this repo, MapLibre Native via the bundled ChartTileSource
 * adapter (app/chart_tile_source.*), but the ABI itself is renderer-agnostic.
 *
 * Lifetime: a tile57_source must OUTLIVE every renderer/adapter still holding it.
 *   In the MapLibre hosts the source is captured by a long-lived FileSource and
 *   is intentionally never closed before process exit (closing first would be a
 *   use-after-free during Map teardown). Call tile57_source_close only once nothing
 *   can still call tile57_tile_get on it.
 *
 * Threading: a tile57_source is NOT internally synchronized. Do not call into the
 *   same source from multiple threads concurrently (the tile cache is mutated by
 *   tile57_tile_get without a lock). Distinct sources are independent.
 *
 * Memory: tile57_tile_get allocates *out; release it with tile57_tile_free, passing the
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

/* Opaque chart tile source. */
typedef struct tile57_source tile57_source;

/* Source backend / on-disk format. */
typedef enum {
    TILE57_FORMAT_AUTO = 0,     /* sniff: PMTiles first, then S-57 cell */
    TILE57_FORMAT_PMTILES = 1,  /* a PMTiles archive */
    TILE57_FORMAT_S57_CELL = 2, /* a raw S-57 ENC cell (.000); tiles generated live */
} tile57_format;

/* Open a chart tile source from in-memory bytes.
 *   format:    TILE57_FORMAT_AUTO tries PMTiles then S-57; a specific value skips the
 *              sniff (and fails if the bytes are not that format).
 *   rules_dir: S-101 portrayal rules directory, used only for S-57 cells. NULL
 *              selects the built-in default (the TILE57_S101_RULES env var
 *              if set, otherwise the vendored official catalogue).
 * The bytes are copied; the caller may free `data` immediately after this returns.
 * Returns an opaque handle, or NULL on error. Close with tile57_source_close. */
tile57_source *tile57_source_open(const uint8_t *data, size_t len,
                          tile57_format format, const char *rules_dir);

/* One ENC cell for tile57_source_open_cells: the base .000 bytes plus its
 * sequential update files (.001, .002, … in order). `updates`/`update_lens` are
 * parallel arrays of length `update_count`; pass update_count = 0 (and NULL
 * arrays) for a base-only cell. All bytes are copied. */
typedef struct {
    const uint8_t *base;
    size_t base_len;
    const uint8_t *const *updates;
    const size_t *update_lens;
    size_t update_count;
} tile57_cell_input;

/* Open an ENC_ROOT as a multi-cell source: every cell is overlaid when a tile is
 * generated, so a region spanning several cells renders them all. The host scans
 * the directory and reads the files (it owns file IO); this parses + portrays
 * each cell. `rules_dir` is as in tile57_source_open. Returns an opaque
 * handle, or NULL if no cell parses. Close with tile57_source_close. */
tile57_source *tile57_source_open_cells(
    const tile57_cell_input *cells, size_t count, const char *rules_dir);

/* ---- streaming ENC_ROOT (low memory) ------------------------------------
 *
 * Like tile57_source_open_cells, but the host does NOT hand over every cell's
 * bytes up front. Instead it supplies cheap per-cell metadata (bbox + scale) and
 * a reader callback; a cell's bytes are read only when a tile needs them and are
 * freed again on LRU eviction. The host therefore holds only the working set's
 * bytes, not the whole catalogue — the right choice for a large ENC_ROOT. */

/* Pre-peeked metadata for one cell (the host computes/knows these). */
typedef struct {
    double west, south, east, north; /* geographic bounds, degrees */
    int32_t cscl;                    /* compilation scale denominator (1:cscl) */
} tile57_cell_meta;

/* Cell bytes returned by a reader. The reader transfers OWNERSHIP of malloc()'d
 * buffers — base, each updates[i], and the updates/update_lens arrays — and the
 * library free()s them once the cell is parsed. update_count = 0 (NULL arrays)
 * for a base-only cell. */
typedef struct {
    const uint8_t *base;
    size_t base_len;
    const uint8_t *const *updates;
    const size_t *update_lens;
    size_t update_count;
} tile57_cell_bytes;

/* Read cell `index`'s bytes into *out (malloc'd; the library frees them).
 * Return true on success, false to skip the cell. Called on demand (and again
 * after eviction); must be safe to call from the thread that calls tile57_tile_get. */
typedef bool (*tile57_cell_read_fn)(void *user, size_t index, tile57_cell_bytes *out);

/* Open a streaming ENC_ROOT: `metas`/`count` describe the cells; `read`/`user`
 * fetch bytes on demand. No bytes are read here. Returns an opaque handle or
 * NULL. Close with tile57_source_close. */
tile57_source *tile57_source_open_cells_streaming(
    const tile57_cell_meta *metas, size_t count,
    tile57_cell_read_fn read, void *user, const char *rules_dir);

/* Progress callback for tile57_bake_cells. stage 0 = loading/portraying cells,
 * stage 1 = baking tiles; done/total count cells (stage 0) or tiles (stage 1). */
typedef void (*tile57_bake_progress)(void *user, uint8_t stage, size_t done, size_t total);

/* Bake a whole ENC_ROOT (the same cells as tile57_source_open_cells) into ONE
 * PMTiles archive, zoom-banded per cell by compilation scale, so the result opens
 * cheaply (tile57_source_open with TILE57_FORMAT_PMTILES) instead of holding every
 * cell live. minzoom/maxzoom clamp the per-cell bands (pass 0/24 for no clamp).
 * `progress` may be NULL. On success returns 1 with the archive in *out and
 * *out_len (free with tile57_tile_free); 0 if nothing covered; -1 on error. Like
 * the live open, this parses + portrays every cell, so peak memory tracks the
 * ENC_ROOT size; run it once and cache the archive. */
int tile57_bake_cells(
    const tile57_cell_input *cells, size_t count, const char *rules_dir,
    uint8_t minzoom, uint8_t maxzoom,
    tile57_bake_progress progress, void *user,
    uint8_t **out, size_t *out_len);

/* Bake a single cell.000 OR a whole ENC_ROOT directory (`input`, an on-disk path)
 * into a self-contained chart bundle written under `out_dir` — the SAME package the
 * `tile57 bake … -o out_dir/` CLI emits:
 *   out_dir/tiles/chart.pmtiles   (PMTiles with scamin + vector_layers metadata)
 *   out_dir/assets/colortables.json, linestyles.json, sprite-mln{,@2x}.{json,png}
 *   out_dir/assets/style-{day,dusk,night}.json   (per-scheme, SCAMIN-bucketed)
 *   out_dir/manifest.json         (schema_version, bbox, cells, styles)
 * The host registers chart.pmtiles and serves style-*.json verbatim. `rules_dir`
 * and `catalog_dir` NULL or "" use the catalogue embedded in the library (no
 * on-disk catalogue needed); a non-empty path overrides from disk. `created` NULL or
 * "" leaves the manifest "created" unset, else stamps it (e.g. an ISO8601 string).
 * minzoom/maxzoom clamp the per-cell bands (pass 0/24 for no clamp). `progress` may
 * be NULL (a built-in console progress is used). `out_cell_count` and `out_bbox`
 * (filled west,south,east,north) are optional — pass NULL to skip. Returns 1 on
 * success, 0 if nothing was covered (no geometry), -1 on error. */
int tile57_bake_bundle(
    const char *input, const char *out_dir,
    const char *rules_dir, const char *catalog_dir, const char *created,
    uint8_t minzoom, uint8_t maxzoom,
    tile57_bake_progress progress, void *user,
    uint32_t *out_cell_count, double *out_bbox);

/* The resolved backend format (meaningful after a TILE57_FORMAT_AUTO open). */
tile57_format tile57_source_format(tile57_source *src);

/* Release a source and all cached tiles. Must not be called while any renderer
 * may still call tile57_tile_get on it (see lifetime note above). */
void tile57_source_close(tile57_source *src);

/* Min/max zoom the source serves (PMTiles: archive range; cell: 0..18). */
void tile57_source_zoom_range(tile57_source *src, uint8_t *min_z, uint8_t *max_z);

/* Bitmask of the navigational bands present in the source (bit r = band rank r has
 * a cell; 0=berthing/finest .. 5=overview/coarsest). 0 for a single cell / PMTiles.
 * Lets a host build a data-driven band filter listing only the loaded bands. */
uint32_t tile57_source_bands(tile57_source *src);

/* Geographic bounds (west, south, east, north degrees); true when known, so a
 * host can frame the data with its own fit-to-window logic. PMTiles -> archive
 * bounds; cell -> data extent. False for degenerate or near-global extents (the
 * host should then choose its own camera). */
bool tile57_source_bounds(tile57_source *src,
                      double *west, double *south, double *east, double *north);

/* A good initial camera (center lat/lon + zoom) on real data, for when fitting the
 * whole source would zoom out uselessly (a continental ENC_ROOT). Returns true and
 * sets the out-params for a lazy ENC_ROOT source; false otherwise (the caller
 * should use fit-to-bounds). */
bool tile57_source_anchor(tile57_source *src, double *lat, double *lon, double *zoom);

/* Result of tile57_tile_get. */
typedef enum {
    TILE57_TILE_OK = 1,     /* *out / *out_len set (free with tile57_tile_free) */
    TILE57_TILE_EMPTY = 0,  /* tile is valid but has no features */
    TILE57_TILE_ERROR = -1, /* generation / decode failure */
} tile57_tile_status;

/* Fetch tile (z, x, y) as decompressed MVT bytes. Results are cached per source,
 * so re-requesting a tile (as renderers do) is cheap and deterministic. */
tile57_tile_status tile57_tile_get(tile57_source *src, uint8_t z, uint32_t x, uint32_t y,
                           uint8_t **out, size_t *out_len);

/* Free a buffer returned by tile57_tile_get (pass the same length). */
void tile57_tile_free(uint8_t *ptr, size_t len);

/* Drop the in-memory tile cache to bound memory in long-running hosts. Safe to
 * call any time; subsequent tile57_tile_get calls simply regenerate/decode. */
void tile57_source_clear_cache(tile57_source *src);

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
} tile57_mariner;

/* Build a MapLibre style JSON from a template + mariner settings + S-52 colortables.
 * enabled_bands: NULL = no band filter (show all); else only features whose `band`
 * rank is in the array (count entries) are shown. On success returns 1 with the
 * style JSON in *out / *out_len (free with tile57_tile_free); 0 on error. */
int tile57_build_style(const char *template_json, size_t template_len,
                       const tile57_mariner *m,
                       const char *colortables_json, size_t colortables_len,
                       const int32_t *enabled_bands, size_t enabled_band_count,
                       uint8_t **out, size_t *out_len);

/* The S-52 colortables and base style template are baked into the library, so a
 * host can generate a complete style with no on-disk catalogue or template file:
 *   tile57_colortables_default(&ct,&ctn);
 *   tile57_style_template(scheme, "http://host/{z}/{x}/{y}", NULL,NULL,0,0, &t,&tn);
 *   tile57_build_style(t,tn, &m, ct,ctn, bands,nb, &style,&sn);   // mariner patch
 * Free each buffer with tile57_tile_free. */

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
 * Returns 1 with out/out_len set (free with tile57_tile_free), 0 on error. */
int tile57_style_template(tile57_scheme scheme, const char *source_tiles,
                          const char *sprite, const char *glyphs,
                          uint32_t minzoom, uint32_t maxzoom,
                          uint8_t **out, size_t *out_len);

/* Fill *m with the canonical default mariner settings (so a host needn't hardcode
 * them). date_view is set to "" (today). */
void tile57_mariner_defaults(tile57_mariner *m);

/* ---- portrayal asset generation -----------------------------------------
 *
 * Generate the S-101 portrayal assets at runtime from in-memory S-101 Portrayal
 * Catalogue bytes — the host reads the catalogue files; tile57 never touches the
 * filesystem. All outputs are owned by the library; free each buffer with
 * tile57_tile_free (same length). The offline `tile57` CLI emits the same files.
 */

/* A named blob: a NUL-terminated id (e.g. a file stem) + its bytes. */
typedef struct {
    const char *id;
    const uint8_t *data;
    size_t len;
} tile57_named_bytes;

/* colortables.json (S-52 colour token -> hex per day/dusk/night palette) from a
 * ColorProfiles colorProfile.xml. Returns 1 with out/out_len set, 0 on error. */
int tile57_colortables(const uint8_t *xml, size_t xml_len,
                       uint8_t **out, size_t *out_len);

/* linestyles.json (dash patterns + placed symbols) from the S-101 LineStyles
 * (each `id` = the XML file stem). Returns 1 with out/out_len set, 0 on error. */
int tile57_linestyles(const tile57_named_bytes *line_styles, size_t count,
                      uint8_t **out, size_t *out_len);

/* Sprite atlas: rasterize the S-101 Symbols (SVG) against a palette stylesheet
 * (css = a SvgStyle.css's content) and pack them. Returns 1 with the sprite.json
 * in out_json/out_json_len and the atlas PNG in out_png/out_png_len (free each
 * with tile57_tile_free); 0 on error. */
int tile57_sprite_atlas(const tile57_named_bytes *svgs, size_t count,
                        const uint8_t *css, size_t css_len,
                        uint8_t **out_json, size_t *out_json_len,
                        uint8_t **out_png, size_t *out_png_len);

/* Area-fill pattern atlas: tile each S-101 AreaFills XML's referenced symbol on
 * its v1/v2 lattice. `symbols` are the Symbols (SVG) the fills reference. Returns
 * 1 with patterns.json + patterns.png (free each with tile57_tile_free); 0 on error. */
int tile57_pattern_atlas(const tile57_named_bytes *fills, size_t fill_count,
                         const tile57_named_bytes *symbols, size_t symbol_count,
                         const uint8_t *css, size_t css_len,
                         uint8_t **out_json, size_t *out_json_len,
                         uint8_t **out_png, size_t *out_png_len);

#ifdef __cplusplus
}
#endif

#endif /* TILE57_H */
