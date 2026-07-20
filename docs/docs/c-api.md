---
id: c-api
title: C API
sidebar_position: 6
---

# C API

`libtile57.a` exposes the whole engine behind a thin C ABI —
[`include/tile57.h`](../../include/tile57.h), prefix `tile57_`. It is a shim over
the [Zig API](./zig-api.md); the two stay in lock-step.

The pipeline is three stages, and the header (and this page) is organised the
same way:

- **Bake** — ENC source data in, per-chart PMTiles out. Each chart bakes to
  its own archive at its own compilation scale, with its M_COVR coverage +
  scale embedded in the archive metadata. The bake section also carries the
  raw-source readers (chart inventory, feature extraction, exchange-set
  catalogue).
- **Render** — a **`tile57`** chart handle opens ONE baked archive and answers
  for it with NO composition: metadata (info / SCAMIN / coverage), its stored
  tiles verbatim (`tile57_chart_tile` — the primitive for writing your own
  compositor), the S-52 cursor pick, and view outputs (`tile57_chart_png` / `_pdf` /
  `_canvas` / `_surface`).
- **Compose** — a **`tile57_compose`** handle stitches MANY open charts through
  the ownership partition and offers the SAME output set, composed:
  `tile57_compose_tile` (what a live tile server hands its HTTP layer — the
  bytes are MapLibre Tiles), `_png`, `_pdf`, `_canvas`, `_surface`, `_query`.

Everything is **bake, then compose** (or bake, then render): source charts
bake once to per-chart archives; every output is produced from baked archives.

Style + portrayal-asset generation rounds out the surface: the mariner's S-52
display options become a concrete MapLibre style JSON plus the colortables and
sprite / pattern / glyph atlases it references.

## Errors

Every call that can fail returns a `tile57_status` — `TILE57_OK` (0) or a coarse
cause — and takes an optional caller-owned `tile57_error*` it fills with the
status plus a specific message on failure (a stack local is fine; nothing to
free). Results come back through out-parameters, which are always defined on
return: the result on `TILE57_OK`, `NULL`/0 otherwise. "Nothing produced" is
NOT a failure — a call that finds nothing returns `TILE57_OK` with a
`NULL`/zero out.

```c
typedef enum {
    TILE57_OK = 0,          /* success */
    TILE57_ERR_BADARG,      /* a NULL or out-of-range argument */
    TILE57_ERR_IO,          /* a file/directory could not be opened, read, or written */
    TILE57_ERR_PARSE,       /* malformed input (S-57 chart, PMTiles, partition, JSON) */
    TILE57_ERR_NOMEM,       /* an allocation failed */
    TILE57_ERR_UNSUPPORTED, /* valid but unusable input */
    TILE57_ERR_RENDER,      /* tile generation or rendering failed */
    TILE57_ERR_INTERNAL,    /* an unexpected engine failure */
} tile57_status;

const char *tile57_status_str(tile57_status status);  /* static strerror-style text */

#define TILE57_ERROR_MSG_MAX 256
typedef struct {
    tile57_status status;
    char message[TILE57_ERROR_MSG_MAX];  /* NUL-terminated; "" when no detail */
} tile57_error;
```

```c
tile57_chart *chart = NULL;
tile57_error err;
if (tile57_chart_open("US5MD1MC.pmtiles", &chart, &err) != TILE57_OK) {
    fprintf(stderr, "open failed: %s\n", err.message);  /* "path: reason" */
}
```

:::warning Lifetime + threading
No handle is internally synchronized — use one thread per handle. Each must
also outlive every borrower still holding it: a compositor borrows its charts
(close the compositor first, then the charts), and a path-opened chart mmaps
its file, so the file must stay in place while the chart is open. Calls that
return bytes allocate `*out`; free it with `tile57_free(ptr)`. Input
bytes are copied, so the caller may free them right after the call.
:::

## Bake: ENC charts → per-chart archives

Tile production is a two-step composite model. First bake each chart to its
own PMTiles at its compilation scale; the archive embeds the chart's M_COVR
coverage, compilation scale, and identity in its metadata. Then open a
**compositor** over the archives and serve any `(z, x, y)` tile on demand —
the compositor stitches the overlapping charts through an ownership partition,
handling cross-band zoom.

