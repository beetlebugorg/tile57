---
id: c-api
title: C API
sidebar_position: 4
---

# The libchartplotter C API

`libchartplotter.a` is the Zig tile generator behind a hand-written C ABI. The
public header is `include/chartplotter.h`; the symbol prefix is `chartplotter_`. The library
opens a chart **source** from in-memory bytes (a PMTiles archive or a raw S-57 ENC
cell) and serves decompressed **Mapbox Vector Tiles** by `(z, x, y)`.

It is renderer-agnostic — in this repo the consumer is MapLibre Native via the
`ChartTileSource` adapter (`app/chart_tile_source.*`), but any MVT consumer works.

:::note Naming
The Zig sources live under `tilegen/` (the implementation really is a tile
generator); only the artifact and this ABI carry the `chartplotter` name.
:::

## Contracts

:::warning Lifetime: the source must outlive the renderer
A `chartplotter_source` must outlive every renderer/adapter still holding it. In the
MapLibre hosts the source is captured by a long-lived `FileSource` and is
intentionally **never** closed before process exit — closing it first would be a
use-after-free during `Map` teardown. Call `chartplotter_source_close` only once nothing can
still call `chartplotter_tile_get`.
:::

- **Threading.** A `chartplotter_source` is **not** internally synchronized: never call into
  the same source from multiple threads at once (the tile cache is mutated by
  `chartplotter_tile_get` without a lock). Distinct sources are independent. The MapLibre
  hosts touch each source from a single resource-loader thread.
- **Memory.** `chartplotter_tile_get` allocates `*out`; release it with `chartplotter_tile_free`,
  passing the **same length**. Input bytes to `chartplotter_source_open` are copied; the
  caller may free them immediately after the call returns.

## Reference

```c
const char *chartplotter_version(void);   /* "0.1.0"; see CHARTPLOTTER_VERSION_* macros */

typedef struct chartplotter_source chartplotter_source;

typedef enum {
    CHARTPLOTTER_FORMAT_AUTO     = 0,   /* sniff: PMTiles first, then S-57 cell */
    CHARTPLOTTER_FORMAT_PMTILES  = 1,
    CHARTPLOTTER_FORMAT_S57_CELL = 2,
} chartplotter_format;

/* Open a source from bytes. rules_dir = S-101 portrayal rules for S-57 cells
 * (NULL = built-in default: CHARTPLOTTER_S101_RULES env, else the vendored
 * catalogue). Bytes are copied. NULL on error. */
chartplotter_source *chartplotter_source_open(const uint8_t *data, size_t len,
                          chartplotter_format format, const char *rules_dir);

chartplotter_format chartplotter_source_format(chartplotter_source *src);   /* resolved after AUTO sniff */
void      chartplotter_source_close(chartplotter_source *src);
void      chartplotter_source_zoom_range(chartplotter_source *src, uint8_t *min_z, uint8_t *max_z);
bool      chartplotter_source_bounds(chartplotter_source *src,
                           double *west, double *south, double *east, double *north);

typedef enum {
    CHARTPLOTTER_TILE_OK    =  1,   /* *out/*out_len set; free with chartplotter_tile_free */
    CHARTPLOTTER_TILE_EMPTY =  0,   /* valid tile, no features */
    CHARTPLOTTER_TILE_ERROR = -1,   /* generation/decode failure */
} chartplotter_tile_status;

chartplotter_tile_status chartplotter_tile_get(chartplotter_source *src, uint8_t z, uint32_t x, uint32_t y,
                           uint8_t **out, size_t *out_len);
void           chartplotter_tile_free(uint8_t *ptr, size_t len);
void           chartplotter_source_clear_cache(chartplotter_source *src);  /* bound memory */
```

- **`chartplotter_source_open` is the only opener.** `CHARTPLOTTER_FORMAT_AUTO` sniffs PMTiles then
  falls back to an S-57 cell; pass a specific `chartplotter_format` to skip the sniff (and
  fail if the bytes are not that format). `chartplotter_source_format` reports what was
  resolved.
- **`chartplotter_source_bounds`** returns `false` for degenerate or near-global extents, so
  a host can fall back to its own camera (the MapLibre hosts feed a `true` result
  to `cameraForLatLngBounds`).
- **`chartplotter_source_clear_cache`** drops the in-process tile cache; later `chartplotter_tile_get`
  calls regenerate/decode. Useful for long-running interactive hosts.

## Minimal usage

```c
#include "chartplotter.h"

chartplotter_source *src = chartplotter_source_open(bytes, len, CHARTPLOTTER_FORMAT_AUTO, /*rules_dir*/ NULL);
if (!src) { /* not a PMTiles archive or S-57 cell */ }

uint8_t min_z, max_z;
chartplotter_source_zoom_range(src, &min_z, &max_z);

uint8_t *mvt = NULL; size_t mvt_len = 0;
switch (chartplotter_tile_get(src, /*z*/ 13, /*x*/ 2356, /*y*/ 3134, &mvt, &mvt_len)) {
    case CHARTPLOTTER_TILE_OK:    /* hand mvt[0..mvt_len] to the renderer */
                        chartplotter_tile_free(mvt, mvt_len); break;
    case CHARTPLOTTER_TILE_EMPTY: /* nothing here */            break;
    case CHARTPLOTTER_TILE_ERROR: /* generation failed */       break;
}

/* ... only after the renderer is gone: */
chartplotter_source_close(src);
```

## Diagnostics header

`include/chartplotter_diag.h` (`chartplotter_diag_*`) exposes the embedded-Lua / S-101
framework bring-up self-tests. These are developer tooling — they back
`chartplotter-render`'s `--s101*` subcommands and the test suite — not part of the
embedding API.

## Versioning

Pre-1.0 (`0.1.0`). There are no external consumers yet, so the ABI is not frozen.
The `CHARTPLOTTER_VERSION_{MAJOR,MINOR,PATCH}` macros and `chartplotter_version()` let a host
record what it built against.
