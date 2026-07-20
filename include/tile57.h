/* tile57.h — public C ABI for libtile57.
 *
 * libtile57 is an embeddable nautical-chart engine. It reads IHO S-57 ENC
 * charts (each one a *cell*, in the spec's vocabulary), bakes them to per-chart
 * PMTiles archives, serves composed vector tiles from
 * those archives on demand, renders finished charts to pixels / PDF / a callback
 * surface, and generates the matching S-52 MapLibre style + portrayal assets.
 *
 * Everything is BAKE, THEN COMPOSE (or bake, then render): source charts bake
 * once to per-chart archives; every output — a tile, a PNG, a PDF, a callback
 * stream — is produced from baked archives. The header is organised the same
 * way:
 *
 *   3. BAKE     ENC source data in, per-chart PMTiles out. Each chart bakes to
 *               its own archive at its own compilation scale, with its M_COVR
 *               coverage + scale embedded in the archive metadata. This is the
 *               import step; the section also carries the raw-source readers
 *               (chart inventory, feature extraction, exchange-set catalogue).
 *
 *   4. RENDER   a `tile57_chart` handle opens ONE baked archive (mmap'd from a
 *               path, or copied from bytes) and answers for it with NO
 *               composition: metadata (info / scamin / coverage), its stored
 *               tiles verbatim (tile57_chart_tile — the primitive for writing your
 *               own compositor), the cursor pick (query), and view outputs
 *               (png / pdf / canvas / surface).
 *
 *   5. COMPOSE  a `tile57_compose` handle stitches MANY open charts through the
 *               ownership partition and offers the SAME output set,
 *               composed: tile (what a live tile server hands its HTTP layer),
 *               png, pdf, canvas, surface, query.
 *
 * Section 6 (style + portrayal assets) turns the mariner's S-52 display options
 * into a concrete MapLibre style JSON plus the colortables / sprite / pattern /
 * glyph atlases it references. The composed tiles are MapLibre Tiles (MLT);
 * maplibre-gl >= 5.12 decodes them natively via the vector source `encoding`
 * option. The ABI is renderer-agnostic.
 *
 * Errors: every call that can fail returns a tile57_status (TILE57_OK = 0) and takes
 *   an optional caller-owned tile57_error* it fills on failure — see section 2.
 *   Out-parameters are always defined on return: the result on TILE57_OK,
 *   NULL/0 otherwise. "Nothing produced" is NOT a failure — a call that finds
 *   nothing (a chart that bakes no tiles, a tile nobody owns, a chart with no
 *   SCAMIN values) returns TILE57_OK with a NULL/zero out.
 *
 * Lifetime: a handle must OUTLIVE every borrower still holding it: a compositor
 *   borrows its charts (close the compositor first, then the charts), and in
 *   the MapLibre hosts a long-lived source captures the handle and intentionally
 *   never closes it before process exit (closing first would be a use-after-free
 *   during teardown). A path-opened chart mmaps its file — the file must stay in
 *   place while the chart is open.
 *
 * Threading: no handle is internally synchronized — do not call into the SAME
 *   handle from multiple threads concurrently (caches are mutated without a
 *   lock). A compositor reads through its charts, so while it serves, do not
 *   call those charts' own methods from other threads. Distinct handles are
 *   independent.
 *
 * Memory: calls that return bytes allocate *out; release it with
 *   tile57_free(ptr) — buffers are length-prefixed at allocation, so the
 *   pointer is all it needs. All pointers are POD across the ABI.
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

/* Library version. tile57_version() returns the string form, e.g. "0.3.0". */
#define TILE57_VERSION_MAJOR 0
#define TILE57_VERSION_MINOR 3
#define TILE57_VERSION_PATCH 0
const char *tile57_version(void);

/* ======================================================================== *
 * 2. Errors
 *
 * A call that can fail returns a tile57_status; TILE57_OK (0) is success and every
 * other value is a failure with a coarse cause. Results come back through
 * out-parameters, which are always defined on return (NULL/0 on failure).
 *
 * tile57_status_str() gives a static, human-readable string for a status (the
 * strerror pattern). Where the specific cause is worth carrying — which path,
 * which parse failure — the call also takes an optional tile57_error*: pass
 * NULL to ignore it, or a caller-owned struct (a stack local is fine) the call
 * fills with the status + a message on failure and leaves untouched on
 * success. There is no allocation and nothing to free.
 * ======================================================================== */

typedef enum {
    TILE57_OK = 0,          /* success */
    TILE57_ERR_BADARG,      /* a NULL or out-of-range argument */
    TILE57_ERR_IO,          /* a file/directory could not be opened, read, or written */
    TILE57_ERR_PARSE,       /* malformed input (S-57 chart, PMTiles, partition, JSON) */
    TILE57_ERR_NOMEM,       /* an allocation failed */
    TILE57_ERR_UNSUPPORTED, /* valid but unusable input (e.g. no coverage-carrying chart) */
    TILE57_ERR_RENDER,      /* tile generation or rendering failed */
    TILE57_ERR_INTERNAL,    /* an unexpected engine failure (please report) */
} tile57_status;

/* A static, human-readable string for a status. Never NULL, never freed. */
const char *tile57_status_str(tile57_status status);

#define TILE57_ERROR_MSG_MAX 256
typedef struct {
    tile57_status status;
    char message[TILE57_ERROR_MSG_MAX]; /* NUL-terminated; "" when no detail */
} tile57_error;

/* ======================================================================== *
 * 3. Bake
 *
 * ENC source data in, per-chart PMTiles archives out. The composite model bakes
 * each chart to its own archive over its NATIVE band zoom range at its own
 * compilation scale; the compositor (section 5) stitches them on demand, so
 * baking never composes and re-importing one chart never re-bakes the rest.
 *
 * A per-chart archive's metadata embeds the chart's M_COVR coverage, compilation
 * scale, and identity — everything a chart handle or compositor needs to place
 * it, with no .000 re-parse (read it back with tile57_pmtiles_metadata).
 *
 * Every emitted vector-tile feature carries the per-feature pick/inspector
 * properties used by the S-52 §10.8 pick report: `class` (object-class
 * acronym), `cell` (source chart name), and `s57` (a JSON object of the
 * feature's full S-57 attribute set, acronym -> value). tile57_chart_query and a
 * host inspector read these back.
 *
 * The section also carries the raw-source readers a host's import UI needs:
 * the chart inventory of a path, GeoJSON feature extraction, and the
 * exchange-set catalogue decode.
 * ======================================================================== */

/* ---- reading ENC source data --------------------------------------------- */

/* The per-chart metadata of the S-57 data at `path` — ONE chart (a .000 file,
 * with its .001.. update chain auto-read from the same directory) or a whole
 * ENC_ROOT directory — as a JSON array, one object per chart:
 *   [{"name":"US5MD1MC","scale":12000,"edition":"13","update":"3",
 *     "issueDate":"20240105","agency":550,"bbox":[west,south,east,north]}, ...]
 * `name` is the DSNM stem; `scale` is DSPM CSCL; edition/update/issueDate/
 * agency are DSID EDTN/UPDN/ISDT/AGEN after the update chain is applied;
 * `bbox` is omitted when none parses. For a host's chart-database scan.
 * TILE57_OK with the JSON in *out / *out_len (free with tile57_free). */
tile57_status tile57_enc_charts(const char *path, uint8_t **out, size_t *out_len,
                               tile57_error *err);

/* The features of the S-57 data at `path` (one chart or a whole ENC_ROOT) for
 * the given object classes (comma-separated acronyms, e.g. "DEPARE,DRGARE") as
 * a GeoJSON FeatureCollection: geometry in lon/lat (Polygon rings
 * largest-first, MultiPoint with depths for soundings, LineString/Point as
 * encoded), properties = {"class":"DEPARE", ...the feature's full S-57
 * acronym->value attribute map}. Parsed without portrayal; a whole-ENC_ROOT
 * extraction walks every chart — the caller owns that cost. TILE57_OK with the
 * JSON in *out / *out_len (free with tile57_free); NULL/0 when nothing
 * matched. */
