---
id: c-api
title: C API
sidebar_position: 5
---

# C API

`libtile57.a` exposes the whole engine behind a thin C ABI —
[`include/tile57.h`](../../include/tile57.h), prefix `tile57_`. It is a shim over
the [Zig API](./zig-api.md); the two stay in lock-step. Open a **chart**, serve
vector tiles by `(z, x, y)` — MapLibre Tiles (MLT, the default bake format) or
Mapbox Vector Tiles (MVT) — render finished PNG/PDF views, and (offline) bake
archives + bundles, build a MapLibre style, and generate portrayal assets.

:::warning Lifetime + threading
A `tile57_chart` is **not** internally synchronized — use one thread per chart.
It must also outlive every consumer still holding it: if a long-lived renderer
captures the chart, close it only once nothing can still call
`tile57_chart_tile`. `tile57_chart_tile` allocates `*out`; free it with
`tile57_free` (same length). Input bytes are copied, so the caller may free them
right after the call.
:::

## Open a chart + fetch tiles

```c
#include "tile57.h"

const char *tile57_version(void);   /* "0.1.0" */

/* Opaque chart handle. */
typedef struct tile57_chart tile57_chart;

/* Open an on-disk ENC_ROOT directory (or a single .000 file) as a streaming
 * chart: cells are enumerated + peeked at open, then their bytes are read on
 * demand (working set only). Rules are the library's embedded catalogue.
 * NULL on failure. */
tile57_chart *tile57_chart_open(const char *path);

/* Open one in-memory ENC cell (base .000 bytes) as a resident chart. Bytes are
 * copied. NULL on failure. */
tile57_chart *tile57_chart_open_bytes(const uint8_t *base, size_t len);

/* Open a baked PMTiles bundle from a file path. NULL on failure. */
tile57_chart *tile57_chart_open_pmtiles(const char *path);

/* Tile encodings served by tile57_chart_tile / produced by the bakes. */
typedef enum {
    TILE57_TILE_TYPE_MVT = 1, /* Mapbox Vector Tile */
    TILE57_TILE_TYPE_MLT = 2, /* MapLibre Tile (the default bake format) */
} tile57_tile_type;

/* Fixed chart metadata, for a host that frames its own camera. Bounds/anchor
 * validity are flagged (false -> those fields are 0). tile_type is the encoding
 * tile57_chart_tile returns: a PMTiles-backed chart reports its archive's stored
 * type; a cell-backed chart reports its live generation format. */
typedef struct {
    uint8_t  min_zoom, max_zoom;
    uint32_t bands;                                 /* bitmask: bit r = band rank r present */
    bool     has_bounds; double west, south, east, north;
    bool     has_anchor; double anchor_lat, anchor_lon, anchor_zoom;
    uint8_t  tile_type;                             /* tile57_tile_type */
} tile57_chart_info;
void tile57_chart_get_info(tile57_chart *chart, tile57_chart_info *out);

typedef enum {
    TILE57_TILE_OK = 1,     /* *out / *out_len set; free with tile57_free */
    TILE57_TILE_EMPTY = 0,  /* valid tile, no features */
    TILE57_TILE_ERROR = -1,
} tile57_tile_status;

/* Fetch tile (z, x, y) as decompressed vector-tile bytes, VERBATIM in the
 * chart's tile encoding (chart_info.tile_type — there is no transcode layer;
 * hosts hint the encoding to the renderer instead, e.g. the MapLibre vector
 * source `encoding` option). Cached per chart. */
tile57_tile_status tile57_chart_tile(tile57_chart *chart, uint8_t z, uint32_t x, uint32_t y,
                                     uint8_t **out, size_t *out_len);

/* Select the encoding for LIVE-generated tiles on a cell-backed chart: 0 =
 * engine default (mlt), TILE57_TILE_TYPE_MVT, TILE57_TILE_TYPE_MLT. Cell-backed
 * charts OPEN generating MVT (existing MVT-only embedders are unaffected); a
 * host whose renderer decodes MLT opts in here. No-op for a baked PMTiles chart.
 * Changing the format drops the tile cache. */
void tile57_chart_set_tile_format(tile57_chart *chart, uint8_t format);

/* Free ANY buffer the engine returned (tiles, style JSON, the scamin array,
 * colortables, …), passing the same length. The universal free. */
void tile57_free(void *ptr, size_t len);

void tile57_chart_clear_cache(tile57_chart *chart);
void tile57_chart_close(tile57_chart *chart);

/* The distinct SCAMIN denominators present in the chart (ascending). On success
 * returns 1 with *out pointing at *out_len int32 values, 0 if none, -1 on error.
 * Free with tile57_free((uint8_t*)*out, *out_len * sizeof(int32_t)). */
int tile57_chart_scamin(tile57_chart *chart, int32_t **out, size_t *out_len);
```

