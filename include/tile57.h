/* tile57.h — public C ABI for libtile57.
 *
 * libtile57 is an embeddable nautical-chart engine. It turns IHO S-57 ENC cells
 * into vector tiles + a matching S-52 style, and renders finished charts to
 * pixels / PDF / a callback surface.
 *
 * Tiles are made ONE way: bake each ENC cell to its own PMTiles
 * (tile57_bake_cell_bytes), then compose them ON DEMAND through the ownership
 * partition (tile57_compose_open / tile57_compose_serve). The composed bytes are
 * decompressed vector tiles — MapLibre Tiles (MLT, the default) or Mapbox Vector
 * Tiles (MVT) — consumed by any matching renderer (maplibre-gl >= 5.12 decodes
 * both natively via the vector source `encoding` option); the ABI is
 * renderer-agnostic.
 *
 * A tile57_chart is a SEPARATE handle used for metadata (open + get_info / cells /
 * features / coverage / query / scamin) and for rendering a view to pixels / PDF /
 * a callback surface. It does not itself serve (z, x, y) tiles — that is the
 * compositor's job.
 *
 * The sections below:
 *   1. Version
 *   2. Chart: open + metadata
 *   3. Cell baking (the per-cell tiles the compositor stitches)
 *   4. Live composing (the runtime compositor)
 *   5. Render surface (PNG / PDF / callback canvas + world-space surface)
 *   6. Style + portrayal assets
 *   7. Util / catalogue / debug
 *
 * Lifetime: a tile57_chart / tile57_compose_source must OUTLIVE every renderer or
 *   adapter still holding it. In the MapLibre hosts the handle is captured by a
 *   long-lived source and intentionally never closed before process exit (closing
 *   first would be a use-after-free during teardown). Call tile57_chart_close /
 *   tile57_compose_close only once nothing can still call into it.
 *
 * Threading: neither handle is internally synchronized — do not call into the SAME
 *   handle from multiple threads concurrently (caches are mutated without a lock).
 *   Distinct handles are independent.
 *
 * Memory: calls that return bytes allocate *out; release it with tile57_free,
 *   passing the same length. All pointers are POD across the seam.
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

/* ======================================================================== *
 * 1. Version
 * ======================================================================== */

/* Library version. tile57_version() returns the string form, e.g. "0.1.0". */
#define TILE57_VERSION_MAJOR 0
#define TILE57_VERSION_MINOR 1
#define TILE57_VERSION_PATCH 0
const char *tile57_version(void);

/* ======================================================================== *
 * 2. Chart: open + metadata
 *
 * A tile57_chart is the metadata + render handle: open a cell (or a baked
 * PMTiles) and read its bounds / scale / coverage / features, query the feature
 * under a point, or render a view (section 5). Tile production is separate —
 * see sections 3 (bake) and 4 (compose).
 * ======================================================================== */

/* Opaque chart handle. */
typedef struct tile57_chart tile57_chart;

/* Open ONE S-57 cell (a .000 file, with its .001.. update chain auto-read from the
 * same directory) OR a whole ENC_ROOT directory, via the STREAMING path: each cell's
 * metadata (name, compilation scale, M_COVR coverage) is enumerated up front and
 * tiles are baked lazily, per requested tile — there is no upfront full-cell bake.
 * This backend exposes the per-cell list (tile57_chart_cells) and the render/query
 * surface. See the header/zoom variants for a metadata-only scan or a progressive
 * narrow-band open. NULL/fail -> NULL. */
tile57_chart *tile57_chart_open(const char *path);

/* Open ONE cell for METADATA ONLY — bbox, native_scale, and M_COVR coverage — via a
 * cheap parse with NO tile bake, for a host's chart-database/header scan. Do NOT
 * render_surface this handle (it has no portrayal). NULL/failure -> NULL. */
tile57_chart *tile57_chart_open_header(const char *path);

/* Open ONE cell baking only [minzoom, maxzoom] to an in-memory PMTiles: bake a narrow
 * native band fast for first paint, then re-open the full range in the background
 * (progressive load). Renders via the fast reader path. NULL/failure -> NULL. */
tile57_chart *tile57_chart_open_zoom(const char *path, uint8_t minzoom, uint8_t maxzoom);

/* Open one in-memory ENC cell (base .000 bytes) as a resident chart. Bytes are copied.
 * NULL/failure -> NULL. */