tile57_status tile57_enc_features(const char *path, const char *classes,
                                  uint8_t **out, size_t *out_len,
                                  tile57_error *err);

/* tile57_enc_features over in-memory base .000 bytes (read from a zip member,
 * say) instead of a path. No update chain is applied. */
tile57_status tile57_enc_features_bytes(const uint8_t *base, size_t len,
                                        const char *classes,
                                        uint8_t **out, size_t *out_len,
                                        tile57_error *err);

/* Decode a CATALOG.031 exchange-set catalogue (raw bytes) into a JSON array of
 * its CATD entries:
 *   [{"file":"US5MD1MC/US5MD1MC.000","longName":"Annapolis Harbor",
 *     "impl":"BIN","bbox":[west,south,east,north]}, ...]
 * `file` is the recorded path with separators normalised to '/'; `longName` is
 * LFIL (the human chart title; empty when absent); `impl` is BIN/ASC/TXT;
 * `bbox` is omitted when SLAT/WLON/NLAT/ELON are not all present (aux files).
 * TILE57_OK with the JSON in *out / *out_len (free with tile57_free); NULL/0
 * when the file holds no CATD records. */
tile57_status tile57_enc_catalog(const uint8_t *catalog_031, size_t len,
                                 uint8_t **out, size_t *out_len,
                                 tile57_error *err);

/* ---- baking charts to per-chart archives ---------------------------------- */

/* Bake ONE chart (+ its .001.. updates, read from disk) to PMTiles bytes over
 * its NATIVE band zoom range and nothing else. Returned in *out / *out_len
 * (free with tile57_free); NULL/0 when the chart produced no tiles. For a host
 * persisting a per-chart tile cache to disk — open the archives as charts
 * (section 4) and compose them (section 5). */
tile57_status tile57_bake_chart_bytes(const char *path, uint8_t **out, size_t *out_len,
                                     tile57_error *err);

/* Bake `n` charts (each a .000 path; updates auto-read) to per-chart PMTiles
 * bytes IN PARALLEL across up to `workers` threads. The engine returns BYTES
 * only — it never writes an output directory; the host writes each archive
 * into the cache it manages. out_bytes[i] / out_lens[i] receive chart i's
 * archive (free each with tile57_free) or NULL/0 when that chart produced
 * nothing; both arrays are caller-allocated, length n. *out_baked (NULL to
 * ignore) receives the number of charts that produced bytes. `workers` is a
 * MEMORY bound — each concurrent bake holds a whole chart's
 * parse+portray+raster working set, so pass a small count (not a core count).
 * Warms up the process globals internally, so concurrent baking is race-free. */
tile57_status tile57_bake_charts(const char *const *paths, size_t n, uint32_t workers,
                                uint8_t **out_bytes, size_t *out_lens,
                                size_t *out_baked, tile57_error *err);

/* Progress callback for tile57_bake_tree: fires after each chart with (done,
 * total). May be called CONCURRENTLY from worker threads — make it
 * thread-safe.
 *
 * Return true to continue, false to CANCEL the bake. Cancellation is at chart
 * granularity: no new chart is started, but the charts already in flight run to
 * completion, so the call returns within roughly one chart's bake time (not
 * instantly). A cancelled bake is TILE57_OK — not a failure — with *out_baked
 * counting the charts it finished before stopping; the archives it did write are
 * complete and valid, so a later re-run resumes where it left off (the
 * incremental skip below sees them). A host with no cancel just returns true. */
typedef bool (*tile57_bake_progress)(void *ctx, uint32_t done, uint32_t total);

/* Walk `in_dir` for S-57 base charts (*.000) and bake each IN PARALLEL to the
 * SAME relative path under `out_dir` with a .pmtiles extension
 * (in_dir/d1/US4CT1AA.000 -> out_dir/d1/US4CT1AA.pmtiles), plus an <out>.sha
 * content-hash sidecar; output subdirs are created as needed. The engine
 * writes and frees each archive as it goes, so the host never holds N archives
 * in memory (peak ~ workers). INCREMENTAL: a chart whose mirrored archive is
 * already at least as new as its whole input (.000 + update chain) is skipped,
 * so a re-run over an unchanged tree bakes nothing — *out_baked (NULL to
 * ignore) counts the charts baked THIS run, and 0 over a warm cache is success,
 * not failure. `in_dir` is the source ENC data; `out_dir` is the caller's OWN
 * cache — it owns the location + layout, so distinct library consumers each
 * keep their own chart library without clashing. `workers` is a MEMORY bound —
 * pass a small count. `progress` (NULL to skip) fires per chart and can CANCEL
 * the bake by returning false — see tile57_bake_progress. An unreadable `in_dir`
 * is TILE57_ERR_IO. */
tile57_status tile57_bake_tree(const char *in_dir, const char *out_dir, uint32_t workers,
                               tile57_bake_progress progress, void *progress_ctx,
                               uint32_t *out_baked, tile57_error *err);

/* Read a PMTiles archive's metadata JSON blob (decompressed) into *out /
 * *out_len (free with tile57_free); NULL/0 when the archive carries none. A
 * per-chart bake embeds the chart's M_COVR coverage + cscl + date/name under a
 * "coverage" key. */
tile57_status tile57_pmtiles_metadata(const uint8_t *pmtiles, size_t len,
                                      uint8_t **out, size_t *out_len,
                                      tile57_error *err);

/* Bake the ownership-partition DEBUG tiles from an ENC_ROOT (on-disk path)
 * into a single PMTiles at out_path: the composited ownership faces (which
 * chart renders which ground at each band), one polygon per owning chart tagged
 * with the properties cell/cscl/band/tier/oi/color, and NO portrayed chart
 * content — for building a partition-debug UI. band < 0 emits the band
 * GOVERNING each zoom (the natural view); 0..5 (berthing..overview) emits one
 * band's own map at every zoom. minzoom/maxzoom bound the tiles (harbor-level
 * detail needs maxzoom >= 13; coarser bands are much cheaper). TILE57_OK with
 * *out_chart_count (NULL to ignore) = the covered-chart count; 0 with no file
 * written when nothing is covered. */
tile57_status tile57_bake_partition_debug(const char *enc_root, const char *out_path,
                                          uint8_t minzoom, uint8_t maxzoom, int8_t band,
                                          uint32_t *out_chart_count, tile57_error *err);

/* ======================================================================== *
 * 4. Render
 *
 * A `tile57_chart` is ONE baked PMTiles archive, opened for metadata and
 * output — with NO composition (the compositor, section 5, offers the same
 * outputs across many charts). Open it from a path (mmap'd — a whole chart
 * library can be open without being resident) or from bytes (copied). It
 * reports the archive's zoom range / bounds / tile encoding, the coverage +
 * compilation scale the bake embedded, and the live SCAMIN manifest; hands
 * back its stored tiles verbatim (the primitive an embedder's own compositor
 * consumes); answers the S-52 cursor pick; and renders any VIEW (centre +
 * fractional zoom + pixel size) as a finished PNG, a vector PDF, resolved
 * pixel-space draw calls, or a world-space semantically-tagged stream.
 *
 * Rendering REPLAYS baked tiles through the native S-52 pixel path: one whole
 * scene across every covering tile, labels decluttered over the full canvas
 * (no tile boundaries), symbols replayed as vectors from the catalogue. The
 * mariner's live-swappable settings — colour scheme, safety contour
 * danger/sounding swaps, category/SCAMIN/text gates, size scale — re-evaluate
 * at render time; the rest of the portrayal context was fixed at bake time.
 * ======================================================================== */

/* Opaque chart handle: one open baked archive. */
typedef struct tile57_chart tile57_chart;

/* Open a baked PMTiles archive from a file path, mmap'd (never fully
 * resident). The file must stay in place while the chart is open. TILE57_OK
 * with *out set (close with tile57_chart_close). */
tile57_status tile57_chart_open(const char *path, tile57_chart **out, tile57_error *err);

/* Open a baked PMTiles archive from in-memory bytes (e.g. straight from
 * tile57_bake_chart_bytes, before any file exists). Bytes are copied. */
