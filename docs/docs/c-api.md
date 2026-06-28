---
id: c-api
title: C API
sidebar_position: 5
---

# C API

`libtile57.a` exposes the whole engine behind a thin C ABI —
[`include/tile57.h`](../../include/tile57.h), prefix `tile57_`. It is a shim over
the [Zig API](./zig-api.md); the two stay in lock-step. Open a chart **source**,
serve Mapbox Vector Tiles by `(z, x, y)`, and (offline) bake archives, build a
MapLibre style, and generate portrayal assets.

:::warning Lifetime + threading
A `tile57_source` is **not** internally synchronized — use one thread per source.
It must also outlive every consumer still holding it: if a long-lived renderer
captures the source, close it only once nothing can still call
`tile57_tile_get`. `tile57_tile_get` allocates `*out`; free it with
`tile57_tile_free` (same length). Input bytes are copied, so the caller may free
them right after the call.
:::

## Open a source + fetch tiles

```c
#include "tile57.h"

const char *tile57_version(void);   /* "0.1.0" */

typedef enum {
    TILE57_FORMAT_AUTO = 0,     /* sniff: PMTiles first, then S-57 cell */
    TILE57_FORMAT_PMTILES = 1,
    TILE57_FORMAT_S57_CELL = 2, /* raw .000; tiles generated live */
} tile57_format;

/* Open from in-memory bytes. rules_dir = S-101 rules for cells (NULL -> default,
 * i.e. TILE57_S101_RULES or the vendored catalogue). NULL on error. */
tile57_source *tile57_source_open(const uint8_t *data, size_t len,
                                  tile57_format format, const char *rules_dir);

tile57_format tile57_source_format(tile57_source *src);   /* resolved after AUTO */
void          tile57_source_close(tile57_source *src);

/* Source metadata, for a host that frames its own camera. */
void     tile57_source_zoom_range(tile57_source *src, uint8_t *min_z, uint8_t *max_z);
uint32_t tile57_source_bands(tile57_source *src);   /* bitmask: bit r = band rank r present */
bool     tile57_source_bounds(tile57_source *src, double *w, double *s, double *e, double *n);
bool     tile57_source_anchor(tile57_source *src, double *lat, double *lon, double *zoom);

typedef enum {
    TILE57_TILE_OK = 1,     /* *out / *out_len set; free with tile57_tile_free */
    TILE57_TILE_EMPTY = 0,  /* valid tile, no features */
    TILE57_TILE_ERROR = -1,
} tile57_tile_status;

/* Fetch tile (z, x, y) as decompressed MVT bytes. Cached per source. */
tile57_tile_status tile57_tile_get(tile57_source *src, uint8_t z, uint32_t x, uint32_t y,
                                   uint8_t **out, size_t *out_len);
void tile57_tile_free(uint8_t *ptr, size_t len);
void tile57_source_clear_cache(tile57_source *src);
```

## Open an ENC_ROOT (many cells)

The host walks the directory and reads the files (Zig 0.16 gates filesystem
access behind `std.Io`); the library parses, applies each cell's updates, and
overlays the cells. One cell = a base `.000` plus its sequential update files.

```c
typedef struct {
    const uint8_t *base; size_t base_len;
    const uint8_t *const *updates; const size_t *update_lens; size_t update_count;
} tile57_cell_input;

tile57_source *tile57_source_open_cells(const tile57_cell_input *cells, size_t count,
                                        const char *rules_dir);
```

### Streaming open (low memory)

For a large ENC_ROOT, hand over cheap per-cell metadata + a reader callback
instead of every cell's bytes up front; a cell's bytes are read only when a tile
needs them and freed again on LRU eviction.

```c
typedef struct {
    double west, south, east, north;   /* degrees */
    int32_t cscl;                      /* 1:cscl compilation scale */
} tile57_cell_meta;

typedef struct {
    const uint8_t *base; size_t base_len;
    const uint8_t *const *updates; const size_t *update_lens; size_t update_count;
} tile57_cell_bytes;   /* reader transfers ownership; library frees */

typedef bool (*tile57_cell_read_fn)(void *user, size_t index, tile57_cell_bytes *out);

tile57_source *tile57_source_open_cells_streaming(
    const tile57_cell_meta *metas, size_t count,
    tile57_cell_read_fn read, void *user, const char *rules_dir);
```