tile57_chart *tile57_chart_open_bytes(const uint8_t *base, size_t len);

/* Open a baked PMTiles bundle from a file path. NULL/failure -> NULL. */
tile57_chart *tile57_chart_open_pmtiles(const char *path);

/* Vector-tile encodings the engine produces (reported in tile57_chart_info.tile_type;
 * the compositor serves MLT). */
typedef enum {
    TILE57_TILE_TYPE_MVT = 1, /* Mapbox Vector Tile */
    TILE57_TILE_TYPE_MLT = 2, /* MapLibre Tile (the default) */
} tile57_tile_type;

/* Fixed chart metadata — folds zoom_range/bands/bounds/anchor into one
 * getter. Bounds/anchor validity are flagged (false -> those fields are 0).
 * tile_type is the vector-tile encoding for this chart's tiles (a
 * tile57_tile_type): a PMTiles-backed chart reports its archive's stored type; a
 * cell-backed chart reports the engine's default bake encoding. A host passes it
 * to tile57_style_template so the renderer decodes the tiles correctly. */
typedef struct {
    uint8_t  min_zoom, max_zoom;
    uint32_t bands;                                       /* bitmask of navigational bands present */
    bool     has_bounds; double west, south, east, north;
    bool     has_anchor; double anchor_lat, anchor_lon, anchor_zoom;
    uint8_t  tile_type;                                   /* tile57_tile_type */
    int32_t  native_scale; /* compilation scale (1:N) for a live cell; 0 = unknown
                            * (PMTiles: derive the scale from the zoom band instead) */
} tile57_chart_info;
void tile57_chart_get_info(tile57_chart *chart, tile57_chart_info *out);

/* The distinct SCAMIN denominators present in the chart (the live SCAMIN manifest),
 * ascending — the host publishes these so its style builds one native fractional-
 * minzoom bucket layer per value (so features honour their 1:N min-display-scale at
 * zero per-zoom cost). A PMTiles chart reads them from the archive metadata; a cell
 * / ENC_ROOT chart scans every cell's features (parsed without portrayal; streamed
 * cells are read transiently). On success returns 1 with *out pointing at *out_len
 * int32 values; 0 if there are none; -1 on error. Free *out with
 * tile57_free((uint8_t*)*out, *out_len * sizeof(int32_t)). */
int tile57_chart_scamin(tile57_chart *chart, int32_t **out, size_t *out_len);

/* The chart's per-cell metadata as a JSON array, one object per cell:
 *   [{"name":"US5MD1MC","scale":12000,"edition":"13","update":"3",
 *     "issueDate":"20240105","agency":550,"bbox":[west,south,east,north]}, ...]
 * `name` is the DSNM stem; `scale` is DSPM CSCL; edition/update/issueDate/
 * agency are DSID EDTN/UPDN/ISDT/AGEN after the cell's update chain is
 * applied; `bbox` is the cell's geographic extent, omitted when none parses.
 * Returns 1 with *out / *out_len holding the JSON (free with tile57_free);
 * 0 if the chart has no cells (e.g. a PMTiles chart — its bundle manifest
 * carries the cell inventory); -1 on error. */
int tile57_chart_cells(tile57_chart *chart, uint8_t **out, size_t *out_len);

/* The chart's features for the given object classes (comma-separated
 * acronyms, e.g. "DEPARE,DRGARE") as a GeoJSON FeatureCollection: geometry
 * in lon/lat (Polygon rings largest-first, MultiPoint with depths for
 * soundings, LineString/Point as encoded), properties = {"class":"DEPARE",
 * ...the feature's full S-57 acronym->value attribute map}. Parsed without
 * portrayal; a whole-ENC_ROOT query walks every cell — the caller owns that
 * cost. Returns 1 with *out / *out_len holding the JSON (free with
 * tile57_free); 0 if no features matched; -1 on error. */
int tile57_chart_features(tile57_chart *chart, const char *classes,
                          uint8_t **out, size_t *out_len);

/* The chart's M_COVR(CATCOV=1) data-coverage polygons — the real coverage a host
 * reports so a quilt fills gaps to coarser cells (vs. the bounding box). ring() is
 * called once per polygon with its exterior ring as `npts` interleaved lon,lat
 * doubles (valid only during the call). Only the live-cell backend (an opened
 * .000) carries this; a baked PMTiles returns 0 with no calls. 0 ok, -1 bad args. */