An ENC_ROOT cell is a base `.000` plus its sequential `.001`, `.002` … update
files; `tile57_chart_open` walks the directory (`CATALOG.031`, else a `*.000`
scan), applies each cell's updates, and overlays the cells by scale band.

## Render a finished view (PNG / PDF)

The [native S-52 rendering engine](./rendering.md) draws a view of the chart —
centre + fractional zoom + pixel size — with the mariner settings evaluated
*live* (real safety contour, category/SCAMIN/text-group gates, day/dusk/night
palette), catalogue symbols replayed as vectors, and labels decluttered over the
whole canvas.

```c
/* PNG raster. `m` NULL = canonical defaults (tile57_mariner_defaults). Returns 0
 * with *out/*out_len set (free with tile57_free); -1 bad handle, -2 render
 * failure, -3 unsupported source (a baked PMTiles chart carries no portrayal). */
int tile57_chart_render_view(tile57_chart *chart, double lon, double lat, double zoom,
                             uint32_t width, uint32_t height,
                             const tile57_mariner *m,
                             uint8_t **out, size_t *out_len);

/* Its vector twin: the SAME scene as a deterministic single-page PDF
 * (1 px = 1 pt, 72 dpi; vector fills + glyph-outline text). Same parameters,
 * returns, and ownership. */
int tile57_chart_render_pdf(tile57_chart *chart, double lon, double lat, double zoom,
                            uint32_t width, uint32_t height,
                            const tile57_mariner *m,
                            uint8_t **out, size_t *out_len);
```