tile57_status tile57_chart_open_bytes(const uint8_t *pmtiles, size_t len,
                                tile57_chart **out, tile57_error *err);

/* Vector-tile encodings an archive can store (reported in
 * tile57_info.tile_type; the engine bakes MLT). */
typedef enum {
    TILE57_TILE_TYPE_MVT = 1, /* Mapbox Vector Tile */
    TILE57_TILE_TYPE_MLT = 2, /* MapLibre Tile (the bake default) */
} tile57_tile_type;

/* Fixed chart metadata. Bounds/anchor validity are flagged (false -> those
 * fields are 0). tile_type is the archive's stored encoding (a
 * tile57_tile_type); a host passes it to tile57_style_template so the renderer
 * decodes the tiles correctly. native_scale is the compilation scale (1:N) the
 * bake embedded in the archive metadata; 0 = unknown (a composed/foreign
 * archive — derive the scale from the zoom band instead). */
typedef struct {
    uint8_t  min_zoom, max_zoom;
    uint32_t bands;                                       /* bitmask of navigational bands present */
    bool     has_bounds; double west, south, east, north;
    bool     has_anchor; double anchor_lat, anchor_lon, anchor_zoom;
    uint8_t  tile_type;                                   /* tile57_tile_type */
    int32_t  native_scale;
} tile57_info;
void tile57_chart_get_info(tile57_chart *chart, tile57_info *out);

/* The distinct SCAMIN denominators present in the chart (read from the archive
 * metadata), ascending — the host publishes these so its style builds one
 * native fractional-minzoom bucket layer per value (features honour their 1:N
 * min-display-scale at zero per-zoom cost). TILE57_OK with *out pointing at
 * *out_len int32 values, or NULL/0 when the chart has none. Free *out with
 * tile57_free. */
tile57_status tile57_chart_scamin(tile57_chart *chart, int32_t **out, size_t *out_len,
                            tile57_error *err);

/* The chart's M_COVR(CATCOV=1) data-coverage polygons, from the coverage the
 * bake embedded in the archive metadata — the real coverage a host reports so
 * a quilt fills gaps to coarser charts (vs. the bounding box). ring() is called
 * once per polygon with its exterior ring as `npts` interleaved lon,lat
 * doubles (valid only during the call). A chart whose archive embeds no
 * coverage (a composed/foreign archive) is TILE57_OK with no calls. */
typedef struct {
    void *ctx;
    void (*ring)(void *ctx, const double *lonlat, size_t npts);
} tile57_coverage_cb;
tile57_status tile57_chart_coverage(tile57_chart *chart, const tile57_coverage_cb *cb,
                              tile57_error *err);

/* The chart's own stored tile at (z,x,y), decompressed (MLT or MVT per
 * tile57_info.tile_type), with NO composition — the per-archive primitive for
 * an embedder writing its own compositor. TILE57_OK with the bytes in *out /
 * *out_len (free with tile57_free); NULL/0 when the archive has no tile
 * there. */
tile57_status tile57_chart_tile(tile57_chart *chart, uint8_t z, uint32_t x, uint32_t y,
                          uint8_t **out, size_t *out_len, tile57_error *err);

/* Cursor object-query (S-52 §10.8 pick): feature() is invoked once per feature
 * the point (lon,lat) falls in — area point-in-polygon, line/point within a
 * small radius — with the S-57 object-class acronym, the attribute JSON
 * (acronym -> value), and the source chart name. Pointers are valid only for
 * the duration of the call. */
typedef struct {
    void *ctx;
    void (*feature)(void *ctx, const char *cls, size_t cls_len,
                    const char *s57, size_t s57_len,
                    const char *chart, size_t chart_len);
} tile57_query_cb;
/* `zoom` is the current view's web-mercator zoom: the query reads the tile at
 * that zoom, so it reports the features actually DISPLAYED there
 * (SCAMIN-bucketed) and the pick tolerance tracks on-screen distance. */
tile57_status tile57_chart_query(tile57_chart *chart, double lon, double lat, double zoom,
                           const tile57_query_cb *cb, tile57_error *err);

/* ---- mariner settings ------------------------------------------------------
 *
 * The mariner's S-52 display options: shared by the view renderers below
 * (evaluated live per render) and the style builders in section 6 (baked into
 * the style JSON). Fill it from your UI, or start from
 * tile57_mariner_defaults. */

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
    bool ignore_scamin; /* host debug toggle: drop SCAMIN scale-gating so every
                         * feature shows in-band (the *_scamin layers become a
                         * single ungated layer). NOT an S-52 setting. Default false. */
    double size_scale;  /* physical-scale multiplier applied to icon-size /
                         * line-width / text-size (@2x, physical calibration).
                         * NOT an S-52 setting. 1.0 = catalogue sizes verbatim. */
    const int32_t *viewing_groups_off; /* S-52 §14.5 fine-grained viewing-group control:
                         * a DENY-LIST of the raw `vg` ids the mariner turned OFF. The
                         * pointee must outlive the call it is passed to. NULL/len 0 ->
                         * every viewing group shown. */
    uint32_t viewing_groups_off_len;
    bool scamin_filter_gate; /* gate SCAMIN with a live client-driven filter instead of
                         * per-value bucket layers — one *_scamin layer per render-type
                         * (no minzoom buckets); the client rewrites the SCAMIN clause on
                         * boundary crossings. NOT an S-52 setting. Default false. */
    bool show_overscale; /* S-52 §10.1.10 overscale indication: the AP(OVERSC01)
                         * vertical-line hatch over regions displayed finer than their
                         * compilation scale (drives the `overscale` layer's
                         * visibility). Default true. */
    double text_size_scale;    /* extra size multiplier for TEXT labels, on top of
                         * size_scale. The engine scales the glyph and its collision
                         * box together, so enlarged labels still declutter correctly.
                         * NOT an S-52 setting. Appended for ABI-append-safety; 0 (an
                         * un-set field) is read as 1.0 = no extra scale. */
    double sounding_size_scale; /* extra size multiplier for SOUNDINGS, on top of
                         * size_scale. Scales each digit AND its spacing together
                         * (soundings arrive as one sprite per digit, so a host cannot
                         * do this itself). NOT an S-52 setting. Appended for
                         * ABI-append-safety; 0 is read as 1.0. */
    uint8_t soundings; /* spot soundings, INDEPENDENT of the display category.
                         * S-52 files SOUNDG under OTHER, but every ECDIS gives
                         * soundings their own switch and the everyday setting is
                         * STANDARD + soundings ON. Without this a host has to enable
                         * the whole OTHER category just to see soundings, and takes
                         * the seabed, the cables and the rest of the low-priority
                         * clutter with it.
                         *   0 = follow the display category (the old behaviour)
                         *   1 = show soundings whatever the category says
                         *   2 = hide soundings whatever the category says
                         * Appended for ABI-append-safety: a zeroed struct means 0. */
    double device_scale; /* device pixels per reference pixel — the HiDPI framebuffer
                         * density the SURFACE paths are drawn at (2.0 on a Retina
                         * backing store). NOT an S-52 setting, and NOT a mariner
                         * preference: it describes the DISPLAY, where size_scale
                         * describes the mariner's taste. The two multiply.
                         *
                         * State it whenever you draw at anything but 1x. The surface
                         * callbacks hand you reference-px sizes for text and symbols
                         * and let YOU draw them; if you then draw at 2x without saying
                         * so, the engine has sized every label's collision box for
                         * glyphs half the size you actually paint, and a view it
                         * decluttered cleanly arrives overlapping. Setting this sizes
                         * the glyph AND its collision box in the units you draw in.
                         * Do NOT fold the density into size_scale instead: that also
                         * works, but it conflates the display with the mariner's own
                         * size preference and the two need to stay separable.
                         *
                         * The pixel outputs (_png / _pdf / _canvas) IGNORE this: the
                         * engine rasterizes those itself, so the density is already in
                         * the width/height asked for.
                         * Appended for ABI-append-safety; 0 is read as 1.0. */
} tile57_mariner;