```c
/* Bake ONE chart (+ its .001.. updates, read from disk) to PMTiles bytes over its
 * native band zoom range. Returned in *out/*out_len (free with tile57_free);
 * NULL/0 when the chart produced no tiles. */
tile57_status tile57_bake_chart_bytes(const char *path, uint8_t **out, size_t *out_len,
                                     tile57_error *err);

/* Bake `n` charts IN PARALLEL across up to `workers` threads (a MEMORY bound —
 * pass a small count). out_bytes[i]/out_lens[i] receive chart i's archive or
 * NULL/0; *out_baked (NULL to ignore) counts the charts that produced bytes. */
tile57_status tile57_bake_charts(const char *const *paths, size_t n, uint32_t workers,
                                uint8_t **out_bytes, size_t *out_lens,
                                size_t *out_baked, tile57_error *err);

/* Walk in_dir for *.000 charts and bake each IN PARALLEL to the SAME relative
 * path under out_dir with a .pmtiles extension (+ an <out>.sha sidecar).
 * INCREMENTAL: a chart whose archive is already at least as new as its whole
 * input (.000 + update chain) is skipped, so a re-run over an unchanged tree
 * bakes nothing — *out_baked counts THIS run, and 0 over a warm cache is
 * success. progress (or NULL) fires per chart, possibly from worker threads;
 * returning false CANCELS the bake (at chart granularity — the charts in flight
 * finish). A cancelled bake is TILE57_OK with *out_baked = what it completed. */
typedef bool (*tile57_bake_progress)(void *ctx, uint32_t done, uint32_t total);
tile57_status tile57_bake_tree(const char *in_dir, const char *out_dir, uint32_t workers,
                               tile57_bake_progress progress, void *progress_ctx,
                               uint32_t *out_baked, tile57_error *err);

/* Read a PMTiles archive's metadata JSON blob (decompressed); NULL/0 when the
 * archive carries none. A per-chart bake embeds the chart's coverage + cscl +
 * date/name under a "coverage" key. */
tile57_status tile57_pmtiles_metadata(const uint8_t *pmtiles, size_t len,
                                      uint8_t **out, size_t *out_len,
                                      tile57_error *err);
```

Every baked feature carries the pick-report properties `class` (object-class
acronym), `cell` (source chart stem), and `s57` (the full S-57 attribute set as a
JSON object) — what `tile57_chart_query` and a host inspector read back.

The `tile57 bake <cell.000 | ENC_ROOT> -o out/` CLI produces this structure
directly: `out/tiles/<STEM>.pmtiles` per chart plus `out/partition.tpart`.

### Read raw S-57 source data

The bake section also reads the source data directly — no handle, no bake — for
a host's import UI:

```c
/* Per-chart metadata of the S-57 data at `path` (one .000, updates applied, or a
 * whole ENC_ROOT) as a JSON array: [{"name","scale","edition","update",
 * "issueDate","agency","bbox"}, ...] — a host's chart-database scan. */
tile57_status tile57_enc_charts(const char *path, uint8_t **out, size_t *out_len,
                               tile57_error *err);

/* Features for comma-separated object-class acronyms (e.g. "DEPARE,DRGARE") as
 * a GeoJSON FeatureCollection: lon/lat geometry, properties = {"class", plus the
 * full S-57 acronym->value attribute map}. NULL/0 when nothing matched. */
tile57_status tile57_enc_features(const char *path, const char *classes,
                                  uint8_t **out, size_t *out_len, tile57_error *err);

/* The same over in-memory base .000 bytes (from a zip member, say). */
tile57_status tile57_enc_features_bytes(const uint8_t *base, size_t len,
                                        const char *classes,
                                        uint8_t **out, size_t *out_len, tile57_error *err);

/* Decode a CATALOG.031 exchange-set catalogue into a JSON array of its CATD
 * entries — file path, longName (chart title), impl (BIN/ASC/TXT), bbox. */
tile57_status tile57_enc_catalog(const uint8_t *catalog_031, size_t len,
                                 uint8_t **out, size_t *out_len, tile57_error *err);
```

The CLI mirrors these as `tile57 cells`, `tile57 features`, and
`tile57 catalog`.

## Render: the `tile57_chart` handle

A `tile57_chart` is ONE baked PMTiles archive, opened for metadata and
output — with no composition (the compositor below offers the same outputs
across many charts). Open it from a path (mmap'd — a whole chart library can
be open without being resident) or from bytes (copied).