typedef struct {
    void *ctx;
    void (*ring)(void *ctx, const double *lonlat, size_t npts);
} tile57_coverage_cb;
int tile57_chart_coverage(tile57_chart *chart, const tile57_coverage_cb *cb);

/* Cursor object-query (S-52 pick): feature() is invoked once per feature the
 * point (lon,lat) falls in — area point-in-polygon, line/point within a small
 * radius — with the S-57 object-class acronym, the attribute JSON (acronym->value),
 * and the source cell name. Pointers are valid only for the duration of the call. */
typedef struct {
    void *ctx;
    void (*feature)(void *ctx, const char *cls, size_t cls_len,
                    const char *s57, size_t s57_len,
                    const char *cell, size_t cell_len);
} tile57_query_cb;
/* `zoom` is the current view's web-mercator zoom: the query uses the tile at that
 * zoom, so it reports the features actually DISPLAYED there (SCAMIN-bucketed) and
 * the pick tolerance tracks on-screen distance. Returns 0 ok, -1 bad args. */
int tile57_chart_query(tile57_chart *chart, double lon, double lat, double zoom,
                       const tile57_query_cb *cb);

/* Release a chart and all cached tiles. Must not be called while any
 * renderer/adapter may still render from it (see the lifetime note above). */
void tile57_chart_close(tile57_chart *chart);

/* ======================================================================== *
 * 3. Cell baking
 *
 * The composite model bakes each ENC cell to its own PMTiles at that cell's
 * compilation scale; the runtime compositor (section 4) stitches them on demand.
 * ======================================================================== */

/* Pick-report attributes. Every emitted vector-tile feature carries the per-feature
 * cursor-pick / inspector properties used by the S-52 §10.8 pick report: `class`
 * (object-class acronym), `cell` (source cell name, the file stem), and `s57` (a
 * JSON object string of the feature's full S-57 attribute set, acronym -> value).
 * These are baked into the per-cell tiles and are what tile57_chart_query and a
 * host inspector read back. */

/* Bake ONE cell (+ its .001.. updates, read from disk) to PMTiles bytes over its
 * NATIVE band zoom range and nothing else — the composite model bakes each cell at its
 * own compilation scale; the compositor combines them and handles any cross-band zoom.
 * Returned in *out / *out_len (free with tile57_free). For a host to persist a per-cell
 * tile cache to disk — then feed the archives to tile57_compose_open. The metadata
 * embeds the cell's coverage (read via tile57_pmtiles_metadata). 1=ok, 0=nothing baked,
 * -1=error. */
int tile57_bake_cell_bytes(const char *path, uint8_t **out, size_t *out_len);

/* Bake `n` cells (each a .000 path; its .001.. updates auto-read) to per-cell PMTiles bytes IN
 * PARALLEL across up to `workers` threads. The engine returns BYTES only — it never writes an
 * output directory; the host writes each archive into the cache it manages. out_bytes[i] /
 * out_lens[i] receive cell i's archive (free each with tile57_free) or NULL/0 when that cell
 * produced nothing. Both arrays are caller-allocated, length n. `workers` is a MEMORY bound —
 * each concurrent bake holds a whole cell's parse+portray+raster working set, so pass a small
 * count (not a core count). Warms up the process globals internally, so concurrent baking is
 * race-free. Returns the number of cells that produced bytes, or -1 on bad args. */
int tile57_bake_cells(const char *const *paths, size_t n, uint32_t workers,
                      uint8_t **out_bytes, size_t *out_lens);

/* Walk `in_dir` for S-57 base cells (*.000) and bake each IN PARALLEL to the SAME relative path
 * under `out_dir` with a .pmtiles extension (in_dir/d1/US4CT1AA.000 -> out_dir/d1/US4CT1AA.pmtiles),
 * plus an <out>.sha content-hash sidecar; output subdirs are created as needed. The engine writes
 * and frees each archive as it goes, so the host never holds N archives in memory (peak ~ workers).
 * `in_dir` is the source ENC data; `out_dir` is the caller's OWN cache — it owns the location + the
 * layout, so distinct library consumers each keep their own chart library without clashing.
 * `workers` is a MEMORY bound — pass a small count. `progress(progress_ctx, done, total)` (or NULL)
 * fires after each cell for an import progress bar; it may be called CONCURRENTLY from worker
 * threads, so it must be thread-safe. Returns the number of cells baked, or -1. */