The `tile57_mariner` settings struct is defined in the
[chart-style section](#build-a-maplibre-style) below.

## Render to a host surface (vector callbacks)

Instead of a finished raster, tile57 can hand you the portrayed scene as a stream
of draw calls in world space. A GPU host tessellates that stream once, then pans
and zooms by transforming the vertices each frame, so symbols and text stay a
constant size on screen and no re-portrayal is needed while the view moves.

You fill in a `tile57_surface_cb` vtable and pass it to
`tile57_chart_render_surface_cb`. Area and line geometry come in web-mercator world
coordinates (the range 0 to 1, with y pointing down). Point symbols, soundings, and
text come as a world anchor plus a small outline in reference pixels, so you can
draw them at a fixed size on screen. Every call carries the feature's SCAMIN, so you
can hide it by zoom in a shader.

```c
typedef struct { double x, y; } tile57_world_point;   /* web-mercator 0..1, y down */
typedef struct { const tile57_world_point *pts; uint32_t n;
                 const uint32_t *ring_starts; uint32_t ring_count; } tile57_world_rings;
typedef struct { const char *cls; int64_t scamin; int32_t plane; } tile57_feature;

typedef struct {
    void *ctx;                                 /* handed back to every call */
    void (*fill_area)  (void *ctx, const tile57_feature *f, const tile57_world_rings *rings,
                        tile57_rgba color, int even_odd);
    void (*stroke_line)(void *ctx, const tile57_feature *f, const tile57_world_rings *lines,
                        float width_px, float dash_on, float dash_off, tile57_rgba color);
    void (*draw_symbol)(void *ctx, const tile57_feature *f, tile57_world_point anchor,
                        const tile57_local_rings *rings, tile57_rgba color, int even_odd, float stroke_w);
    void (*draw_text)  (void *ctx, const tile57_feature *f, tile57_world_point anchor,
                        const tile57_local_rings *glyphs, tile57_rgba color, tile57_rgba halo, float halo_px);
    /* Optional. Leave NULL to get vector outlines from the two calls above; set them
     * to draw point symbols and area patterns from the sprite atlas as textured quads. */
    void (*draw_sprite) (void *ctx, const tile57_feature *f, const char *name, size_t name_len,
                         tile57_world_point anchor, float rot_deg, float half_w_px, float half_h_px);
    void (*draw_pattern)(void *ctx, const tile57_feature *f, const char *name, size_t name_len,
                         const tile57_world_rings *rings);
} tile57_surface_cb;

/* Portray the view once and drive the callbacks. 0 ok, -1 bad handle,
 * -2 render failure, -3 unsupported source. */
int tile57_chart_render_surface_cb(tile57_chart *chart, double lon, double lat, double zoom,
                                   uint32_t width, uint32_t height,
                                   const tile57_mariner *m, const tile57_surface_cb *surface);
```

Set `draw_sprite` and `draw_pattern` once you have the sprite atlas loaded (see
[`tile57_bake_sprite_mln`](#generate-portrayal-assets)). tile57 then hands point
symbols, soundings, and area patterns by name, and you draw them as atlas quads —
smoothed by texture filtering and cheaper than tessellating outlines. If you leave
those two fields NULL, the same features arrive as vector outlines instead.

tile57 also declutters overlapping text for you before it makes the calls (symbols
and soundings always draw, per S-52), so you don't repeat that work.

## Inspect a chart: cells, features, catalogues

```c
/* The chart's per-cell metadata as a JSON array — name (DSNM stem), scale
 * (DSPM CSCL), edition/update/issueDate/agency (after the update chain), and
 * bbox. 1 = *out/*out_len set (free with tile57_free); 0 = no cells (e.g. a
 * PMTiles chart — its bundle manifest carries the inventory); -1 = error. */
int tile57_chart_cells(tile57_chart *chart, uint8_t **out, size_t *out_len);

/* The chart's features for comma-separated object-class acronyms (e.g.
 * "DEPARE,DRGARE") as a GeoJSON FeatureCollection: lon/lat geometry,
 * properties = {"class": …, plus the full S-57 acronym->value attribute map}.
 * Parsed without portrayal; an ENC_ROOT-wide query walks every cell. 1 = JSON
 * set; 0 = no matches; -1 = error. */
int tile57_chart_features(tile57_chart *chart, const char *classes,
                          uint8_t **out, size_t *out_len);

/* Decode a CATALOG.031 exchange-set catalogue (raw bytes) into a JSON array of
 * its CATD entries — file path, longName (chart title), impl (BIN/ASC/TXT),
 * bbox. Not chart-scoped. 1 = JSON set; 0 = no CATD records; -1 = parse error. */
int tile57_catalog_entries(const uint8_t *catalog_031, size_t len,
                           uint8_t **out, size_t *out_len);
```

The CLI mirrors these as `tile57 cells`, `tile57 features`, and
`tile57 catalog`.

## Query the features under a point (object query / pick)

The S-52 cursor pick. Given a lon/lat, tile57 replays the finest tile that covers
the point and reports every feature the point falls in — an area you are inside,
or a line or point symbol within a small radius. Each hit calls you back with the
S-57 object-class acronym, the attribute JSON (acronym to value), and the source
cell name. This is what a chart application shows when you tap a feature to see
what it is.

```c
typedef struct {
    void *ctx;
    void (*feature)(void *ctx, const char *cls, size_t cls_len,
                    const char *s57, size_t s57_len,
                    const char *cell, size_t cell_len);
} tile57_query_cb;

/* Calls cb->feature once per feature under (lon,lat). 0 ok, -1 bad args.
 * The pointers passed to the callback are valid only during that call. */
int tile57_chart_query(tile57_chart *chart, double lon, double lat, const tile57_query_cb *cb);
```

The class and cell come through for any chart. The attribute JSON is filled in
only when the chart was baked with pick attributes — `tile57_bake_bundle` /
`tile57_bake_pmtiles` include them by default (set `omit_pick_attrs` to leave them
out for leaner tiles). Without them, `s57` is an empty string.

## Bake an ENC_ROOT to PMTiles

Bake in-memory cells into one PMTiles archive, zoom-banded per cell by
compilation scale, so the result opens cheaply (`tile57_chart_open_pmtiles`)
instead of holding every cell live. One cell = a base `.000` plus its sequential
update files.

```c
/* One ENC cell for tile57_bake_pmtiles. `name` (the source cell stem, e.g.
 * "US4MD81M") is emitted as the `cell` pick-report property; NULL/"" omits it. */
typedef struct {
    const uint8_t *base;  size_t base_len;
    const uint8_t *const *updates;  const size_t *update_lens;  size_t update_count;
    const char *name;
} tile57_cell;

/* Progress callback. stage 0 = loading/portraying cells, stage 1 = baking tiles.
 * band_index/band_count/band_name locate the current navigational band. */
typedef void (*tile57_bake_progress)(void *user, uint8_t stage, size_t done, size_t total,
                                     uint8_t band_index, uint8_t band_count,
                                     const char *band_name);

/* Shared bake options. Pass NULL for all defaults (embedded rules/catalogue, no
 * band clamp, pick attrs included, no progress). catalog_dir/created apply to
 * tile57_bake_bundle only. */
typedef struct {
    const char *rules_dir;      /* NULL = embedded portrayal rules */
    const char *catalog_dir;    /* NULL = embedded S-101 catalogue (bundle only) */
    const char *created;        /* NULL = manifest "created" unset (bundle only) */
    uint8_t minzoom, maxzoom;   /* 0/0 = no band clamp */
    bool omit_pick_attrs;
    tile57_bake_progress progress;
    void *progress_user;
    uint8_t format;             /* baked tile encoding: 0 = default (mlt),
                                 * TILE57_TILE_TYPE_MVT, TILE57_TILE_TYPE_MLT.
                                 * Honored by both bake calls. */
} tile57_bake_opts;

/* 1 with the archive in *out/*out_len (free with tile57_free), 0 if nothing
 * covered, -1 on error. */
int tile57_bake_pmtiles(const tile57_cell *cells, size_t count,
                        const tile57_bake_opts *opts,
                        uint8_t **out, size_t *out_len);
```

## Bake a chart bundle

`tile57_bake_bundle` bakes a single cell `.000` **or** a whole ENC_ROOT directory
(`input`, an on-disk path) into a self-contained chart bundle under `out_dir` —
the same package the `tile57 bake … -o out/` CLI emits: `tiles/chart.pmtiles`,
`assets/{colortables,linestyles}.json` + sprite/pattern atlases, per-scheme
`assets/style-{day,dusk,night}.json`, and `manifest.json`. `out_cell_count` /
`out_bbox` (w,s,e,n) are optional. Returns 1 on success, 0 if nothing was covered,
-1 on error.

```c
int tile57_bake_bundle(const char *input, const char *out_dir,
                       const tile57_bake_opts *opts,
                       uint32_t *out_cell_count, double *out_bbox);
```

## Generate portrayal assets

`tile57_bake_assets` produces all portrayal assets in memory (the same files
`tile57_bake_bundle` writes to disk) from the library's embedded catalogue
(`catalog_dir` NULL/"") or an on-disk `PortrayalCatalog`. Every non-NULL buffer is
owned by the library; release the whole struct with `tile57_assets_free`.

```c
typedef struct {
    uint8_t *colortables;  size_t colortables_len;
    uint8_t *linestyles;   size_t linestyles_len;
    uint8_t *sprite_json;  size_t sprite_json_len;   uint8_t *sprite_png;  size_t sprite_png_len;
    uint8_t *pattern_json; size_t pattern_json_len;  uint8_t *pattern_png; size_t pattern_png_len;
} tile57_assets;

int  tile57_bake_assets(const char *catalog_dir, tile57_assets *out);   /* 1 = ok, 0 = error */
void tile57_assets_free(tile57_assets *out);
```

`tile57_bake_sprite_mln` is a focused variant that fills only the `sprite_json` /
`sprite_png` fields with a MapLibre **sprite-mln** atlas: every S-101 symbol packed
into one PNG, each cell centered on its symbol's pivot, plus a JSON index of
`{name: {x, y, width, height, pixelRatio}}`. A GPU host loads this atlas once and
draws point symbols and area patterns as textured quads by name — the atlas the
[host-surface `draw_sprite`/`draw_pattern` callbacks](#render-to-a-host-surface-vector-callbacks)
hand back. Free it with `tile57_assets_free` as above.

```c
int tile57_bake_sprite_mln(const char *catalog_dir, tile57_assets *out);   /* 1 = ok, 0 = error */
```

## Build a MapLibre style

`tile57_build_style` turns a MapLibre style template + the mariner's S-52 display
options + the S-52 colortables into a concrete style JSON, client-side. The
template + colortables come from the built-in `tile57_style_template` /
`tile57_colortables_default` (or the bundle's assets); the host fills
`tile57_mariner` from its UI.

```c
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
    char date_view[9];              /* "YYYYMMDD" or "" (empty -> today) */
    bool ignore_scamin;             /* debug: drop SCAMIN scale-gating (not S-52) */
    double size_scale;              /* physical-scale multiplier; 1.0 = catalogue sizes */
    const int32_t *viewing_groups_off;  /* S-52 §14.5 deny-list of `vg` ids turned off */
    uint32_t viewing_groups_off_len;
    bool scamin_filter_gate;        /* gate SCAMIN with a live filter, not bucket layers */
    bool show_overscale;            /* S-52 §10.1.10 overscale indication: the
                                     * AP(OVERSC01) hatch over regions displayed finer
                                     * than their compilation scale. Defaults true. */
} tile57_mariner;

void tile57_mariner_defaults(tile57_mariner *m);   /* canonical defaults, date_view = "" */

/* enabled_bands: NULL = show all; else only features whose band rank is in the
 * array. scamin: the distinct SCAMIN denominators present in the source (e.g. from
 * tile57_chart_scamin) — when non-NULL the `_scamin` layers split into per-value
 * native-minzoom buckets; scamin_lat is the representative latitude. Returns 1 with
 * the style JSON in *out/*out_len (free with tile57_free); 0 on error. */
int tile57_build_style(const char *template_json, size_t template_len,
                       const tile57_mariner *m,
                       const char *colortables_json, size_t colortables_len,
                       const int32_t *enabled_bands, size_t enabled_band_count,
                       const int32_t *scamin, size_t scamin_count, double scamin_lat,
                       uint8_t **out, size_t *out_len);

/* Minimal MapLibre style-mutation ops to turn the style for `old_m` into the style
 * for `new_m` (same inputs as tile57_build_style) — for flicker-free mariner
 * toggles. Writes a JSON op array to *out/*out_len (free with tile57_free). */
int tile57_style_diff(const char *template_json, size_t template_len,
                      const tile57_mariner *old_m, const tile57_mariner *new_m,
                      const char *colortables_json, size_t colortables_len,
                      const int32_t *enabled_bands, size_t enabled_band_count,
                      const int32_t *scamin, size_t scamin_count, double scamin_lat,
                      uint8_t **out, size_t *out_len);
```

The S-52 colortables and base style template are baked into the library, so a host
can build a complete style with no on-disk catalogue or template file (free each
buffer with `tile57_free`):

```c
/* colortables.json (S-52 token -> hex per day/dusk/night) from the baked profile. */
int tile57_colortables_default(uint8_t **out, size_t *out_len);

/* Base MapLibre style template (layers + chart source + sprite/glyph URLs). scheme
 * selects the palette; source_tiles is the {z}/{x}/{y} URL (NULL -> a default
 * pmtiles:// source); sprite/glyphs are base URLs (NULL omits those layers);
 * minzoom is the chart source's tile floor, emitted verbatim (pass the archive's
 * real minzoom); maxzoom 0 -> engine default. tile_encoding is the source's tile
 * type (from chart_info.tile_type): TILE57_TILE_TYPE_MLT emits "encoding":"mlt"
 * on the source so maplibre-gl >= 5.12 decodes MLT natively; 0 / MVT emits
 * nothing. */
int tile57_style_template(tile57_scheme scheme, const char *source_tiles,
                          const char *sprite, const char *glyphs,
                          uint32_t minzoom, uint32_t maxzoom,
                          uint8_t tile_encoding,
                          uint8_t **out, size_t *out_len);
```

## Diagnostics header

[`include/tile57_diag.h`](../../include/tile57_diag.h) (`tile57_diag_*`) exposes
the embedded-Lua / S-101 framework bring-up self-tests — developer tooling, not
part of the embedding API.

## Versioning

Pre-1.0 (`0.1.0`). No external consumers yet, so the ABI is not frozen.