/* Fill *m with the canonical default mariner settings (so a host needn't
 * hardcode them). date_view is set to "" (today). */
void tile57_mariner_defaults(tile57_mariner *m);

/* ---- view renders ----------------------------------------------------------
 *
 * All four render the SAME scene for a VIEW — centre (lon, lat) + fractional
 * zoom + pixel size — and differ only in what they emit. `m` NULL = canonical
 * defaults. width/height must be 1..16384; larger or zero is
 * TILE57_ERR_BADARG. */

/* The view as a PNG, in *out / *out_len (free with tile57_free). */
tile57_status tile57_chart_png(tile57_chart *chart, double lon, double lat, double zoom,
                         uint32_t width, uint32_t height,
                         const tile57_mariner *m,
                         uint8_t **out, size_t *out_len, tile57_error *err);

/* The view as a deterministic single-page vector PDF (1 px = 1 pt, 72 dpi;
 * vector fills + native strokes + glyph-outline text), in *out / *out_len
 * (free with tile57_free). */
tile57_status tile57_chart_pdf(tile57_chart *chart, double lon, double lat, double zoom,
                         uint32_t width, uint32_t height,
                         const tile57_mariner *m,
                         uint8_t **out, size_t *out_len, tile57_error *err);

/* ---- callback Canvas: the pixel-space callback twin ------------------------
 * The same view painted through a table of C function pointers instead of
 * rasterising to PNG — the embedder (e.g. a GPU chart app) feeds these to its
 * own renderer. Geometry is emitted in canvas PIXEL space (y down), in final
 * paint order; colours are fully resolved for the active palette. */
typedef struct { float x, y; } tile57_point;   /* canvas pixels */
/* A resolved straight-alpha colour, packed 0xRRGGBBAA.
 *
 * Deliberately a SCALAR, not a 4-byte struct. Passing a small extern struct BY
 * VALUE across a callconv(.c) boundary is miscompiled by zig 0.16 on aarch64 in
 * every optimized build mode (ReleaseFast/ReleaseSafe zero the argument,
 * ReleaseSmall passes garbage; Debug is correct), which silently reached hosts
 * as fully transparent fills, lines and text. A uint32_t is passed in a
 * register and is correct in every mode. */
typedef uint32_t tile57_color;
#define TILE57_COLOR_R(c) ((uint8_t)((c) >> 24))
#define TILE57_COLOR_G(c) ((uint8_t)((c) >> 16))
#define TILE57_COLOR_B(c) ((uint8_t)((c) >>  8))
#define TILE57_COLOR_A(c) ((uint8_t)((c) & 0xFFu))
#define TILE57_COLOR(r, g, b, a) \
    (((uint32_t)(r) << 24) | ((uint32_t)(g) << 16) | ((uint32_t)(b) << 8) | (uint32_t)(a))
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
    void (*fill_path)   (void *ctx, const tile57_rings *rings, tile57_color color, int even_odd);
    /* Stroke polylines width_px wide; dash on/off in px (0,0 = solid). */
    void (*stroke_path) (void *ctx, const tile57_rings *rings, float width_px,
                         float dash_on, float dash_off, tile57_color color);
    /* Fill rings with a repeating RGBA8 pattern cell (pw*ph*4 bytes). */
    void (*fill_pattern)(void *ctx, const tile57_rings *rings, uint32_t pw, uint32_t ph,
                         const uint8_t *rgba);
    /* Draw a shaped label as flattened outline rings (px), optional halo
     * (halo.a == 0 => none). */
    void (*draw_glyphs) (void *ctx, const tile57_rings *outline, tile57_color color,
                         tile57_color halo, float halo_px);
} tile57_canvas_cb;
tile57_status tile57_chart_canvas(tile57_chart *chart, double lon, double lat, double zoom,
                            uint32_t width, uint32_t height,
                            const tile57_mariner *m,
                            const tile57_canvas_cb *canvas, tile57_error *err);

/* ---- world-space Surface callback: the GPU vector twin ---------------------
 * The same view emitted as a WORLD-SPACE, semantically TAGGED stream rather
 * than resolved pixels: area/line geometry in web-mercator [0,1] (y down);
 * point symbols and text as a WORLD anchor + a LOCAL outline in reference px
 * (a constant screen size); every draw call tagged with its feature's S-57
 * class and SCAMIN. A GPU host applies its own view transform, pins
 * symbols/text at the anchor, and culls by SCAMIN per frame — so pan and zoom
 * re-portray NOTHING. */
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

/* What a rotatable draw call's rotation is referenced to (MapLibre's
 * rotation-alignment — the same model tile57's own style output emits).
 *
 * VIEWPORT: the angle is SCREEN-relative. A host with a rotated view must NOT
 *           add its view rotation — the mark stays upright on screen, so a buoy
 *           stays the right way up and a label stays readable. The default for
 *           anchored symbols and ordinary labels.
 * MAP:      the angle is CHART-relative (referenced to north, or to a line
 *           tangent). A host with a rotated view ADDS its view rotation, so the
 *           mark turns with the chart. This is the engine's ORIENT / linestyle
 *           `rot_north`, and it is what a depth-contour value must follow. */
typedef enum { TILE57_ALIGN_VIEWPORT = 0, TILE57_ALIGN_MAP = 1 } tile57_rot_align;

/* The S-52 display category a feature belongs to — the axis the mariner's
 * display_base / display_standard / display_other settings select on. A feature
 * only reaches the surface if its category is enabled, so this says WHICH of the
 * enabled categories it came in on. Display base is the never-hide set (the
 * safety-of-navigation minimum): SCAMIN is not applied to it. */
typedef enum {
    TILE57_DISPLAY_BASE = 0, TILE57_DISPLAY_STANDARD = 1, TILE57_DISPLAY_OTHER = 2
} tile57_display_category;

/* S-101 DisplayPlane. Outranks display_priority in paint order — S-52 PresLib
 * §10.3.4.2: "the OVERRADAR flag takes precedence over the objects display
 * priority". */
typedef enum {
    TILE57_PLANE_UNDER_RADAR = 0, TILE57_PLANE_OVER_RADAR = 1
} tile57_display_plane;

/* The feature the following draw calls belong to. `cls` is the S-57 object-class
 * acronym (NUL-terminated; "" if none); `scamin` is the SCAMIN 1:N denominator
 * (<= 0 => always visible); `display_category` is the feature's display category
 * — a host that applies SCAMIN itself must skip it when display_category ==
 * TILE57_DISPLAY_BASE.
 *
 * `display_plane` and `display_priority` are the two paint-order axes, in that
 * order of precedence (see the draw table below). `display_priority` is the
 * S-101 catalogue DrawingPriority, 0..30. The engine has ALREADY sorted the call
 * stream by both, so they are here for a host that re-buckets the stream into
 * its own batches and has to rebuild the order.
 *
 * NOTE: `display_priority` was called `plane` before, then `draw_prio`. The
 * original name was simply wrong — it never carried DisplayPlane. That axis is
 * now transmitted properly, as `display_plane`. */
typedef struct {
    const char *cls;
    int64_t scamin;
    int32_t display_priority;
    tile57_display_plane display_plane;
    tile57_display_category display_category;
    /* Paint-order key for THIS draw call — the engine's own ordering, folded into
     * one comparable integer: text last, then DisplayPlane (radar overlay only),
     * then display priority, then geometry class. Strictly non-decreasing across
     * the call stream.
     *
     * This is what a batching host should bucket on. Do NOT decode it — the
     * packing is the engine's to change; compare it and nothing else. It is
     * meaningful only within one scene, and bounded by TILE57_PAINT_KEY_MAX so a
     * host can size a bucket array. */
    uint32_t paint_key;
} tile57_feature;

/* One past the largest tile57_feature.paint_key. */
#define TILE57_PAINT_KEY_MAX 744u