typedef void (*tile57_bake_progress)(void *ctx, uint32_t done, uint32_t total);
int tile57_bake_tree(const char *in_dir, const char *out_dir, uint32_t workers,
                     tile57_bake_progress progress, void *progress_ctx);

/* Read a PMTiles archive's metadata JSON blob (decompressed) into *out / *out_len
 * (free with tile57_free). A single-cell bake embeds that cell's M_COVR coverage +
 * cscl + date/name under a "coverage" key, so the composite stitcher rebuilds the
 * ownership partition without re-parsing the .000. 1=ok, 0=no metadata, -1=error. */
int tile57_pmtiles_metadata(const uint8_t *pmtiles, size_t len,
                            uint8_t **out, size_t *out_len);

/* ======================================================================== *
 * 4. Live composing (the runtime compositor)
 *
 * Holds the per-cell PMTiles (section 3) mmap'd and the ownership partition
 * resident, so any tile is composed on demand for the cost of a classify + one
 * decode/clip or a decompress. Open once, serve many, close.
 * ======================================================================== */

/* Opaque runtime-compositor handle. */
typedef struct tile57_compose_source tile57_compose_source;

/* Coverage/zoom summary filled by tile57_compose_meta_get. */
typedef struct {
    uint8_t min_zoom;
    uint8_t max_zoom;   /* deepest zoom served (native windows + one fill-up overscale zoom) */
    uint32_t cells;     /* coverage-carrying archives held */
    double west, south, east, north; /* union coverage bounds, degrees */
} tile57_compose_meta;

/* Open a resident compositor over the `n` per-cell PMTiles at `paths` (each from
 * tile57_bake_cell_bytes, on disk), mmap'd so the cell set is never fully resident.
 * `partition_path` (NULL to skip) names a partition sidecar — written by
 * tile57_compose_save_partition (the `tile57 bake` CLI emits one as partition.tpart) —
 * to load and skip the build; a missing/stale one falls back to building. Returns an
 * opaque handle (free with tile57_compose_close), or NULL on error / no
 * coverage-carrying archive. */
tile57_compose_source *tile57_compose_open(const char *const *paths, size_t n,
                                           const char *partition_path);

/* Compose the tile (z,x,y) on demand into RAW (decompressed) MLT in *out / *out_len (free with
 * tile57_free) — what a live tile server hands its HTTP layer (which gzips on the wire). Returns:
 *   1  served (bytes in *out / *out_len),
 *   2  OWNED but empty — a cell owns this ground per the ownership partition but produced nothing
 *      (transient while its per-cell bake is still running; an error state once bakes are done),
 *   0  not owned — true empty ocean (no cell owns this ground; safe to cache),
 *  -1  error. */
int tile57_compose_serve(tile57_compose_source *src, uint8_t z, uint32_t x, uint32_t y,
                         uint8_t **out, size_t *out_len);

/* Fill *out with the compositor's zoom range + union coverage bounds. */
void tile57_compose_meta_get(tile57_compose_source *src, tile57_compose_meta *out);

/* Serialize the compositor's ownership partition to the file `path` (a sidecar a later
 * tile57_compose_open can load to skip the build). Returns 1 ok, -1 on error. */
int tile57_compose_save_partition(tile57_compose_source *src, const char *path);

/* Release a compositor opened by tile57_compose_open (munmaps the archives, frees the partition). */
void tile57_compose_close(tile57_compose_source *src);

/* ======================================================================== *
 * 5. Render surface
 *
 * A general render-surface primitive: portray a VIEW of a chart (centre +
 * fractional zoom + pixel size) once and emit it as a finished PNG, a vector PDF,
 * resolved pixel-space draw calls, or a world-space semantically-tagged stream.
 * Make a surface, render it anywhere — a PNG file, a GPU chart app, a PDF printer.
 * ======================================================================== */

struct tile57_mariner; /* fwd; defined in section 6 (style) */

