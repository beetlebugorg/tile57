---
id: c-api
title: C API
sidebar_position: 5
---

# C API

`libtile57.a` exposes the whole engine behind a thin C ABI —
[`include/tile57.h`](../../include/tile57.h), prefix `tile57_`. It is a shim over
the [Zig API](./zig-api.md); the two stay in lock-step.

Two handles cover the surface:

- A **`tile57_chart`** is the metadata + render handle. Open a cell (or a baked
  PMTiles) and read its bounds, scale, coverage, cells, and features; query the
  feature under a point; or render a finished PNG / PDF / callback surface.
- A **`tile57_compose_source`** is the runtime **compositor**. Tiles are made one
  way: bake each ENC cell to its own PMTiles, then compose them on demand by
  `(z, x, y)` through the ownership partition. The composed bytes are MapLibre
  Tiles (MLT, the default) or Mapbox Vector Tiles (MVT).

The header is organized into seven sections — version, chart open + metadata,
cell baking, live composing, render surface, style + assets, and util/catalogue/
debug — mirrored below.

:::warning Lifetime + threading
Neither handle is internally synchronized — use one thread per handle. Each must
also outlive every consumer still holding it: if a long-lived renderer or
compositor captures it, close it only once nothing can still call into it. Calls
that return bytes allocate `*out`; free it with `tile57_free` (same length).
Input bytes are copied, so the caller may free them right after the call.
:::

## Open a chart + read metadata

```c
#include "tile57.h"

const char *tile57_version(void);   /* "0.1.0" */

/* Opaque chart handle. */
typedef struct tile57_chart tile57_chart;

/* Open an on-disk ENC_ROOT directory (or a single .000 file, with its .001..
 * update chain) via the streaming path: each cell's metadata (name, compilation
 * scale, M_COVR coverage) is read up front and tiles are baked lazily per request,
 * with no upfront full-cell bake. Rules are the library's embedded catalogue.
 * NULL on failure. */
tile57_chart *tile57_chart_open(const char *path);

/* Open a cell for METADATA ONLY — bbox, native_scale, M_COVR coverage — via a
 * cheap parse with no tile bake (a chart-database / header scan). Do NOT render
 * this handle. NULL on failure. */
tile57_chart *tile57_chart_open_header(const char *path);

/* Open a cell baking only [minzoom, maxzoom] — a narrow native band fast for
 * first paint, then re-open the full range in the background (progressive load). */
tile57_chart *tile57_chart_open_zoom(const char *path, uint8_t minzoom, uint8_t maxzoom);

/* Open one in-memory ENC cell (base .000 bytes) as a resident chart. Bytes are
 * copied. NULL on failure. */
tile57_chart *tile57_chart_open_bytes(const uint8_t *base, size_t len);

/* Open a baked PMTiles bundle from a file path. NULL on failure. */
tile57_chart *tile57_chart_open_pmtiles(const char *path);

/* Vector-tile encodings the engine produces (reported in chart_info.tile_type;
 * the compositor serves MLT). */
typedef enum {
    TILE57_TILE_TYPE_MVT = 1, /* Mapbox Vector Tile */
    TILE57_TILE_TYPE_MLT = 2, /* MapLibre Tile (the default) */
} tile57_tile_type;

/* Fixed chart metadata, for a host that frames its own camera. Bounds/anchor
 * validity are flagged (false -> those fields are 0). tile_type is the encoding
 * for this chart's tiles (PMTiles: the archive's stored type; a cell: the engine
 * default). native_scale is the compilation scale 1:N (0 if unknown). */
typedef struct {
    uint8_t  min_zoom, max_zoom;
    uint32_t bands;                                 /* bitmask: bit r = band rank r present */
    bool     has_bounds; double west, south, east, north;
    bool     has_anchor; double anchor_lat, anchor_lon, anchor_zoom;
    uint8_t  tile_type;                             /* tile57_tile_type */
    int32_t  native_scale;
} tile57_chart_info;
void tile57_chart_get_info(tile57_chart *chart, tile57_chart_info *out);

/* The distinct SCAMIN denominators present in the chart (ascending). On success
 * returns 1 with *out pointing at *out_len int32 values, 0 if none, -1 on error.
 * Free with tile57_free((uint8_t*)*out, *out_len * sizeof(int32_t)). */
int tile57_chart_scamin(tile57_chart *chart, int32_t **out, size_t *out_len);

/* Release a chart and all cached tiles. */
void tile57_chart_close(tile57_chart *chart);
```