/* Draw table. Pointers are valid only for the duration of the call; ctx is
 * passed back verbatim.
 *
 * CALLS ARRIVE IN S-52 PAINT ORDER. The engine buffers the scene and sorts it
 * before calling you: class-major (areas, then area patterns, then lines, then
 * point symbols, then soundings, then text — a fill never covers a line whatever
 * its priority), and by S-52 draw priority within a class. Draw them in the order
 * you receive them and the result is correct; you do not need to sort.
 *
 * BUT ONLY IF YOU PRESERVE THAT ORDER. A GPU renderer normally batches by DRAW
 * TYPE — all fills, then all sprites, then all text — to minimise pipeline
 * switches, and batching REORDERS the stream: it lifts every call of one type out
 * of the sequence the engine put it in. That silently breaks global paint order
 * again (an area pattern jumps over the lines drawn above it, a tessellated
 * symbol and an atlas sprite swap places), and it breaks it in a way that looks
 * plausible on a sparse chart and wrong on a dense one. If you batch, sort each
 * batch by `display_priority` yourself and draw the batches in the class order above.
 * That is what `display_priority` is still there for.
 *
 * A host that batches PER TILE must go further: sorting within a tile still
 * leaves paint order broken across tiles, because the tiles are drawn one after
 * another. Walk the priority bands OUTSIDE the tile loop, or a low-priority
 * symbol in one tile will cover a high-priority one in its neighbour. */
typedef struct {
    void *ctx;
    /* Filled area (world). even_odd != 0 selects the even-odd rule. */
    void (*fill_area)  (void *ctx, const tile57_feature *f, const tile57_world_rings *rings, tile57_color color, int even_odd);
    /* Stroked line (world); width in reference px, dash on/off px (0,0 solid). */
    void (*stroke_line)(void *ctx, const tile57_feature *f, const tile57_world_rings *lines, float width_px, float dash_on, float dash_off, tile57_color color);
    /* Point symbol: world anchor + local outline (px). even_odd for compound
     * glyphs; stroke_w > 0 => the rings are a polyline stroked stroke_w px wide.
     * The outline arrives ALREADY rotated to the symbol's angle; `align` says
     * whether that angle is chart-relative — MAP => additionally rotate the
     * outline by the view rotation (ORIENT symbols, linestyle bricks); VIEWPORT
     * => leave it upright on screen (the common navaid case). */
    void (*draw_symbol)(void *ctx, const tile57_feature *f, tile57_world_point anchor, const tile57_local_rings *rings, tile57_color color, int even_odd, float stroke_w, tile57_rot_align align);
    /* Text: world anchor + local glyph outlines (px, even-odd) + halo
     * (halo.a == 0 => none). The glyphs arrive ALREADY rotated; `align` says
     * whether that angle is chart-relative — MAP => additionally rotate by the
     * view rotation (a depth-contour value follows its contour); VIEWPORT => the
     * label stays upright on screen (the ordinary case).
     * `text_group` is the label's S-52 text group (§14.5) — a property of the
     * LABEL, not the feature, since one feature can carry several labels in
     * different groups. Group 11 is IMPORTANT TEXT: it ignores the mariner's
     * text switches and always shows, so a host wanting it larger/bold keys on
     * this. 21/26/29 are names, 23 light descriptions; 0 = none. */
    void (*draw_text)  (void *ctx, const tile57_feature *f, tile57_world_point anchor, const tile57_local_rings *glyphs, tile57_color color, tile57_color halo, float halo_px, tile57_rot_align align, int32_t text_group);
    /* Point symbol as a sprite: symbol name (ptr,len) to look up in the atlas
     * (tile57_bake_assets sprite_png/json), world anchor, rotation (deg), and the
     * symbol's un-rotated half-extent in reference px. Draw the atlas cell as a
     * quad of that half-size, centred on the anchor, at `rot_deg + (align == MAP
     * ? view_rotation : 0)`. NULL => symbols tessellate via draw_symbol instead.
     * (ABI-appended after the original vtable.) */
    void (*draw_sprite)(void *ctx, const tile57_feature *f, const char *name, size_t name_len, tile57_world_point anchor, float rot_deg, tile57_rot_align align, float half_w_px, float half_h_px);
    /* Area fill pattern: pattern name (ptr,len) to look up in the atlas ("pat:"
     * prefix) + the fill rings (world). Tile the cell across the polygon.
     *
     * Only the cell's SIZE is screen-referenced (a constant number of device px,
     * like a symbol); its ORIGIN is not. Anchor the tiling to WORLD space — derive
     * the pattern coordinate from the fragment's world position, never from its
     * screen position — so the pattern translates with the chart. A pattern phased
     * off screen coordinates stays nailed to the viewport while the seabed slides
     * underneath it, which reads as the chart moving and the fill not.
     * NULL => flat tint. */
    void (*draw_pattern)(void *ctx, const tile57_feature *f, const char *name, size_t name_len, const tile57_world_rings *rings);
    /* Text as a STRING for the host's SDF glyph atlas (tile57_bake_glyph_sdf):
     * world anchor + the anchor-relative baseline-left origin in px (ox,oy, with
     * alignment already applied) + UTF-8 text (ptr,len) + the glyph pixel size.
     * The host lays the string out from its glyph metrics and draws SDF quads,
     * rotating the whole run about the anchor by `rot_deg + (align == MAP ?
     * view_rotation : 0)` (a depth-contour value passes the tangent + MAP; an
     * ordinary label passes 0 + VIEWPORT and stays upright). `text_group` is the
     * label's S-52 text group, exactly as on draw_text (11 = important text).
     * NULL => text tessellates via draw_text. Must be the LAST field. */
    void (*draw_text_str)(void *ctx, const tile57_feature *f, tile57_world_point anchor, float ox_px, float oy_px, const char *text, size_t text_len, float size_px, float rot_deg, tile57_rot_align align, tile57_color color, tile57_color halo, int32_t text_group);
} tile57_surface_cb;

tile57_status tile57_chart_surface(tile57_chart *chart, double lon, double lat, double zoom,
                             double rotation_rad, /* view rotation, radians CW; 0 = north-up */
                             uint32_t width, uint32_t height,
                             const tile57_mariner *m,
                             const tile57_surface_cb *surface, tile57_error *err);

/* ---- draw-ready GPU scenes -------------------------------------------------
 *
 * The callback surface above hands a host a STREAM of draw calls, in paint
 * order. A GPU host cannot draw that stream as it arrives: it has to batch by
 * pipeline, and batching destroys the order. So it ends up sorting the calls
 * back into order itself — which means owning a tessellator, a copy of the
 * geometry-class taxonomy, and a copy of the S-52 ordering rule. That is a
 * second scene, free to drift from the engine's, and it did drift: the same
 * spec bug (applying OVERRADAR precedence with no radar overlay present) had to
 * be found and fixed on both sides.
 *
 * tile57_chart_gpu_scene exists so that a host owns no scene and knows no S-52.
 * It hands over geometry ALREADY triangulated, ALREADY in paint order, and
 * ALREADY split into ranges that draw one pipeline at a time. Upload the three
 * buffers, then walk the ranges in order and draw each one. That is the whole
 * host obligation.
 *
 * What the host still owns: the camera, the shaders, and what to do with the
 * per-vertex `scamin` / `disp_cat` gates — those are per-frame, and baking them
 * in would force a rebuild on every zoom or category toggle. */

/* One vertex. (x, y) is WORLD position (web-mercator, [0,1], y down) — the
 * camera transforms it. (ox, oy) is an offset in REFERENCE PIXELS added in
 * SCREEN space after projection: zero for area interiors, +/- half-width for
 * line edges, and the glyph or symbol outline for marks. Keeping the two apart
 * is what lets a symbol hold a constant on-screen size while its anchor moves
 * with the chart, with no re-tessellation on zoom. */
typedef struct {
    float x, y;      /* world position, [0,1] */
    float ox, oy;    /* screen-space offset, reference px */
    float scamin;    /* SCAMIN 1:N denominator; 0 = always visible */
    uint8_t disp_cat;  /* S-52 display category: 0 base, 1 standard, 2 other */
    uint8_t map_align; /* nonzero = chart-relative: a rotated view must turn it */
    uint8_t _pad[2];
} tile57_gpu_vertex;

