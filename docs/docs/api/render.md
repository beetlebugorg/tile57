---
title: Render
slug: /c-api/render
---

# Render: the `tile57_chart` handle

A `tile57_chart` is ONE baked PMTiles archive, opened for metadata and
output — with no composition (the [compositor](./compose.md) offers the same
outputs across many charts). Open it from a path (mmap'd — a whole chart library can
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

/* The label languages the chart states besides English, as ISO 639-2 codes
 * (ascending); NULL/0 when none. A host offers the mariner these: a
 * preferred_language outside the set draws the portrayed name, except on an
 * S-57 chart, whose one national name is coded "und" and answers any language.
 * One allocation holds the pointer array and the codes; free *out with
 * tile57_free. The compositor borrows its charts, so a host reading a quilt
 * unions the sets from the charts it opened, the way it does for SCAMIN. */
tile57_status tile57_chart_languages(tile57_chart *chart, const char *const **out,
                            size_t *out_len, tile57_error *err);

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

## Query the features under a point (object query / pick)

The S-52 cursor pick. Given a lon/lat and the current view `zoom`, tile57 replays
the tile at that zoom and reports every feature the point falls in — an area you
are inside, a line within a small radius, or a symbol whose drawn mark covers the
point. A buoy's or beacon's mark stands above its charted position, and the pick
follows what is drawn. Each hit calls you back with the S-57 object-class acronym,
the attribute JSON (acronym to value), and the source chart name. This is what a
chart application shows when you tap a feature to see what it is.

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

## Render surfaces

Every render surface draws the SAME portrayal of the SAME view — centre + fractional
zoom + pixel size — replaying the archive's baked tiles through the S-52 pixel path:
one scene across every covering tile, labels decluttered over the whole canvas,
catalogue symbols replayed as vectors. They differ only in what they hand back: a
finished raster (PNG/PDF), a stream of world-space draw calls (host surface), or
draw-ready GPU buffers. The mariner's live-swappable settings (colour scheme,
safety-contour danger and sounding swaps, category/SCAMIN/text gates, size scale)
evaluate at render time; the rest of the portrayal context was fixed at bake time.

`width`/`height` must be 1..16384 per side; `m` NULL = canonical defaults
(`tile57_mariner_defaults`). The `tile57_mariner` settings struct is shared
with the [style builders](./style.md).

### Finished view (PNG / PDF), one chart

The [native S-52 rendering engine](../rendering.md) draws the view straight to
pixels or a deterministic single-page PDF.

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
composed set (see [Compose](./compose.md)).

### Host surface (vector callbacks)

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
[`tile57_bake_sprite_mln`](./assets.md)). tile57 then hands point
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

#### Per-tile surface + cross-view labels

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

### Draw-ready GPU scenes (batched buffers)

> This section is the struct reference. For the whole GPU contract end to end —
> these buffers plus the uniform block, the shaders, `tile57_gpu_batch`, and a
> worked frame loop — see [GPU Rendering](../gpu-rendering.md).