```c
const char *tile57_version(void);   /* "0.3.0" */

/* Opaque chart handle: one open baked archive. */
typedef struct tile57_chart tile57_chart;

tile57_status tile57_chart_open(const char *path, tile57_chart **out, tile57_error *err);
tile57_status tile57_chart_open_bytes(const uint8_t *pmtiles, size_t len,
                                tile57_chart **out, tile57_error *err);

/* Vector-tile encodings an archive can store (reported in tile57_info.tile_type;
 * the engine bakes MLT). */
typedef enum {
    TILE57_TILE_TYPE_MVT = 1, /* Mapbox Vector Tile */
    TILE57_TILE_TYPE_MLT = 2, /* MapLibre Tile (the bake default) */
} tile57_tile_type;

/* Fixed chart metadata, for a host that frames its own camera. Bounds/anchor
 * validity are flagged (false -> those fields are 0). native_scale is the
 * compilation scale 1:N the bake embedded (0 = unknown — derive from the zoom
 * band). */
typedef struct {
    uint8_t  min_zoom, max_zoom;
    uint32_t bands;                                 /* bitmask: bit r = band rank r present */
    bool     has_bounds; double west, south, east, north;
    bool     has_anchor; double anchor_lat, anchor_lon, anchor_zoom;
    uint8_t  tile_type;                             /* tile57_tile_type */
    int32_t  native_scale;
} tile57_info;
void tile57_chart_get_info(tile57_chart *chart, tile57_info *out);

/* The distinct SCAMIN denominators present in the chart (ascending); NULL/0 when
 * none. Free with tile57_free((uint8_t*)*out, *out_len * sizeof(int32_t)). */
tile57_status tile57_chart_scamin(tile57_chart *chart, int32_t **out, size_t *out_len,
                            tile57_error *err);

/* The chart's M_COVR data-coverage polygons, from the coverage the bake embedded:
 * ring() is called once per polygon with its exterior ring as npts interleaved
 * lon,lat doubles (valid only during the call). OK with no calls when the archive
 * embeds none. */
typedef struct {
    void *ctx;
    void (*ring)(void *ctx, const double *lonlat, size_t npts);
} tile57_coverage_cb;
tile57_status tile57_chart_coverage(tile57_chart *chart, const tile57_coverage_cb *cb,
                              tile57_error *err);

/* The chart's own stored tile at (z,x,y), decompressed (MLT or MVT per
 * tile57_info.tile_type), with NO composition — the per-archive primitive for
 * an embedder writing its own compositor. NULL/0 when the archive has no tile
 * there. */
tile57_status tile57_chart_tile(tile57_chart *chart, uint8_t z, uint32_t x, uint32_t y,
                          uint8_t **out, size_t *out_len, tile57_error *err);

/* Release a chart and all cached tiles (not while a compositor still holds it). */
void tile57_chart_close(tile57_chart *chart);
```

### Query the features under a point (object query / pick)

The S-52 cursor pick. Given a lon/lat and the current view `zoom`, tile57 replays
the tile at that zoom and reports every feature the point falls in — an area you
are inside, or a line or point symbol within a small radius. Each hit calls you
back with the S-57 object-class acronym, the attribute JSON (acronym to value),
and the source chart name. This is what a chart application shows when you tap a
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
                    const char *chart, size_t chart_len);
} tile57_query_cb;

/* Calls cb->feature once per displayed feature under (lon,lat) at view `zoom`.
 * Callback pointers are valid only during that call. */
tile57_status tile57_chart_query(tile57_chart *chart, double lon, double lat, double zoom,
                           const tile57_query_cb *cb, tile57_error *err);
```

The class and chart name come through for any hit; the attribute JSON is filled in
from the `s57` pick property baked into the tiles (empty if a chart was baked
without pick attributes).

### Render a finished view (PNG / PDF), one chart

The [native S-52 rendering engine](./rendering.md) draws a view of the chart —
centre + fractional zoom + pixel size — by replaying the archive's baked tiles
through the S-52 pixel path: one scene across every covering tile, labels
decluttered over the whole canvas, catalogue symbols replayed as vectors. The
mariner's live-swappable settings (colour scheme, safety-contour danger and
sounding swaps, category/SCAMIN/text gates, size scale) evaluate at render
time; the rest of the portrayal context was fixed at bake time.

`width`/`height` must be 1..16384 per side; `m` NULL = canonical defaults
(`tile57_mariner_defaults`). The `tile57_mariner` settings struct is shared
with the [style builders](#build-a-maplibre-style) below.

```c
/* PNG raster in *out/*out_len (free with tile57_free). */
tile57_status tile57_chart_png(tile57_chart *chart, double lon, double lat, double zoom,
                         uint32_t width, uint32_t height,
                         const tile57_mariner *m,
                         uint8_t **out, size_t *out_len, tile57_error *err);