/* What a range draws. The host picks a pipeline from this and nothing more —
 * it is NOT the paint order. Ordering is paint_key and only paint_key. */
typedef enum {
    TILE57_GPU_AREA = 0,
    TILE57_GPU_PATTERN = 1,
    TILE57_GPU_LINE = 2,
    TILE57_GPU_SYMBOL = 3,
    TILE57_GPU_SOUNDING = 4,
    TILE57_GPU_TEXT = 5
} tile57_gpu_kind;

/* Sentinel for tile57_gpu_range.pattern on every range that is not a pattern. */
#define TILE57_GPU_NO_PATTERN 0xFFFFFFFFu

/* One area-fill pattern cell: RGBA8, w * h * 4 bytes, row-major. It is
 * rasterized at the scene's own screen density, so w and h ARE the on-screen
 * tiling period in device px — there is no separate period to apply.
 *
 * The host tiles it: sample the cell 1:1 in device px, PHASE-ANCHORED TO THE
 * WORLD ORIGIN rather than to the screen, so the pattern stays fixed to the
 * chart under a pan instead of swimming across it. The vertex (x, y) is all
 * that is needed to derive that phase. Tiling is left to the host because it
 * resolves per-fragment at the live camera scale; baking it into geometry would
 * mean re-tessellating on every zoom. */
typedef struct {
    uint32_t w, h;
    const uint8_t *rgba;
    size_t rgba_len;
} tile57_gpu_pattern;

/* A contiguous slice of the index buffer drawing with ONE pipeline and ONE
 * colour. Ranges arrive already sorted by paint_key: draw them in order and the
 * chart is correct. */
typedef struct {
    uint32_t first_index;
    uint32_t index_count;
    /* The engine's paint-order key. Already sorted by it; exposed so a host
     * batching ACROSS scenes can interleave them. Opaque — compare, never
     * decode. */
    uint32_t paint_key;
    /* Index into tile57_gpu_scene.patterns, or TILE57_GPU_NO_PATTERN. Set only
     * on TILE57_GPU_PATTERN ranges. */
    uint32_t pattern;
    /* Resolved RGBA for the palette the scene was built with. Meaningless on a
     * pattern range — the cell carries its own colours. */
    uint8_t color[4];
    uint8_t kind; /* tile57_gpu_kind */
    uint8_t _pad[3];
} tile57_gpu_range;

/* Draw-ready buffers for one view. Every pointer is BORROWED and stays valid
 * until tile57_gpu_scene_free; `owner` is opaque and must not be touched. */
typedef struct {
    const tile57_gpu_vertex *vertices;
    size_t vertex_count;
    const uint32_t *indices;
    size_t index_count;
    const tile57_gpu_range *ranges;
    size_t range_count;
    const tile57_gpu_pattern *patterns;
    size_t pattern_count;
    void *owner;
} tile57_gpu_scene;

/* Portray a view into the buffers above — the draw-ready twin of
 * tile57_chart_surface. The WHOLE view builds into ONE scene, so labels
 * declutter across it and a name cannot collide with itself over a tile seam.
 *
 * There is deliberately NO rotation parameter, for the same reason
 * tile57_chart_tile_surface has none: geometry stays north-up in world space
 * and the host applies the view rotation, so a course-up view that turns
 * continuously never has to have its scene rebuilt. The per-vertex map_align
 * flag is what keeps that invariant for marks that must turn with the chart.
 *
 * On OK the caller owns the scene and MUST release it with
 * tile57_gpu_scene_free. On failure *out is zeroed and nothing needs freeing. */
tile57_status tile57_chart_gpu_scene(tile57_chart *chart, double lon, double lat, double zoom,
                             uint32_t width, uint32_t height,
                             const tile57_mariner *m,
                             tile57_gpu_scene *out, tile57_error *err);

/* Release a scene and zero the struct. Every pointer it handed out dies here,
 * so the host must have finished uploading first. Null-safe, and safe to call
 * twice. */
void tile57_gpu_scene_free(tile57_gpu_scene *scene);

/* Portray ONE tile (z, x, y) through the SAME S-52 portrayal and the SAME
 * tile57_surface_cb, but for a single tile instead of a whole view. Lets a host
 * portray + tessellate each tile ONCE, cache the geometry keyed by (chart, z, x, y),
 * and compose the view from cached tiles (re-portray only newly-visible tiles) —
 * the MapLibre tile model, reusing tile57's portrayal. World coordinates and SCAMIN
 * tags are identical to tile57_chart_surface, so the same callbacks/shaders apply.
 * Decluttering is PER-TILE (labels resolve within the tile); a host wanting
 * cross-tile label suppression keeps a separate view-level text pass.
 *
 * There is deliberately NO rotation parameter: a tile is tessellated ONCE and
 * re-transformed on the GPU every frame, so its geometry must stay north-up in
 * world space and the host applies the view rotation. The per-feature `align`
 * flags are what keep that invariant — a MAP-aligned mark turns with the chart
 * without the tile being re-baked, so a course-up view that turns continuously
 * never invalidates a cached tile. */
tile57_status tile57_chart_tile_surface(tile57_chart *chart, uint8_t z, uint32_t x, uint32_t y,
                             const tile57_mariner *m,
                             const tile57_surface_cb *surface, tile57_error *err);

/* Portray ONE MLT tile from CALLER-SUPPLIED bytes to a surface — the archive-less
 * twin of tile57_chart_tile_surface. For a host that fetched a tile (e.g. over HTTP
 * from a tile server) and wants it painted with NO chart open: `mlt`/`mlt_len` are
 * the raw (DECOMPRESSED) MLT tile bytes; (z,x,y) place it. Same WORLD-SPACE tagged
 * draw calls, callbacks, and PER-TILE decluttering as tile57_chart_tile_surface;
 * the colour profile + symbol catalogue are the ones baked into the library. An
 * undecodable tile paints nothing (still TILE57_OK). */
tile57_status tile57_render_mlt_tile(const uint8_t *mlt, size_t mlt_len,
                             uint8_t z, uint32_t x, uint32_t y,
                             const tile57_mariner *m,
                             const tile57_surface_cb *surface, tile57_error *err);

/* The VIEW-level, GLOBALLY-decluttered TEXT pass — the companion to
 * tile57_chart_tile_surface for a tile-renderer host. That per-tile call declutters
 * labels WITHIN each tile, so a name straddling a tile seam collides or repeats
 * across the join; this call resolves the WHOLE view's labels against one collision
 * pool and emits ONLY the survivors, through the SAME surface `draw_text_str`
 * (preferred) / `draw_text` callbacks. It draws NO fill_area / stroke_line /
 * draw_symbol / draw_sprite — the host draws geometry + symbols from its per-tile
 * cache and takes text from here.
 *
 * The intended loop: cache each (z,x,y) tile's geometry + symbols once via
 * tile57_chart_tile_surface, draw those cached tiles every frame, and call this once
 * per frame (or per view change) to overlay the text. World anchors, local px
 * offsets, per-feature tags and the MAP/VIEWPORT `align` convention are identical to
 * tile57_chart_surface, so the text sits over the cached geometry with no
 * re-projection — draw it LAST (text is drawn on top). `rotation_rad` matters: labels
 * declutter in the SCREEN frame the host draws them in.
 *
 * Cost: each covering tile is portrayed ONCE and its label candidates are memoized
 * on the chart, so a repeat call over tiles already seen does NO portrayal work — it
 * only re-resolves those candidates against the new view. Zoom and rotation are NOT
 * part of the memo (a candidate holds what a label says, how it is shaped and where
 * it is anchored; the collision box, the contour legibility gate and the upright
 * flip all derive per call), so a continuous pan / zoom / rotate settles in well
 * under a millisecond. Only the first view of a region — or a change to the palette
 * or ANY mariner setting, which retires the memo — pays portrayal again. The memo is
 * bounded (a few hundred tiles, a couple of MB) and released with the chart.
 * Cell/bundle sources; a lazy multi-cell ENC_ROOT is TILE57_ERR_UNSUPPORTED (bake,
 * then compose). */