/* Render a VIEW of the chart — centre + fractional zoom + pixel size — to a
 * PNG through the native S-52 pixel path: the mariner settings evaluate LIVE
 * (real safety contour + category/SCAMIN/text-group gates + day/dusk/night
 * palette), catalogue symbols replay as vectors, and labels declutter over
 * the whole canvas (no tile seams). `m` NULL = canonical defaults (see
 * tile57_mariner_defaults; declared below). Physical calibration / @2x is
 * m->size_scale. Returns 0 with *out and *out_len set (free with tile57_free);
 * -1 bad handle, -2 render failure, -3 unsupported source (a baked PMTiles
 * chart carries no portrayal to render from). */
int tile57_chart_render_view(tile57_chart *chart, double lon, double lat, double zoom,
                             uint32_t width, uint32_t height,
                             const struct tile57_mariner *m,
                             uint8_t **out, size_t *out_len);

/* tile57_chart_render_view's vector twin: the SAME scene as a deterministic
 * single-page PDF (1 px = 1 pt, 72 dpi; vector fills + native strokes +
 * glyph-outline text). Same parameters, returns, and ownership. */
int tile57_chart_render_pdf(tile57_chart *chart, double lon, double lat, double zoom,
                            uint32_t width, uint32_t height,
                            const struct tile57_mariner *m,
                            uint8_t **out, size_t *out_len);

/* ---- callback Canvas: tile57_chart_render_view's GPU/vector twin ----------
 * Run the SAME view portrayal as tile57_chart_render_view, but paint every
 * resolved, flattened primitive through a table of C function pointers instead
 * of rasterising to PNG. The embedder (e.g. a GPU chart app) feeds these to
 * its own renderer. Geometry is emitted in canvas PIXEL space (y down), in
 * final paint order; colours are fully resolved for the active palette. */
typedef struct { float x, y; } tile57_point;   /* canvas pixels */
typedef struct { uint8_t r, g, b, a; } tile57_rgba;  /* resolved straight-alpha */
/* A multi-ring path: flat vertex array `pts`; ring k spans
 * [ring_starts[k], ring_starts[k+1]) (last runs to `n`). Rings closed implicitly. */
typedef struct {
    const tile57_point *pts;  uint32_t n;
    const uint32_t *ring_starts;  uint32_t ring_count;
} tile57_rings;
/* The paint table. Every callback gets `ctx` back verbatim. Calls arrive in
 * paint order (no priority key needed). */
typedef struct {
    void *ctx;
    /* Fill closed rings; even_odd != 0 selects the even-odd rule. */
    void (*fill_path)   (void *ctx, const tile57_rings *rings, tile57_rgba color, int even_odd);
    /* Stroke polylines width_px wide; dash on/off in px (0,0 = solid). */
    void (*stroke_path) (void *ctx, const tile57_rings *rings, float width_px,
                         float dash_on, float dash_off, tile57_rgba color);
    /* Fill rings with a repeating RGBA8 pattern cell (pw*ph*4 bytes). */
    void (*fill_pattern)(void *ctx, const tile57_rings *rings, uint32_t pw, uint32_t ph,
                         const uint8_t *rgba);
    /* Draw a shaped label as flattened outline rings (px), optional halo
     * (halo.a == 0 => none). */
    void (*draw_glyphs) (void *ctx, const tile57_rings *outline, tile57_rgba color,
                         tile57_rgba halo, float halo_px);
} tile57_canvas_cb;
/* Returns (INVERTED, matches tile57_chart_render_view): 0 ok / -1 bad handle /
 * -2 render failure / -3 unsupported source. Same threading rules as the rest
 * of a tile57_chart (serialise per handle). */
int tile57_chart_render_view_cb(tile57_chart *chart, double lon, double lat, double zoom,
                                uint32_t width, uint32_t height,
                                const struct tile57_mariner *m,
                                const tile57_canvas_cb *canvas);

/* ---- world-space Surface callback: the GPU vector twin ----------------------
 * tile57_chart_render_surface_cb runs the SAME view portrayal as
 * tile57_chart_render_view_cb but emits a WORLD-SPACE, semantically TAGGED
 * stream rather than resolved pixels: area/line geometry in web-mercator [0,1]
 * (y down); point symbols and text as a WORLD anchor + a LOCAL outline in
 * reference px (a constant screen size); every draw call tagged with its
 * feature's S-57 class and SCAMIN. A GPU host applies its own view transform,
 * pins symbols/text at the anchor, and culls by SCAMIN per frame — so pan and
 * zoom re-portray NOTHING. Works for a baked bundle (tile replay) or a live
 * cell (full S-52 portrayal). */