## Bake an ENC_ROOT to PMTiles

Bake the same cells into one PMTiles archive, zoom-banded per cell by compilation
scale, so the result opens cheaply (`tile57_source_open` with
`TILE57_FORMAT_PMTILES`) instead of holding every cell live. `minzoom`/`maxzoom`
clamp the bands (0/24 = no clamp); `progress` may be NULL. Returns 1 with the
archive in `*out`/`*out_len` (free with `tile57_tile_free`), 0 if nothing
covered, -1 on error.

```c
typedef void (*tile57_bake_progress)(void *user, uint8_t stage, size_t done, size_t total);

int tile57_bake_cells(const tile57_cell_input *cells, size_t count, const char *rules_dir,
                      uint8_t minzoom, uint8_t maxzoom,
                      tile57_bake_progress progress, void *user,
                      uint8_t **out, size_t *out_len);
```

## Build a MapLibre style

`tile57_build_style` turns a MapLibre style template + the mariner's S-52 display
options + the S-52 colortables into a concrete style JSON, client-side. It
patches the mariner-driven parts of the template (depth shading, sounding/danger
symbol swaps, contour-label units, the per-scheme recolour) and AND-s the display
filters (category, band, boundary/point style, date validity, text groups, …)
onto every `source:"chart"` layer. The template + colortables are produced by the
asset generator below; the host fills `tile57_mariner` from its UI.

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
    char date_view[9]; /* "YYYYMMDD" or "" (empty -> today) */
} tile57_mariner;

void tile57_mariner_defaults(tile57_mariner *m);   /* canonical defaults */

/* enabled_bands: NULL = show all bands; else only features whose band rank is in
 * the array are shown. Returns 1 with the style JSON in *out/*out_len
 * (free with tile57_tile_free); 0 on error. */
int tile57_build_style(const char *template_json, size_t template_len,
                       const tile57_mariner *m,
                       const char *colortables_json, size_t colortables_len,
                       const int32_t *enabled_bands, size_t enabled_band_count,
                       uint8_t **out, size_t *out_len);
```

## Generate portrayal assets

Generate the S-101 portrayal assets at runtime from in-memory S-101 Portrayal
Catalogue bytes — the host reads the catalogue files; tile57 never touches the
filesystem. Every output buffer is owned by the library; free each with
`tile57_tile_free` (same length). The `tile57` CLI emits the same files.

```c
/* A named blob: a NUL-terminated id (file stem) + its bytes. */
typedef struct { const char *id; const uint8_t *data; size_t len; } tile57_named_bytes;

/* colortables.json (S-52 token -> hex per day/dusk/night) from a colorProfile.xml. */
int tile57_colortables(const uint8_t *xml, size_t xml_len,
                       uint8_t **out, size_t *out_len);

/* linestyles.json (dash patterns + placed symbols) from the S-101 LineStyles. */
int tile57_linestyles(const tile57_named_bytes *line_styles, size_t count,
                      uint8_t **out, size_t *out_len);

/* Sprite atlas: rasterize the S-101 Symbols (SVG) against a palette stylesheet
 * (css) and pack them -> sprite.json + atlas PNG. */
int tile57_sprite_atlas(const tile57_named_bytes *svgs, size_t count,
                        const uint8_t *css, size_t css_len,
                        uint8_t **out_json, size_t *out_json_len,
                        uint8_t **out_png, size_t *out_png_len);

/* Area-fill pattern atlas: tile each AreaFills XML's symbol on its lattice
 * -> patterns.json + patterns.png. */
int tile57_pattern_atlas(const tile57_named_bytes *fills, size_t fill_count,
                         const tile57_named_bytes *symbols, size_t symbol_count,
                         const uint8_t *css, size_t css_len,
                         uint8_t **out_json, size_t *out_json_len,
                         uint8_t **out_png, size_t *out_png_len);
```

## Diagnostics header

[`include/tile57_diag.h`](../../include/tile57_diag.h) (`tile57_diag_*`) exposes
the embedded-Lua / S-101 framework bring-up self-tests — developer tooling, not
part of the embedding API.

## Versioning

Pre-1.0 (`0.1.0`). No external consumers yet, so the ABI is not frozen.
