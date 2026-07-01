---
id: c-api
title: C API
sidebar_position: 5
---

# C API

`libtile57.a` exposes the whole engine behind a thin C ABI —
[`include/tile57.h`](../../include/tile57.h), prefix `tile57_`. It is a shim over
the [Zig API](./zig-api.md); the two stay in lock-step. Open a **chart**, serve
Mapbox Vector Tiles by `(z, x, y)`, and (offline) bake archives + bundles, build a
MapLibre style, and generate portrayal assets.

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

/* Fixed chart metadata, for a host that frames its own camera. Bounds/anchor
 * validity are flagged (false -> those fields are 0). */
typedef struct {
    uint8_t  min_zoom, max_zoom;
    uint32_t bands;                                 /* bitmask: bit r = band rank r present */
    bool     has_bounds; double west, south, east, north;
    bool     has_anchor; double anchor_lat, anchor_lon, anchor_zoom;
} tile57_chart_info;
void tile57_chart_get_info(tile57_chart *chart, tile57_chart_info *out);

typedef enum {
    TILE57_TILE_OK = 1,     /* *out / *out_len set; free with tile57_free */
    TILE57_TILE_EMPTY = 0,  /* valid tile, no features */
    TILE57_TILE_ERROR = -1,
} tile57_tile_status;

/* Fetch tile (z, x, y) as decompressed MVT bytes. Cached per chart. */
tile57_tile_status tile57_chart_tile(tile57_chart *chart, uint8_t z, uint32_t x, uint32_t y,
                                     uint8_t **out, size_t *out_len);

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
 * minzoom/maxzoom of 0 -> engine defaults. */
int tile57_style_template(tile57_scheme scheme, const char *source_tiles,
                          const char *sprite, const char *glyphs,
                          uint32_t minzoom, uint32_t maxzoom,
                          uint8_t **out, size_t *out_len);
```

## Diagnostics header

[`include/tile57_diag.h`](../../include/tile57_diag.h) (`tile57_diag_*`) exposes
the embedded-Lua / S-101 framework bring-up self-tests — developer tooling, not
part of the embedding API.

## Versioning

Pre-1.0 (`0.1.0`). No external consumers yet, so the ABI is not frozen.