/* Its vector twin: the SAME scene as a deterministic single-page PDF
 * (1 px = 1 pt, 72 dpi; vector fills + glyph-outline text). */
tile57_status tile57_chart_pdf(tile57_chart *chart, double lon, double lat, double zoom,
                         uint32_t width, uint32_t height,
                         const tile57_mariner *m,
                         uint8_t **out, size_t *out_len, tile57_error *err);
```

The composed twins — `tile57_compose_png` / `tile57_compose_pdf`, same
parameters over a `tile57_compose` — render the same view across the WHOLE
composed set (see below).

### Render to a host surface (vector callbacks)

Instead of a finished raster, tile57 can hand you the portrayed scene as a stream
of draw calls in world space. A GPU host tessellates that stream once, then pans
and zooms by transforming the vertices each frame, so symbols and text stay a
constant size on screen and no re-portrayal is needed while the view moves.

You fill in a `tile57_surface_cb` vtable and pass it to `tile57_chart_surface` (or
`tile57_compose_surface` for the composed set). Area and line geometry come in
web-mercator world
coordinates (the range 0 to 1, with y pointing down). Point symbols, soundings, and
text come as a world anchor plus a small outline in reference pixels, so you can
draw them at a fixed size on screen. Every call carries the feature's SCAMIN, so you
can hide it by zoom in a shader — together with the display category it came in on,
so you can honour the S-52 rule that SCAMIN never hides a display-base feature
(`f->disp_cat == TILE57_DISP_BASE` => draw it at every zoom).

You pass the view rotation (`rotation_rad`, 0 = north-up) and apply it to your own
transform. Each rotatable call carries a `tile57_rot_align` saying what its angle is
measured against: `TILE57_ALIGN_VIEWPORT` marks stay upright on screen (a buoy, an
ordinary label); `TILE57_ALIGN_MAP` marks are chart-relative and you add the view
rotation, so they turn with the chart — ORIENT symbols, every linestyle-embedded
symbol (traffic-lane and tidal-stream arrows, bank/dyke ticks), and depth-contour
value labels laid out along their contour.

```c
typedef struct { double x, y; } tile57_world_point;   /* web-mercator 0..1, y down */
typedef struct { const tile57_world_point *pts; uint32_t n;
                 const uint32_t *ring_starts; uint32_t ring_count; } tile57_world_rings;
/* The S-52 display category the feature came in on. */
typedef enum { TILE57_DISP_BASE=0, TILE57_DISP_STANDARD=1, TILE57_DISP_OTHER=2 } tile57_disp_cat;

typedef struct { const char *cls; int64_t scamin; int32_t display_priority;
                 tile57_disp_cat disp_cat; } tile57_feature;

/* What a rotatable call's angle is referenced to: VIEWPORT = screen (stay upright),
 * MAP = chart (add the view rotation, turn with the chart). */
typedef enum { TILE57_ALIGN_VIEWPORT = 0, TILE57_ALIGN_MAP = 1 } tile57_rot_align;

