---
id: c-api
title: C APIs
sidebar_position: 4
---

# C APIs

chartplotter-native is two C libraries:

- **`libchartplotter`** — the headless chart **renderer**. Draws an S-52 chart to
  a PNG offscreen with MapLibre Native. Header
  [`include/chartplotter.h`](../../include/chartplotter.h), prefix `chartplotter_`.
  (The interactive window is a separate Qt6 app — see below.)
- **`libtile57`** — the S-57 **tile generator** underneath it. Opens a chart
  source (PMTiles / S-57 cell / ENC_ROOT) and serves Mapbox Vector Tiles by
  `(z, x, y)`. Header [`include/tile57.h`](../../include/tile57.h), prefix
  `tile57_`.

Most embedders want `libchartplotter` (it pulls in `libtile57` + MapLibre). Reach
for `libtile57` directly only if you have your own MVT renderer.

## libchartplotter — the chart renderer

```c
#include "chartplotter.h"

const char *chartplotter_version(void);   /* "0.1.0" */

/* Render a chart to a PNG offscreen — no window. chart_path is a PMTiles archive,
 * a raw S-57 .000 cell, or an ENC_ROOT directory. rules_dir = S-101 rules (NULL
 * auto-resolves). Returns 0 on success. */
int chartplotter_render_png(const char *chart_path, const char *style_path,
                            const char *rules_dir,
                            double lat, double lon, double zoom,
                            uint32_t width, uint32_t height, float pixel_ratio,
                            const char *out_png);
```

- One chart is active per process (the MapLibre FileSource factory is global).

```c
/* Render an ENC_ROOT to a PNG, fitting the data bounds (zoom 0 -> fit). */
chartplotter_render_png("/path/to/ENC_ROOT", "style/chart-zig-day.json",
                        /*rules_dir*/ NULL, 0, 0, /*zoom*/ 0,
                        2048, 1536, 1.0f, "chart.png");
```

The interactive window is a separate **Qt6** app — `chartplotter-qt` (`app/qt`,
built via `scripts/build-qmaplibre.sh`) — that loads a baked chart bundle's
`style.json` into a [QMapLibre](https://github.com/maplibre/maplibre-native-qt)
widget; it links QMapLibre, not `libchartplotter`/mbgl directly.

## libtile57 — the tile generator

`libtile57.a` opens a chart **source** from in-memory bytes and serves
decompressed MVT by `(z, x, y)`. The bytes come from the Zig tile generator
(`engine/`); the consumer here is `libchartplotter`'s `ChartTileSource`, but the
ABI is renderer-agnostic.

:::warning Lifetime: the source must outlive the renderer
A `tile57_source` must outlive every renderer/adapter still holding it; in the
renderer the source is captured by a long-lived `FileSource` and is closed only at
process exit (closing it earlier is a use-after-free during `Map` teardown).
:::

- **Threading**: a `tile57_source` is not internally synchronized — one thread per
  source.
- **Memory**: `tile57_tile_get` allocates `*out`; free with `tile57_tile_free`
  (same length). Input bytes are copied; the caller may free them after the call.

```c
#include "tile57.h"

typedef struct tile57_source tile57_source;
typedef enum { TILE57_FORMAT_AUTO=0, TILE57_FORMAT_PMTILES=1, TILE57_FORMAT_S57_CELL=2 } tile57_format;

/* Open from bytes. AUTO sniffs PMTiles then S-57. rules_dir = S-101 rules for
 * cells (NULL -> default). Bytes copied. NULL on error. */
tile57_source *tile57_source_open(const uint8_t *data, size_t len,
                                  tile57_format format, const char *rules_dir);

/* One ENC cell: base .000 + its sequential .001… updates (parallel arrays). */
typedef struct {
    const uint8_t *base; size_t base_len;
    const uint8_t *const *updates; const size_t *update_lens; size_t update_count;
} tile57_cell_input;

/* Open an ENC_ROOT: every cell overlaid, each cell's updates applied. */
tile57_source *tile57_source_open_cells(const tile57_cell_input *cells, size_t count,
                                        const char *rules_dir);

tile57_format tile57_source_format(tile57_source *src);   /* resolved after AUTO */
void          tile57_source_close(tile57_source *src);
void          tile57_source_zoom_range(tile57_source *src, uint8_t *min_z, uint8_t *max_z);
bool          tile57_source_bounds(tile57_source *src, double *w, double *s, double *e, double *n);

typedef enum { TILE57_TILE_OK=1, TILE57_TILE_EMPTY=0, TILE57_TILE_ERROR=-1 } tile57_tile_status;
tile57_tile_status tile57_tile_get(tile57_source *src, uint8_t z, uint32_t x, uint32_t y,
                                   uint8_t **out, size_t *out_len);
void               tile57_tile_free(uint8_t *ptr, size_t len);
void               tile57_source_clear_cache(tile57_source *src);
```

The host (not the library) walks an ENC_ROOT directory and reads the files — Zig
0.16 gates filesystem access behind `std.Io`. `app/enc_root.hpp` (`cpn::openPath`)
is the reference implementation, used by `chartplotter-render`.

## Diagnostics header

[`include/tile57_diag.h`](../../include/tile57_diag.h) (`tile57_diag_*`) exposes
the embedded-Lua / S-101 framework bring-up self-tests — developer tooling behind
`chartplotter-render`'s `--s101*` subcommands, not part of either embedding API.

## Versioning

Pre-1.0 (`0.1.0`). No external consumers yet, so the ABIs are not frozen.
