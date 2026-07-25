---
title: Compose
slug: /c-api/compose
---

# Compose: many charts, one chart

The compositor builds (or loads) the ownership partition over its charts'
embedded coverage, then offers the SAME output set as a single chart, composed:
any tile on demand for the cost of a classify plus one decompress or one
decode/clip, plus the composed view outputs and the composed cursor pick. It
**borrows** the charts — their mmap'd archives and decoded coverage — so the
chart set is never fully resident and the charts must outlive the compositor.
Open once, serve many, close.

```c
/* Opaque runtime-compositor handle. */
typedef struct tile57_compose tile57_compose;

/* Coverage/zoom summary filled by tile57_compose_get_meta. */
typedef struct {
    uint8_t min_zoom;
    uint8_t max_zoom;                 /* deepest zoom served (native + one overscale zoom) */
    uint32_t charts;                  /* coverage-carrying charts held */
    double west, south, east, north;  /* union coverage bounds, degrees */
} tile57_compose_meta;

/* Open a compositor over `n` open charts. Charts whose archives embed no
 * coverage are skipped (they can own no ground); none at all is
 * TILE57_ERR_UNSUPPORTED. partition_path (NULL to skip) names a sidecar —
 * written by tile57_compose_save_partition (the `tile57 bake` CLI emits
 * partition.tpart) — to load and skip the build; a missing/stale one falls back
 * to building. Close with tile57_compose_close BEFORE closing the charts. */
tile57_status tile57_compose_open(tile57_chart *const *charts, size_t n,
                                  const char *partition_path,
                                  tile57_compose **out, tile57_error *err);

/* Compose tile (z,x,y) on demand into RAW (decompressed) MLT — what a live tile
 * server hands its HTTP layer (which gzips on the wire). NULL/0 out with OK =
 * no bytes; *out_owned (NULL to ignore) then distinguishes the two empties:
 *   owned=false: no chart owns this ground — true empty ocean, safe to cache;
 *   owned=true:  a chart owns this ground but produced nothing — transient while
 *                its per-chart bake is running, suspect once bakes are done. */
tile57_status tile57_compose_tile(tile57_compose *c, uint8_t z, uint32_t x, uint32_t y,
                                   uint8_t **out, size_t *out_len, bool *out_owned,
                                   tile57_error *err);

/* The composed view outputs and pick — the render-surface calls across the WHOLE
 * composed set: every covering tile is composed on demand (stitched
 * through the ownership partition) and replayed through the S-52 pixel path.
 * Same parameters, limits, and ownership as the single-chart forms. */
tile57_status tile57_compose_png(tile57_compose *c, double lon, double lat, double zoom,
                                 uint32_t width, uint32_t height, const tile57_mariner *m,
                                 uint8_t **out, size_t *out_len, tile57_error *err);
tile57_status tile57_compose_pdf(tile57_compose *c, double lon, double lat, double zoom,
                                 uint32_t width, uint32_t height, const tile57_mariner *m,
                                 uint8_t **out, size_t *out_len, tile57_error *err);
tile57_status tile57_compose_canvas(tile57_compose *c, double lon, double lat, double zoom,
                                    uint32_t width, uint32_t height, const tile57_mariner *m,
                                    const tile57_canvas_cb *canvas, tile57_error *err);
tile57_status tile57_compose_surface(tile57_compose *c, double lon, double lat, double zoom,
                                     double rotation_rad,
                                     uint32_t width, uint32_t height, const tile57_mariner *m,
                                     const tile57_surface_cb *surface, tile57_error *err);
/* The composed view-level, globally-decluttered TEXT pass (tile57_chart_labels
 * across the composed set): only surviving labels, decluttered across tile AND
 * chart seams, no geometry. */
tile57_status tile57_compose_labels(tile57_compose *c, double lon, double lat, double zoom,
                                    double rotation_rad,
                                    uint32_t width, uint32_t height, const tile57_mariner *m,
                                    const tile57_surface_cb *surface, tile57_error *err);
tile57_status tile57_compose_query(tile57_compose *c, double lon, double lat, double zoom,
                                   const tile57_query_cb *cb, tile57_error *err);

/* The composed draw-ready GPU scene — a whole chart library into one scene, seams
 * stitched across cells. See Render › "Draw-ready GPU scenes" for the
 * tile57_gpu_scene buffers, pixel_ratio, and how to draw the ranges; free with
 * tile57_gpu_scene_free. */
tile57_status tile57_compose_gpu_scene(tile57_compose *c, double lon, double lat, double zoom,
                                       uint32_t width, uint32_t height, const tile57_mariner *m,
                                       double pixel_ratio, tile57_gpu_scene *out, tile57_error *err);

/* Fill *out with the compositor's zoom range + union coverage bounds. */
void tile57_compose_get_meta(tile57_compose *c, tile57_compose_meta *out);

/* Serialize the ownership partition to `path` (a sidecar a later
 * tile57_compose_open loads to skip the build). */
tile57_status tile57_compose_save_partition(tile57_compose *c, const char *path,
                                            tile57_error *err);

/* Release a compositor. Its charts stay open (and stay yours to close). */
void tile57_compose_close(tile57_compose *c);
```

```c
/* bake -> open -> compose -> serve */
tile57_chart *charts[2];
tile57_chart_open("tiles/US5MD1MC.pmtiles", &charts[0], NULL);
tile57_chart_open("tiles/US5MD1MD.pmtiles", &charts[1], NULL);
tile57_compose *cmp = NULL;
tile57_compose_open(charts, 2, "partition.tpart", &cmp, NULL);
uint8_t *tile; size_t n; bool owned;
tile57_compose_tile(cmp, 13, 2359, 3139, &tile, &n, &owned, NULL);
```

The per-surface forms above (`_png` / `_pdf` / `_canvas` / `_surface` / `_labels`,
plus `tile57_compose_gpu_scene`) are the composed twins of the single-chart
[render surfaces](./render.md#render-surfaces) — same parameters, same callbacks,
same ownership, over the whole set instead of one archive.