An ENC_ROOT cell is a base `.000` plus its sequential `.001`, `.002` … update
files; `tile57_chart_open` walks the directory (`CATALOG.031`, else a `*.000`
scan), applies each cell's updates, and overlays the cells by scale band.

## Bake cells, then compose tiles

Tile production is a two-step composite model. First bake each ENC cell to its
own PMTiles at that cell's compilation scale; the per-cell archive embeds the
cell's M_COVR coverage in its metadata. Then open a **compositor** over the
archives and serve any `(z, x, y)` tile on demand — the compositor stitches the
overlapping cells through an ownership partition, handling cross-band zoom.

```c
/* Bake ONE cell (+ its .001.. updates, read from disk) to PMTiles bytes over its
 * native band zoom range. Returned in *out/*out_len (free with tile57_free) —
 * persist the per-cell archive, then feed it to tile57_compose_open. The metadata
 * embeds the cell's coverage (read via tile57_pmtiles_metadata). 1 = ok, 0 =
 * nothing baked, -1 = error. */
int tile57_bake_cell_bytes(const char *path, uint8_t **out, size_t *out_len);

/* Read a PMTiles archive's metadata JSON blob (decompressed) into *out/*out_len.
 * A single-cell bake embeds that cell's coverage + cscl + date/name under a
 * "coverage" key, so the compositor rebuilds the partition without re-parsing the
 * .000. 1 = ok, 0 = no metadata, -1 = error. */
int tile57_pmtiles_metadata(const uint8_t *pmtiles, size_t len,
                            uint8_t **out, size_t *out_len);
```

Every baked feature carries the pick-report properties `class` (object-class
acronym), `cell` (source cell stem), and `s57` (the full S-57 attribute set as a
JSON object) — what `tile57_chart_query` and a host inspector read back.

The compositor holds the per-cell archives mmap'd and the ownership partition
resident, so a tile costs a classify plus one decode/clip or a decompress. Open
once, serve many, close.

```c
/* Opaque runtime-compositor handle. */
typedef struct tile57_compose_source tile57_compose_source;

/* Coverage/zoom summary filled by tile57_compose_meta_get. */
typedef struct {
    uint8_t min_zoom;
    uint8_t max_zoom;                 /* deepest zoom served (native + one overscale zoom) */
    uint32_t cells;                   /* coverage-carrying archives held */
    double west, south, east, north;  /* union coverage bounds, degrees */
} tile57_compose_meta;

/* Open a resident compositor over the `n` per-cell PMTiles at `paths` (each from
 * tile57_bake_cell_bytes, on disk), mmap'd so the cell set is never fully
 * resident. partition_path (NULL to skip) names a sidecar — written by
 * tile57_compose_save_partition (the `tile57 bake` CLI emits partition.tpart) — to
 * load and skip the build; a missing/stale one falls back to building. NULL on
 * error / no coverage-carrying archive. */
tile57_compose_source *tile57_compose_open(const char *const *paths, size_t n,
                                           const char *partition_path);

/* Compose tile (z,x,y) on demand into RAW (decompressed) MLT in *out/*out_len — what
 * a live tile server hands its HTTP layer (which gzips on the wire). Returns:
 *   1  served (bytes in *out/*out_len),
 *   2  OWNED but empty — a cell owns this ground but produced nothing (transient
 *      while its bake is still running; an error state once bakes are done),
 *   0  not owned — true empty ocean (safe to cache),
 *  -1  error. */
int tile57_compose_serve(tile57_compose_source *src, uint8_t z, uint32_t x, uint32_t y,
                         uint8_t **out, size_t *out_len);

/* Fill *out with the compositor's zoom range + union coverage bounds. */
void tile57_compose_meta_get(tile57_compose_source *src, tile57_compose_meta *out);

/* Serialize the ownership partition to `path` (a sidecar a later
 * tile57_compose_open loads to skip the build). 1 = ok, -1 = error. */
int tile57_compose_save_partition(tile57_compose_source *src, const char *path);

/* Release a compositor (munmaps the archives, frees the partition). */
void tile57_compose_close(tile57_compose_source *src);
```