tile57_status tile57_chart_labels(tile57_chart *chart, double lon, double lat, double zoom,
                             double rotation_rad, /* view rotation, radians CW; 0 = north-up */
                             uint32_t width, uint32_t height,
                             const tile57_mariner *m,
                             const tile57_surface_cb *surface, tile57_error *err);

/* Release a chart and all cached tiles. Must not be called while any borrower
 * (a compositor, a renderer thread) may still read from it. */
void tile57_chart_close(tile57_chart *chart);

/* ======================================================================== *
 * 5. Compose
 *
 * The runtime compositor: MANY open charts in, one seamless chart out. It
 * builds (or loads) the ownership partition over the charts' embedded
 * coverage, then offers the SAME output set as a single chart, composed:
 * any (z, x, y) tile on demand for the cost of a classify plus one decompress
 * or one decode/clip (what a live tile server hands its HTTP layer), plus the
 * composed view outputs (png / pdf / canvas / surface) and the composed cursor
 * pick (query). Open once, serve many, close.
 *
 * The compositor BORROWS its charts (their mmap'd archives and decoded
 * coverage): every chart must outlive the compositor, and while it serves, do
 * not call those charts' own methods from other threads.
 * ======================================================================== */

/* Opaque runtime-compositor handle. */
typedef struct tile57_compose tile57_compose;

/* Coverage/zoom summary filled by tile57_compose_get_meta. */
typedef struct {
    uint8_t min_zoom;
    uint8_t max_zoom;   /* deepest zoom served (native windows + one fill-up overscale zoom) */
    uint32_t charts;    /* coverage-carrying charts held */
    double west, south, east, north; /* union coverage bounds, degrees */
} tile57_compose_meta;

/* Open a compositor over `n` open charts (each a per-chart archive from the
 * bake, opened with tile57_chart_open). Charts whose archives embed no coverage are
 * skipped — they can own no ground; if none carries coverage the open is
 * TILE57_ERR_UNSUPPORTED. The ownership partition is an internal detail: it is
 * found beside the archives, reused when it still matches the cell set, and
 * rebuilt (and refreshed on disk) when it does not. Nothing to pass, nothing to
 * manage. TILE57_OK with *out set (close with tile57_compose_close — BEFORE
 * closing the charts). */
tile57_status tile57_compose_open(tile57_chart *const *charts, size_t n,
                                  tile57_compose **out, tile57_error *err);

/* Open a WHOLE baked tree in one call: recursively walk `dir` for the *.pmtiles
 * archives a bake produced, mmap and open each (the cell set is never fully
 * resident), and compose them — the one-call form of enumerating the directory,
 * tile57_chart_open on each, then tile57_compose_open. Unlike tile57_compose_open,
 * the returned compositor OWNS the archives it opened: the caller holds no chart
 * handles and tile57_compose_close alone releases the whole set. `partition_path`
 * (NULL to skip) behaves exactly as in tile57_compose_open — a partition sidecar
 * (tile57_compose_save_partition; the `tile57 bake` CLI emits partition.tpart) to
 * load and skip the build, with a missing/stale one falling back to building.
 * *out_chart_count (NULL to ignore) receives the number of archives composed. No
 * *.pmtiles under `dir`, or none carrying coverage, is TILE57_ERR_UNSUPPORTED with
 * *out = NULL; an unreadable `dir` errors. TILE57_OK with *out set (close with
 * tile57_compose_close). */
tile57_status tile57_compose_tree(const char *dir,
                                  tile57_compose **out, uint32_t *out_chart_count,
                                  tile57_error *err);

/* Compose the tile (z,x,y) on demand into RAW (decompressed) MLT in *out /
 * *out_len (free with tile57_free) — the HTTP layer gzips on the wire. NULL/0
 * out with TILE57_OK means no bytes for this tile; *out_owned (NULL to ignore)
 * then distinguishes the two empties:
 *   owned = false: no chart owns this ground — true empty ocean, safe to cache.
 *   owned = true:  a chart owns this ground but produced nothing — transient
 *                  while its per-chart bake is still running; suspect once
 *                  bakes are done. */
tile57_status tile57_compose_tile(tile57_compose *c, uint8_t z, uint32_t x, uint32_t y,
                                   uint8_t **out, size_t *out_len, bool *out_owned,
                                   tile57_error *err);

/* The composed view outputs — tile57_chart_png / tile57_chart_pdf / tile57_chart_canvas /
 * tile57_chart_surface across the WHOLE composed set: every covering tile is
 * composed on demand (stitched through the ownership partition) and
 * replayed through the native S-52 pixel path. Same parameters, limits, and
 * ownership as the single-chart forms in section 4. */
tile57_status tile57_compose_png(tile57_compose *c, double lon, double lat, double zoom,
                                 uint32_t width, uint32_t height,
                                 const tile57_mariner *m,
                                 uint8_t **out, size_t *out_len, tile57_error *err);
tile57_status tile57_compose_pdf(tile57_compose *c, double lon, double lat, double zoom,
                                 uint32_t width, uint32_t height,
                                 const tile57_mariner *m,
                                 uint8_t **out, size_t *out_len, tile57_error *err);
tile57_status tile57_compose_canvas(tile57_compose *c, double lon, double lat, double zoom,
                                    uint32_t width, uint32_t height,
                                    const tile57_mariner *m,
                                    const tile57_canvas_cb *canvas, tile57_error *err);
tile57_status tile57_compose_surface(tile57_compose *c, double lon, double lat, double zoom,
                                     double rotation_rad, /* view rotation, radians CW; 0 = north-up */
                                     uint32_t width, uint32_t height,
                                     const tile57_mariner *m,
                                     const tile57_surface_cb *surface, tile57_error *err);

/* The composed VIEW-level, globally-decluttered TEXT pass — tile57_chart_labels
 * across the WHOLE composed set. Emits ONLY the surviving labels (through the
 * surface's draw_text_str / draw_text) resolved against one collision pool spanning
 * every covering tile and every chart seam; draws NO geometry. For a tile-renderer
 * host that draws geometry + symbols from its own per-tile cache (tile57_compose_tile
 * / a per-tile surface) but needs labels decluttered across BOTH tile and chart
 * seams. World anchors, per-feature tags and the align convention are identical to
 * tile57_compose_surface, so the text overlays the cached geometry with no
 * re-projection — draw it last. Label candidates memoize per tile on the compositor
 * (released with it), so each covering tile is composed, decoded and portrayed once
 * and a repeat call at any centre, zoom or rotation over tiles already seen only
 * re-resolves them — the composed set's first view of a region is the only one that
 * pays. See tile57_chart_labels for the memo's terms and the intended per-frame
 * loop. */
tile57_status tile57_compose_labels(tile57_compose *c, double lon, double lat, double zoom,
                                    double rotation_rad, /* view rotation, radians CW; 0 = north-up */
                                    uint32_t width, uint32_t height,
                                    const tile57_mariner *m,
                                    const tile57_surface_cb *surface, tile57_error *err);

/* The composed cursor pick (S-52 §10.8, across chart boundaries): tile57_chart_query across
 * the whole composed set. */
tile57_status tile57_compose_query(tile57_compose *c, double lon, double lat, double zoom,
                                   const tile57_query_cb *cb, tile57_error *err);

/* Fill *out with the compositor's zoom range + union coverage bounds. */
void tile57_compose_get_meta(tile57_compose *c, tile57_compose_meta *out);


/* Release a compositor. Its charts stay open (and stay yours to close). */
void tile57_compose_close(tile57_compose *c);

/* ======================================================================== *
 * 6. Style + portrayal assets
 *
 * tile57 ships tile generation AND style generation together. tile57_style_build
 * turns a MapLibre style template + the mariner's S-52 display options + the S-52
 * colortables into a concrete style JSON, client-side; tile57_bake_assets produces
 * the colour tables, line styles, and sprite / pattern / glyph atlases the style
 * references.
 * ======================================================================== */

/* ---- portrayal assets ---------------------------------------------------- */