typedef struct {
    void *ctx;                                 /* handed back to every call */
    void (*fill_area)  (void *ctx, const tile57_feature *f, const tile57_world_rings *rings,
                        tile57_color color, int even_odd);
    void (*stroke_line)(void *ctx, const tile57_feature *f, const tile57_world_rings *lines,
                        float width_px, float dash_on, float dash_off, tile57_color color);
    /* rings arrive already rotated; align says whether to also add the view rotation. */
    void (*draw_symbol)(void *ctx, const tile57_feature *f, tile57_world_point anchor,
                        const tile57_local_rings *rings, tile57_color color, int even_odd,
                        float stroke_w, tile57_rot_align align);
    /* text_group is the LABEL's S-52 text group (§14.5): 11 = important text (always
     * shown — it ignores the mariner's text switches), 21/26/29 names, 23 light
     * descriptions, 0 none. It rides the callback rather than tile57_feature because
     * one feature can carry several labels in different groups. */
    void (*draw_text)  (void *ctx, const tile57_feature *f, tile57_world_point anchor,
                        const tile57_local_rings *glyphs, tile57_color color, tile57_color halo,
                        float halo_px, tile57_rot_align align, int32_t text_group);
    /* Optional. Leave NULL to get vector outlines from the two calls above; set them
     * to draw point symbols and area patterns from the sprite atlas as textured quads.
     * Draw the sprite at rot_deg + (align == MAP ? view_rotation : 0). */
    void (*draw_sprite) (void *ctx, const tile57_feature *f, const char *name, size_t name_len,
                         tile57_world_point anchor, float rot_deg, tile57_rot_align align,
                         float half_w_px, float half_h_px);
    void (*draw_pattern)(void *ctx, const tile57_feature *f, const char *name, size_t name_len,
                         const tile57_world_rings *rings);
    /* Optional. Text as a UTF-8 string for a host SDF glyph atlas (tile57_bake_glyph_sdf),
     * instead of tessellated outlines. Rotate the run by rot_deg + (align == MAP ?
     * view_rotation : 0). */
    void (*draw_text_str)(void *ctx, const tile57_feature *f, tile57_world_point anchor,
                          float ox_px, float oy_px, const char *text, size_t text_len,
                          float size_px, float rot_deg, tile57_rot_align align,
                          tile57_color color, tile57_color halo, int32_t text_group);
} tile57_surface_cb;

/* Portray the view once and drive the callbacks. rotation_rad is the view rotation
 * (radians clockwise; 0 = north-up), which you apply to your transform. */
tile57_status tile57_chart_surface(tile57_chart *chart, double lon, double lat, double zoom,
                             double rotation_rad,
                             uint32_t width, uint32_t height,
                             const tile57_mariner *m,
                             const tile57_surface_cb *surface, tile57_error *err);
```

Set `draw_sprite` and `draw_pattern` once you have the sprite atlas loaded (see
[`tile57_bake_sprite_mln`](#generate-portrayal-assets)). tile57 then hands point
symbols, soundings, and area patterns by name, and you draw them as atlas quads —
smoothed by texture filtering and cheaper than tessellating outlines. If you leave
those two fields NULL, the same features arrive as vector outlines instead.

tile57 also declutters overlapping text for you before it makes the calls (symbols
and soundings always draw, per S-52), so you don't repeat that work — and it lays
out depth-contour values along their contours, so you get the same labelled contours
as the raster and MapLibre outputs.

Tell it your framebuffer density with `m.device_scale` (2.0 on a Retina backing
store). The engine sizes text and symbols in reference pixels and you draw them, so
it needs the density to size a label's collision box in the pixels you actually
paint. Draw at 2x while leaving `device_scale` at 1.0 and the declutter reserves
space for glyphs half the size that land on screen; the view comes out overlapping
even though the engine decluttered it correctly for the size it was told.

#### Paint order

The calls arrive in S-52 paint order. The engine buffers the scene and sorts it
before calling you, per S-52 Presentation Library §10.3.4.1:

1. **`display_priority`** — the dominant key, and it "applies irrespective of whether an
   object is a point, line or area". A light sector arc at priority 24 paints over
   a wreck symbol at 12, even though one is a line and the other a point.
2. **geometry class** — a tiebreak used *only* where `display_priority` is equal:
   areas, then area patterns, then lines, then point symbols, then soundings.
3. **emission order** — the tiebreak where both of the above are equal.

Text is drawn last regardless of priority (§10.3.4.1, §16 rule 3). Draw the calls
in the order you receive them and the picture is right; you need no sort of your own.

That holds only as long as you *preserve* the order. A GPU renderer usually batches
by draw type — all fills, then all sprites, then all text — to keep pipeline
switches down, and batching reorders the stream by construction: it lifts every call
of one type out of the sequence the engine placed it in. Global paint order is then
broken again, and broken in the way that looks fine on an empty stretch of water and
wrong in a harbour.

**Do not batch by draw type and then sort each batch by `display_priority`.** That
reproduces the exact inversion this ordering exists to prevent — it makes geometry
class dominant and `display_priority` subordinate, so every sprite covers every line
whatever the priorities say. If you must batch, batch by `display_priority` *band* and
draw the bands in ascending order, switching pipelines within a band as the class
tiebreak requires. `display_priority` is exposed so you can rebuild the real order, not so
you can sort inside a per-type bucket.

A host that batches per tile must go further: sorting within a tile still leaves
paint order broken across tiles, because tiles are drawn one after another. Walk
the priority bands *outside* the tile loop.

Both text callbacks carry the label's `text_group`, so a host can style text by its
S-52 role rather than by its feature — draw group 11 (important text: vertical
clearances, bridge and cable legends) larger or bold, and leave ordinary names at
their normal weight. The group is per-LABEL, not per-feature: the same feature can
emit a name in group 26 and a clearance in group 11 on consecutive calls.

The per-tile form `tile57_chart_tile_surface` takes no rotation: a tile is
tessellated once, north-up, and re-transformed on the GPU each frame, so a
continuously-turning course-up view never re-portrays or re-tessellates it — the
`align` flags carry everything the host needs to turn the right marks with the chart.

Because `tile57_chart_tile_surface` declutters **within** each tile, a label that
straddles a tile seam collides or repeats across the join. When you cache geometry
per tile but want labels resolved across the whole view, add a single
`tile57_chart_labels` pass (`tile57_compose_labels` for the composed set). It walks
the view's covering tiles into **one** collision pool and emits **only** the
surviving text — through the same `draw_text_str` / `draw_text` callbacks, at the
same world anchors as `tile57_chart_surface` — and draws no fills, lines, symbols, or
soundings. So the host draws geometry + symbols from its per-tile cache and calls
this once per frame (or per view change) to overlay the globally-decluttered text
last (text is drawn on top).

It is cheap enough to call on every view change. Each covering tile is portrayed
once and its label *candidates* — what a label says, how it is shaped, where it is
anchored — memoize on the chart or compositor. Neither zoom nor rotation is part of
that memo: the collision box, the depth-contour legibility gate and the upright flip
on a tangent-rotated run all derive per call, so a pan, zoom or rotation over tiles
already seen does no portrayal work and settles in well under a millisecond. Only
the first view of a region pays, and changing the palette or any mariner setting
retires the memo (a candidate carries a resolved colour and the text the mariner's
settings selected). The memo is bounded at a few hundred tiles and released with the
handle.

```c
/* View-level, globally-decluttered TEXT pass: emits only surviving labels
 * (draw_text_str / draw_text), no geometry. Same anchors/space as
 * tile57_chart_surface; rotation_rad declutters in the screen frame. */