The `tile57 bake <cell.000 | ENC_ROOT> -o out/` CLI produces this structure
directly: `out/tiles/<STEM>.pmtiles` per cell plus `out/partition.tpart`. A host
opens the compositor over `out/tiles/*.pmtiles` with that sidecar.

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
    /* Optional. Text as a UTF-8 string for a host SDF glyph atlas (tile57_bake_glyph_sdf),
     * instead of tessellated outlines. */
    void (*draw_text_str)(void *ctx, const tile57_feature *f, tile57_world_point anchor,
                          float ox_px, float oy_px, const char *text, size_t text_len,
                          float size_px, tile57_rgba color, tile57_rgba halo);
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

There is a pixel-space twin, `tile57_chart_render_view_cb` with a `tile57_canvas_cb`
vtable, that emits the SAME portrayal as resolved paint-order draw calls in canvas
pixels — for a host that wants the engine's own paint pipeline without the PNG
encode.

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

The S-52 cursor pick. Given a lon/lat and the current view `zoom`, tile57 replays
the tile at that zoom and reports every feature the point falls in — an area you
are inside, or a line or point symbol within a small radius. Each hit calls you
back with the S-57 object-class acronym, the attribute JSON (acronym to value),
and the source cell name. This is what a chart application shows when you tap a
feature to see what it is.

Passing the view zoom matters: the query reports the features actually DISPLAYED
at that zoom (it applies the same SCAMIN cull the renderer does), and the pick
tolerance tracks on-screen distance instead of ground distance — so a buoy is just
as easy to tap zoomed out as zoomed in, and a zoomed-out click doesn't return
finer-scale features that aren't drawn.

```c
typedef struct {
    void *ctx;
    void (*feature)(void *ctx, const char *cls, size_t cls_len,
                    const char *s57, size_t s57_len,
                    const char *cell, size_t cell_len);
} tile57_query_cb;

/* Calls cb->feature once per displayed feature under (lon,lat) at view `zoom`.
 * 0 ok, -1 bad args. Callback pointers are valid only during that call. */
int tile57_chart_query(tile57_chart *chart, double lon, double lat, double zoom,
                       const tile57_query_cb *cb);
```

The class and cell come through for any chart; the attribute JSON is filled in
from the `s57` pick property baked into the tiles (empty if a chart was baked
without pick attributes).

## Generate portrayal assets

`tile57_bake_assets` produces all portrayal assets in memory — colour tables,
line styles, and the sprite / area-fill pattern atlases — from the library's
embedded catalogue (`catalog_dir` NULL/"") or an on-disk `PortrayalCatalog`.
Every non-NULL buffer is owned by the library; release the whole struct with
`tile57_assets_free`.

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
hand back. `tile57_bake_glyph_sdf` is its text counterpart: an RGBA
signed-distance-field atlas of the label font, for a host that draws text as SDF
quads. Free either with `tile57_assets_free` as above.

```c
int tile57_bake_sprite_mln(const char *catalog_dir, tile57_assets *out);   /* 1 = ok, 0 = error */
int tile57_bake_glyph_sdf(tile57_assets *out);                             /* 1 = ok, 0 = error */
```

## Build a MapLibre style

`tile57_build_style` turns a MapLibre style template + the mariner's S-52 display
options + the S-52 colortables into a concrete style JSON, client-side. The
template + colortables come from the built-in `tile57_style_template` /
`tile57_colortables_default` (or the generated assets); the host fills
`tile57_mariner` from its UI.

```c
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

## Util: warmup + free

```c
/* Populate the process-global read-only registries (feature catalogue +
 * complex-linestyle table) on the calling thread. Call ONCE on your main thread
 * before opening or baking cells from worker threads, so concurrent bake/render is
 * race-free. Idempotent. */
void tile57_warmup(void);

/* Free ANY buffer the engine returned (tiles, style JSON, the scamin array,
 * colortables, …), passing the same length. The universal free. */
void tile57_free(void *ptr, size_t len);
```

## Diagnostics header

[`include/tile57_diag.h`](../../include/tile57_diag.h) (`tile57_diag_*`) exposes
the embedded-Lua / S-101 framework bring-up self-tests — developer tooling, not
part of the embedding API.

## Versioning

Pre-1.0 (`0.1.0`). No external consumers yet, so the ABI is not frozen.