The [host surface callback](#host-surface-vector-callbacks) hands back a *stream* of
draw calls in paint order. A GPU host can't draw that stream directly — it must batch
by pipeline, and batching reorders it (see [Paint order](#paint-order)). Rebuilding
the correct order then falls to the host, which means owning a tessellator and a copy
of the S-52 ordering rules.

`tile57_chart_gpu_scene` does that work for you. It hands geometry back **already
triangulated, already in paint order, and already split into ranges that each draw
with one pipeline**. Upload the buffers, then walk the ranges in order and draw each
one — that is the whole host obligation. The host still owns only what is genuinely
per-frame: the camera, the shaders, and what to do with each vertex's `scamin` /
`disp_cat` visibility gates (baking those in would force a rebuild on every zoom or
category toggle).

```c
/* One vertex. (x, y) is WORLD position (web-mercator [0,1], y down) — the camera
 * transforms it. (ox, oy) is a REFERENCE-PIXEL offset added in SCREEN space after
 * projection (zero for area interiors, ±half-width for line edges, the outline for
 * marks) — that split is what holds a mark at a constant on-screen size while its
 * anchor rides the chart, with no re-tessellation on zoom. */
typedef struct {
    float x, y;        /* world position, [0,1]        */
    float ox, oy;      /* screen-space offset, ref px   */
    float scamin;      /* SCAMIN 1:N denominator; 0 = always visible */
    uint8_t disp_cat;  /* 0 base, 1 standard, 2 other   */
    uint8_t map_align; /* nonzero = chart-relative: a rotated view must turn it */
    uint8_t _pad[2];
    uint8_t color[4];  /* straight-alpha RGBA, per-vertex */
    float depth;       /* paint-order depth (0,1); later paint = smaller = closer */
} tile57_gpu_vertex;

/* A contiguous slice of ONE buffer drawn with ONE pipeline. Ranges arrive already
 * sorted by paint_key: draw them in order and the chart is correct. `prim` says
 * which buffer first/count address (indices vs quads); `atlas` which texture a
 * QUADS range samples. */
typedef struct {
    uint32_t first, count;
    uint32_t paint_key;   /* engine's paint order; already sorted, opaque */
    uint32_t pattern;     /* index into scene.patterns, or TILE57_GPU_NO_PATTERN */
    uint8_t color[4];     /* resolved for the scene's palette */
    uint8_t kind;         /* tile57_gpu_kind: AREA/PATTERN/LINE/SYMBOL/SOUNDING/TEXT */
    uint8_t prim;         /* tile57_gpu_prim: TRIANGLES (indexed) or QUADS */
    uint8_t atlas;        /* tile57_gpu_atlas: NONE/SPRITE/GLYPH[/_BOLD/_ITALIC] */
    uint8_t flags;        /* bit 0: OPAQUE — eligible for the depth-tested pass */
} tile57_gpu_range;

/* Draw-ready buffers for one view. Every pointer is BORROWED until
 * tile57_gpu_scene_free; `owner` is opaque. Upload vertices+indices (the triangle
 * buffers) and quads (sprite/SDF), plus the two atlas textures you baked once
 * (tile57_bake_sprite_mln, tile57_bake_glyph_sdf), then walk ranges in order. */
typedef struct {
    const tile57_gpu_vertex *vertices;  size_t vertex_count;
    const uint32_t          *indices;   size_t index_count;
    const tile57_gpu_quad   *quads;     size_t quad_count;   /* symbols + SDF text */
    const tile57_gpu_range  *ranges;    size_t range_count;
    const tile57_gpu_pattern *patterns; size_t pattern_count;
    void *owner;
} tile57_gpu_scene;

/* Portray a view into those buffers — the draw-ready twin of tile57_chart_surface.
 * The WHOLE view builds into ONE scene, so labels declutter across it and a name
 * can't collide with itself over a tile seam. There is deliberately NO rotation
 * parameter: geometry stays north-up in world space and the host applies the view
 * rotation (the per-vertex map_align flag turns the marks that must follow the
 * chart), so a continuously-turning course-up view never rebuilds. pixel_ratio is
 * the display density (1, 2, ...) — pass the SAME value to tile57_bake_sprite_mln
 * for the atlas you upload, or the sprite UVs won't index it. On OK the caller owns
 * *out and MUST release it with tile57_gpu_scene_free. */
tile57_status tile57_chart_gpu_scene(tile57_chart *chart, double lon, double lat, double zoom,
                             uint32_t width, uint32_t height,
                             const tile57_mariner *m, double pixel_ratio,
                             tile57_gpu_scene *out, tile57_error *err);

/* Composed twin: a whole chart library (tile57_compose_open) into one scene, seams
 * stitched across cells. Same buffers, same tile57_gpu_scene_free. */
tile57_status tile57_compose_gpu_scene(tile57_compose *compose, double lon, double lat, double zoom,
                             uint32_t width, uint32_t height,
                             const tile57_mariner *m, double pixel_ratio,
                             tile57_gpu_scene *out, tile57_error *err);

/* Release a scene and zero the struct — every borrowed pointer dies here, so finish
 * uploading first. Null-safe and safe to call twice. */
void tile57_gpu_scene_free(tile57_gpu_scene *scene);
```

To draw a scene: upload `vertices`+`indices` and `quads` once, then for each range
in order pick a pipeline from `kind`/`prim`/`atlas` and issue one draw — a
`TRIANGLES` range draws indexed from the flat-colour pipeline (or, when
`pattern != TILE57_GPU_NO_PATTERN`, the pattern pipeline with that cell); a `QUADS`
range draws `6·N` vertices from the sprite or SDF-glyph pipeline per `atlas`. Ranges
carrying `flags` bit 0 (OPAQUE) may be drawn front-to-back with a depth test first
for early-Z, then the rest in paint order — the per-vertex `depth` encodes that
order (later paint = smaller = closer). Everything else — pattern tiling
(phase-anchored to the world origin), the `flip`/`tangent_q` upright fix on
tangent-rotated text, applying the view rotation to `map_align` marks — is described
field-by-field in [`tile57.h`](https://github.com/beetlebugorg/tile57/blob/main/include/tile57.h).
The [Paint order](#paint-order) rules apply unchanged: the ranges *are* that order,
so drawing them in sequence is all a host must do to honour it.