tile57_status tile57_chart_labels(tile57_chart *chart, double lon, double lat, double zoom,
                             double rotation_rad,
                             uint32_t width, uint32_t height,
                             const tile57_mariner *m,
                             const tile57_surface_cb *surface, tile57_error *err);
```

There is a pixel-space twin, `tile57_chart_canvas` with a `tile57_canvas_cb` vtable,
that emits the SAME portrayal as resolved paint-order draw calls in canvas
pixels — for a host that wants the engine's own paint pipeline without the PNG
encode. Both callback forms have composed twins (`tile57_compose_canvas` /
`tile57_compose_surface`).

## Compose: many charts, one chart

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

/* The composed view outputs and pick — the section-4 calls across the WHOLE
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

tile57_status tile57_bake_assets(const char *catalog_dir, tile57_assets *out,
                                 tile57_error *err);
void tile57_assets_free(tile57_assets *out);
```

`tile57_bake_sprite_mln` is a focused variant that fills only the `sprite_json` /
`sprite_png` fields with a MapLibre **sprite-mln** atlas: every S-101 symbol packed
into one PNG, each atlas cell centered on its symbol's pivot, plus a JSON index of
`{name: {x, y, width, height, pixelRatio}}`. A GPU host loads this atlas once and
draws point symbols and area patterns as textured quads by name — the atlas the
[host-surface `draw_sprite`/`draw_pattern` callbacks](#render-to-a-host-surface-vector-callbacks)
hand back. `tile57_bake_glyph_sdf` is its text counterpart: an RGBA
signed-distance-field atlas of the label font, for a host that draws text as SDF
quads. Free either with `tile57_assets_free` as above.

```c
tile57_status tile57_bake_sprite_mln(const char *catalog_dir, tile57_assets *out,
                                     tile57_error *err);
tile57_status tile57_bake_glyph_sdf(tile57_assets *out, tile57_error *err);
```

## Build a MapLibre style

`tile57_style_build` turns a MapLibre style template + the mariner's S-52 display
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
    double text_size_scale;         /* extra size multiplier for TEXT labels, on top of
                                     * size_scale (the engine scales glyph + collision box
                                     * together). 1.0 = none; 0 reads as 1.0. */
    double sounding_size_scale;     /* extra size multiplier for SOUNDINGS, on top of
                                     * size_scale (scales each digit + spacing together).
                                     * 1.0 = none; 0 reads as 1.0. */
    double device_scale;            /* device px per reference px — the HiDPI density the
                                     * SURFACE paths are drawn at (2.0 on a Retina backing
                                     * store). Describes the DISPLAY where size_scale
                                     * describes the mariner; the two multiply. Sizes text
                                     * and symbols AND their collision boxes in the units
                                     * the host actually draws in. The pixel outputs ignore
                                     * it (that density is already in the requested
                                     * width/height). 1.0 = a 1x framebuffer; 0 reads as
                                     * 1.0. */
} tile57_mariner;