typedef struct { double x, y; } tile57_world_point;  /* web-mercator [0,1], y down */
typedef struct { float  x, y; } tile57_local_point;  /* anchor-relative reference px */

typedef struct {
    const tile57_world_point *pts;  uint32_t n;
    const uint32_t *ring_starts;    uint32_t ring_count;
} tile57_world_rings;
typedef struct {
    const tile57_local_point *pts;  uint32_t n;
    const uint32_t *ring_starts;    uint32_t ring_count;
} tile57_local_rings;

/* The feature the following draw calls belong to. `cls` is the S-57 object-class
 * acronym (NUL-terminated; "" if none); `scamin` is the SCAMIN 1:N denominator
 * (<= 0 => always visible); `plane` is the S-52 draw priority (paint hint). */
typedef struct {
    const char *cls;
    int64_t scamin;
    int32_t plane;
} tile57_feature;

/* Draw table. Pointers are valid only for the duration of the call; ctx is
 * passed back verbatim. Calls arrive in Surface emission order (the host owns
 * final paint order + label collision). */
typedef struct {
    void *ctx;
    /* Filled area (world). even_odd != 0 selects the even-odd rule. */
    void (*fill_area)  (void *ctx, const tile57_feature *f, const tile57_world_rings *rings, tile57_rgba color, int even_odd);
    /* Stroked line (world); width in reference px, dash on/off px (0,0 solid). */
    void (*stroke_line)(void *ctx, const tile57_feature *f, const tile57_world_rings *lines, float width_px, float dash_on, float dash_off, tile57_rgba color);
    /* Point symbol: world anchor + local outline (px). even_odd for compound
     * glyphs; stroke_w > 0 => the rings are a polyline stroked stroke_w px wide. */
    void (*draw_symbol)(void *ctx, const tile57_feature *f, tile57_world_point anchor, const tile57_local_rings *rings, tile57_rgba color, int even_odd, float stroke_w);
    /* Text: world anchor + local glyph outlines (px, even-odd) + halo
     * (halo.a == 0 => none). */
    void (*draw_text)  (void *ctx, const tile57_feature *f, tile57_world_point anchor, const tile57_local_rings *glyphs, tile57_rgba color, tile57_rgba halo, float halo_px);
    /* Point symbol as a sprite: symbol name (ptr,len) to look up in the atlas
     * (tile57_bake_assets sprite_png/json), world anchor, rotation (deg), and the
     * symbol's un-rotated half-extent in reference px. Draw the atlas cell as a
     * quad of that half-size, centred on the anchor. NULL => symbols tessellate
     * via draw_symbol instead. (ABI-appended after the original vtable.) */
    void (*draw_sprite)(void *ctx, const tile57_feature *f, const char *name, size_t name_len, tile57_world_point anchor, float rot_deg, float half_w_px, float half_h_px);
    /* Area fill pattern: pattern name (ptr,len) to look up in the atlas ("pat:"
     * prefix) + the fill rings (world). Tile the cell across the polygon at a
     * constant screen size. NULL => flat tint. */
    void (*draw_pattern)(void *ctx, const tile57_feature *f, const char *name, size_t name_len, const tile57_world_rings *rings);
    /* Text as a STRING for the host's SDF glyph atlas (tile57_bake_glyph_sdf):
     * world anchor + the anchor-relative baseline-left origin in px (ox,oy, with
     * alignment already applied) + UTF-8 text (ptr,len) + the glyph pixel size +
     * colour + halo. The host lays the string out from its glyph metrics and draws
     * SDF quads. NULL => text tessellates via draw_text. Must be the LAST field. */
    void (*draw_text_str)(void *ctx, const tile57_feature *f, tile57_world_point anchor, float ox_px, float oy_px, const char *text, size_t text_len, float size_px, tile57_rgba color, tile57_rgba halo);
} tile57_surface_cb;

/* Returns 0 ok / -1 bad handle / -2 render failure / -3 unsupported source. */
int tile57_chart_render_surface_cb(tile57_chart *chart, double lon, double lat, double zoom,
                                   uint32_t width, uint32_t height,
                                   const struct tile57_mariner *m,
                                   const tile57_surface_cb *surface);