/* All portrayal assets in memory, from the library's embedded catalogue
 * (catalog_dir NULL/"") or an on-disk one. Pairs with tile57_style_build + the
 * composed tiles for a complete renderable chart. Free with
 * tile57_assets_free. */
typedef struct {
    uint8_t *colortables;  size_t colortables_len;
    uint8_t *linestyles;   size_t linestyles_len;
    uint8_t *sprite_json;  size_t sprite_json_len;   uint8_t *sprite_png;  size_t sprite_png_len;
    uint8_t *pattern_json; size_t pattern_json_len;  uint8_t *pattern_png; size_t pattern_png_len;
} tile57_assets;
tile57_status tile57_bake_assets(const char *catalog_dir, tile57_assets *out,
                                 tile57_error *err);
/* Like tile57_bake_assets but sprite_json/sprite_png carry the MapLibre sprite-mln
 * atlas (pivot-centred cells + {name:{x,y,width,height,pixelRatio}} JSON); other
 * fields are NULL. Free with tile57_assets_free. */
tile57_status tile57_bake_sprite_mln(const char *catalog_dir, tile57_assets *out,
                                     tile57_error *err);
/* SDF glyph atlas for GPU text: sprite_png is the RGBA signed-distance-field atlas
 * of the label font; sprite_json is {"em_px","pad","glyphs":{codepoint:[u0,v0,u1,
 * v1,off_x,off_y,w,h,advance]}} with the quad geometry in EM units (multiply by the
 * text pixel size). A host draws each glyph as a textured quad sampling the SDF.
 * Only sprite_* filled. Free with tile57_assets_free. */
tile57_status tile57_bake_glyph_sdf(tile57_assets *out, tile57_error *err);
void tile57_assets_free(tile57_assets *out);

/* ---- chart-style generation ---------------------------------------------
 *
 * tile57_style_build patches the mariner-driven parts of the template (depth
 * shading, sounding/danger symbol swaps, contour-label units, the per-scheme
 * recolour) and AND-s the display filters (category, band, boundary/point style,
 * date validity, text groups, …) onto every source:"chart" layer. The template +
 * colortables are produced by the engine's asset generator; the host fills
 * tile57_mariner (section 4) from its UI.
 *
 * The S-52 colortables and base style template are baked into the library, so a
 * host can generate a complete style with no on-disk catalogue or template file:
 *   tile57_colortables_default(&ct,&ctn,NULL);
 *   tile57_style_template(scheme, "http://host/{z}/{x}/{y}", NULL,NULL,0,0,0, &t,&tn,NULL);
 *   tile57_style_build(t,tn, &m, ct,ctn, bands,nb, scamin,nsm,lat, &style,&sn,NULL);
 * Free each buffer with tile57_free. */

/* Build a MapLibre style JSON from a template + mariner settings + S-52 colortables.
 * enabled_bands: NULL = no band filter (show all); else only features whose `band`
 * rank is in the array (count entries) are shown.
 * scamin: the distinct SCAMIN denominators present in the source (e.g. from
 *   tile57_chart_scamin / the TileJSON). When non-NULL with scamin_count>0 the `_scamin`
 *   source-layers are split into one per-value bucket layer with a native
 *   fractional minzoom = scaminDisplayZoom(value, scamin_lat). NULL / count 0 -> the
 *   `_scamin` layers stay a single ungated layer (features render, but SCAMIN does
 *   not gate by value).
 * scamin_lat: representative latitude (degrees) for the bucket minzooms (the SCAMIN
 *   display cutoff is latitude-dependent); use the source's center latitude.
 * TILE57_OK with the style JSON in *out / *out_len (free with tile57_free). */
tile57_status tile57_style_build(const char *template_json, size_t template_len,
                                 const tile57_mariner *m,
                                 const char *colortables_json, size_t colortables_len,
                                 const int32_t *enabled_bands, size_t enabled_band_count,
                                 const int32_t *scamin, size_t scamin_count, double scamin_lat,
                                 uint8_t **out, size_t *out_len, tile57_error *err);

/* Compute the minimal MapLibre style-mutation ops to turn the style for `old_m`
 * into the style for `new_m` — same template/colortables/bands/scamin inputs as
 * tile57_style_build, so the two styles are comparable. For a flicker-free mariner
 * toggle the host applies each op in place (map.setFilter / setPaintProperty /
 * setLayoutProperty) instead of re-setStyle-ing, leaving overlays and sources
 * untouched. The output is a JSON array; each element is one mutation:
 *   {"op":"setFilter",        "layer":<id>,"value":<filter|null>}
 *   {"op":"setPaintProperty", "layer":<id>,"property":<key>,"value":<v|null>}
 *   {"op":"setLayoutProperty","layer":<id>,"property":<key>,"value":<v|null>}
 * Only layers whose filter / a paint prop / a layout prop differ appear; an
 * unchanged toggle yields "[]". If the two mariners would produce a DIFFERENT SET
 * of layers (not expected for any current mariner field — a safety valve), the
 * result is [{"op":"rebuild"}], signalling the host to fall back to a full
 * setStyle. TILE57_OK with the op array in *out / *out_len (free with
 * tile57_free). */
tile57_status tile57_style_diff(const char *template_json, size_t template_len,
                                const tile57_mariner *old_m, const tile57_mariner *new_m,
                                const char *colortables_json, size_t colortables_len,
                                const int32_t *enabled_bands, size_t enabled_band_count,
                                const int32_t *scamin, size_t scamin_count, double scamin_lat,
                                uint8_t **out, size_t *out_len, tile57_error *err);

/* S-52 colortables.json (token -> hex per day/dusk/night) from the colour profile
 * baked into the library. TILE57_OK with *out / *out_len set (free with
 * tile57_free). */
tile57_status tile57_colortables_default(uint8_t **out, size_t *out_len,
                                         tile57_error *err);

/* Base MapLibre style template (layers + chart `sources` + sprite/glyph URLs) from
 * the catalogue baked into the library — no template file needed. The source lives
 * in the template; the per-change mariner patch (tile57_style_build) takes none.
 *   scheme:       a tile57_scheme (selects the per-scheme palette).
 *   source_tiles: the chart {z}/{x}/{y} tiles URL (NULL -> a default pmtiles:// source).
 *   sprite,glyphs:base URLs that enable the symbol / text layers (NULL omits them).
 *   minzoom: the chart source's tile floor, emitted verbatim — pass the archive's
 *            real minzoom (0 = tiles from z0; MapLibre never requests tiles below
 *            a source's minzoom, so an inflated floor blanks every lower zoom).
 *   maxzoom: 0 -> engine default.
 *   tile_encoding: the chart source's tile encoding (a tile57_tile_type, from
 *            tile57_info.tile_type). TILE57_TILE_TYPE_MLT emits "encoding":"mlt" on
 *            the source so maplibre-gl >= 5.12 decodes MLT natively; 0 /
 *            TILE57_TILE_TYPE_MVT emits nothing (the MapLibre default). The hint
 *            survives tile57_style_build / tile57_style_diff.
 * TILE57_OK with *out / *out_len set (free with tile57_free). */
tile57_status tile57_style_template(tile57_scheme scheme, const char *source_tiles,
                                    const char *sprite, const char *glyphs,
                                    uint32_t minzoom, uint32_t maxzoom,
                                    uint8_t tile_encoding,
                                    uint8_t **out, size_t *out_len, tile57_error *err);

/* ======================================================================== *
 * 7. Util
 * ======================================================================== */

/* Populate the process-global read-only registries (the S-100 feature catalogue and
 * the complex-linestyle table) on the calling thread. Both are idempotent lazy-init
 * and thereafter read-only. Call this ONCE on your main thread before opening or
 * baking charts from worker threads, so those globals are fully populated first and
 * concurrent bake/render is race-free (the allocator is thread-safe and the portrayal
 * context is thread-local). Cheap and safe to call more than once. */
void tile57_warmup(void);

/* Free ANY buffer the engine returned (tiles, style JSON, the scamin array,
 * colortables, …). Buffers are length-prefixed at allocation, so the pointer is
 * all it needs — the universal free. */
void tile57_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* TILE57_H */