void tile57_mariner_defaults(tile57_mariner *m);   /* canonical defaults, date_view = "" */

/* enabled_bands: NULL = show all; else only features whose band rank is in the
 * array. scamin: the distinct SCAMIN denominators present in the source (e.g.
 * from tile57_chart_scamin) — when non-NULL the `_scamin` layers split into per-value
 * native-minzoom buckets; scamin_lat is the representative latitude. */
tile57_status tile57_style_build(const char *template_json, size_t template_len,
                                 const tile57_mariner *m,
                                 const char *colortables_json, size_t colortables_len,
                                 const int32_t *enabled_bands, size_t enabled_band_count,
                                 const int32_t *scamin, size_t scamin_count, double scamin_lat,
                                 uint8_t **out, size_t *out_len, tile57_error *err);

/* Minimal MapLibre style-mutation ops to turn the style for `old_m` into the style
 * for `new_m` (same inputs as tile57_style_build) — for flicker-free mariner
 * toggles. Writes a JSON op array to *out/*out_len (free with tile57_free). */
tile57_status tile57_style_diff(const char *template_json, size_t template_len,
                                const tile57_mariner *old_m, const tile57_mariner *new_m,
                                const char *colortables_json, size_t colortables_len,
                                const int32_t *enabled_bands, size_t enabled_band_count,
                                const int32_t *scamin, size_t scamin_count, double scamin_lat,
                                uint8_t **out, size_t *out_len, tile57_error *err);
```

The S-52 colortables and base style template are baked into the library, so a host
can build a complete style with no on-disk catalogue or template file (free each
buffer with `tile57_free`):

```c
/* colortables.json (S-52 token -> hex per day/dusk/night) from the baked profile. */
tile57_status tile57_colortables_default(uint8_t **out, size_t *out_len,
                                         tile57_error *err);

/* Base MapLibre style template (layers + chart source + sprite/glyph URLs). scheme
 * selects the palette; source_tiles is the {z}/{x}/{y} URL (NULL -> a default
 * pmtiles:// source); sprite/glyphs are base URLs (NULL omits those layers);
 * minzoom is the chart source's tile floor, emitted verbatim (pass the archive's
 * real minzoom); maxzoom 0 -> engine default. tile_encoding is the source's tile
 * type (from tile57_info.tile_type): TILE57_TILE_TYPE_MLT emits "encoding":"mlt"
 * on the source so maplibre-gl >= 5.12 decodes MLT natively; 0 / MVT emits
 * nothing. */
tile57_status tile57_style_template(tile57_scheme scheme, const char *source_tiles,
                                    const char *sprite, const char *glyphs,
                                    uint32_t minzoom, uint32_t maxzoom,
                                    uint8_t tile_encoding,
                                    uint8_t **out, size_t *out_len, tile57_error *err);
```

## Util: warmup + free

```c
/* Populate the process-global read-only registries (feature catalogue +
 * complex-linestyle table) on the calling thread. Call ONCE on your main thread
 * before opening or baking charts from worker threads, so concurrent bake/render is
 * race-free. Idempotent. */
void tile57_warmup(void);

/* Free ANY buffer the engine returned (tiles, style JSON, the scamin array,
 * colortables, …) — length-prefixed, so the pointer is all it needs. */
void tile57_free(void *ptr);
```

## Diagnostics header

[`include/tile57_diag.h`](../../include/tile57_diag.h) (`tile57_diag_*`) exposes
the embedded-Lua / S-101 framework bring-up self-tests — developer tooling, not
part of the embedding API.

## Versioning

Pre-1.0 (`0.3.0`). No external consumers yet, so the ABI is not frozen.