/* ======================================================================== *
 * 6. Style + portrayal assets
 *
 * tile57 ships tile generation AND style generation together. tile57_build_style
 * turns a MapLibre style template + the mariner's S-52 display options + the S-52
 * colortables into a concrete style JSON, client-side; tile57_bake_assets produces
 * the colour tables, line styles, and sprite / pattern / glyph atlases the style
 * references.
 * ======================================================================== */

/* ---- portrayal assets ---------------------------------------------------- */

/* All portrayal assets in memory, from the library's embedded catalogue
 * (catalog_dir NULL/"") or an on-disk one. Pairs with tile57_build_style + the
 * composed tiles for a complete renderable chart. Returns 1 with *out filled (free
 * with tile57_assets_free), 0 on error. */
typedef struct {
    uint8_t *colortables;  size_t colortables_len;
    uint8_t *linestyles;   size_t linestyles_len;
    uint8_t *sprite_json;  size_t sprite_json_len;   uint8_t *sprite_png;  size_t sprite_png_len;
    uint8_t *pattern_json; size_t pattern_json_len;  uint8_t *pattern_png; size_t pattern_png_len;
} tile57_assets;
int  tile57_bake_assets(const char *catalog_dir, tile57_assets *out);
/* Like tile57_bake_assets but sprite_json/sprite_png carry the MapLibre sprite-mln
 * atlas (pivot-centred cells + {name:{x,y,width,height,pixelRatio}} JSON); other
 * fields are NULL. Free with tile57_assets_free. 1=ok, 0=error. */
int  tile57_bake_sprite_mln(const char *catalog_dir, tile57_assets *out);
/* SDF glyph atlas for GPU text: sprite_png is the RGBA signed-distance-field atlas
 * of the label font; sprite_json is {"em_px","pad","glyphs":{codepoint:[u0,v0,u1,
 * v1,off_x,off_y,w,h,advance]}} with the quad geometry in EM units (multiply by the
 * text pixel size). A host draws each glyph as a textured quad sampling the SDF.
 * Only sprite_* filled. Free with tile57_assets_free. 1=ok, 0=error. */
int  tile57_bake_glyph_sdf(tile57_assets *out);
void tile57_assets_free(tile57_assets *out);

/* ---- chart-style generation ---------------------------------------------
 *
 * tile57_build_style patches the mariner-driven parts of the template (depth
 * shading, sounding/danger symbol swaps, contour-label units, the per-scheme
 * recolour) and AND-s the display filters (category, band, boundary/point style,
 * date validity, text groups, …) onto every source:"chart" layer. The template +
 * colortables are produced by the engine's asset generator; the host fills
 * tile57_mariner from its UI. */

typedef enum { TILE57_SCHEME_DAY=0, TILE57_SCHEME_DUSK=1, TILE57_SCHEME_NIGHT=2 } tile57_scheme;
typedef enum { TILE57_DEPTH_METERS=0, TILE57_DEPTH_FEET=1 } tile57_depth_unit;
typedef enum { TILE57_BOUNDARY_SYMBOLIZED=0, TILE57_BOUNDARY_PLAIN=1 } tile57_boundary_style;

typedef struct tile57_mariner {
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
    bool scamin_filter_gate; /* gate SCAMIN with a live client-driven filter instead of
                         * per-value bucket layers — one *_scamin layer per render-type
                         * (no minzoom buckets). The client rewrites the SCAMIN clause on
                         * boundary crossings. NOT an S-52 setting.
                         * tile57_mariner_defaults sets false (per-value buckets). */
    bool show_overscale; /* S-52 §10.1.10 overscale indication: the AP(OVERSC01)
                         * vertical-line hatch over regions displayed finer than their
                         * compilation scale (drives the `overscale` layer's visibility).
                         * tile57_mariner_defaults sets true. */
} tile57_mariner;

/* Build a MapLibre style JSON from a template + mariner settings + S-52 colortables.
 * enabled_bands: NULL = no band filter (show all); else only features whose `band`
 * rank is in the array (count entries) are shown.
 * scamin: the distinct SCAMIN denominators present in the source (e.g. from
 *   tile57_chart_scamin / the TileJSON). When non-NULL with scamin_count>0 the
 *   `_scamin` source-layers are split into one per-value bucket layer with a native
 *   fractional minzoom = scaminDisplayZoom(value, scamin_lat). NULL / count 0 -> the
 *   `_scamin` layers stay a single ungated layer (features render, but SCAMIN does
 *   not gate by value).
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
 *   tile57_style_template(scheme, "http://host/{z}/{x}/{y}", NULL,NULL,0,0,0, &t,&tn);
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
 *   minzoom: the chart source's tile floor, emitted verbatim — pass the archive's
 *            real minzoom (0 = tiles from z0; MapLibre never requests tiles below
 *            a source's minzoom, so an inflated floor blanks every lower zoom).
 *   maxzoom: 0 -> engine default.
 *   tile_encoding: the chart source's tile encoding (a tile57_tile_type, from
 *            chart_info.tile_type). TILE57_TILE_TYPE_MLT emits "encoding":"mlt" on
 *            the source so maplibre-gl >= 5.12 decodes MLT natively; 0 /
 *            TILE57_TILE_TYPE_MVT emits nothing (the MapLibre default). The hint
 *            survives tile57_build_style / tile57_style_diff.
 * Returns 1 with out/out_len set (free with tile57_free), 0 on error. */
int tile57_style_template(tile57_scheme scheme, const char *source_tiles,
                          const char *sprite, const char *glyphs,
                          uint32_t minzoom, uint32_t maxzoom,
                          uint8_t tile_encoding,
                          uint8_t **out, size_t *out_len);

/* Fill *m with the canonical default mariner settings (so a host needn't hardcode
 * them). date_view is set to "" (today). */
void tile57_mariner_defaults(tile57_mariner *m);

/* ======================================================================== *
 * 7. Util / catalogue / debug
 * ======================================================================== */

/* Populate the process-global read-only registries (the S-100 feature catalogue and
 * the complex-linestyle table) on the calling thread. Both are idempotent lazy-init
 * and thereafter read-only. Call this ONCE on your main thread before opening or
 * baking cells from worker threads, so those globals are fully populated first and
 * concurrent bake/render is race-free (the allocator is thread-safe and the portrayal
 * context is thread-local). Cheap and safe to call more than once. */
void tile57_warmup(void);

/* Free ANY buffer the engine returned (tiles, style JSON, the scamin array,
 * colortables, atlases, …), passing the same length. The universal free. */
void tile57_free(void *ptr, size_t len);

/* Decode a CATALOG.031 exchange-set catalogue (raw bytes) into a JSON array
 * of its CATD entries:
 *   [{"file":"US5MD1MC/US5MD1MC.000","longName":"Annapolis Harbor",
 *     "impl":"BIN","bbox":[west,south,east,north]}, ...]
 * `file` is the recorded path with separators normalised to '/'; `longName`
 * is LFIL (the human chart title; empty when absent); `impl` is BIN/ASC/TXT;
 * `bbox` is omitted when SLAT/WLON/NLAT/ELON are not all present (aux files).
 * Not chart-scoped: the catalogue describes an exchange set, not an open
 * chart. Returns 1 with *out / *out_len holding the JSON (free with
 * tile57_free); 0 if the file holds no CATD records; -1 on parse error. */
int tile57_catalog_entries(const uint8_t *catalog_031, size_t len,
                           uint8_t **out, size_t *out_len);

/* Bake the ownership-partition DEBUG tiles from an ENC_ROOT (on-disk path) into a
 * single PMTiles at out_path: the composited ownership faces (which cell renders which
 * ground at each band), one polygon per owning cell tagged with the properties
 * cell/cscl/band/tier/oi/color, and NO portrayed chart content — for building a
 * partition-debug UI. band < 0 emits the band GOVERNING each zoom (the natural view);
 * 0..5 (berthing..overview) emits one band's own map at every zoom. minzoom/maxzoom
 * bound the tiles (harbor-level detail needs maxzoom >= 13; coarser bands are much
 * cheaper). out_cell_count is optional. Returns 1=ok, 0=nothing covered, -1=error. */
int tile57_bake_partition_debug(const char *enc_root, const char *out_path,
                                uint8_t minzoom, uint8_t maxzoom, int8_t band,
                                uint32_t *out_cell_count);

#ifdef __cplusplus
}
#endif

#endif /* TILE57_H */
