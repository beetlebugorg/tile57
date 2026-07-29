# GPU Rendering

[Rendering Engine](./rendering.md) describes how tile57 draws a finished
chart on the CPU. This page is the other path: handing a GPU everything it needs
to draw an S-52 chart at 60 fps, and nothing it doesn't.

## The one-paragraph version

The engine portrays a whole view into **draw-ready buffers** — geometry already
triangulated, already in S-52 paint order, already split into ranges that each
draw with one pipeline — and also owns the **shaders** that read those buffers,
the **uniform block** they read alongside, and the **batcher** that turns ranges
into draw calls. A host uploads the buffers once, then each frame fills in a
uniform from its camera, asks for the batch, and issues the draws. It owns no
tessellator, no copy of the S-52 ordering rules, and no shader of its own.

## What the engine owns, and why

A GPU host must batch by pipeline, and batching destroys the order the engine
emitted in. Rebuilding that order correctly means owning a tessellator and a
copy of the paint rules — a second scene, drifting from the real one. So the
engine took that over, and then kept taking over each piece that turned out to
be the same on every backend:

| Piece | Where | Why it is not the host's |
|---|---|---|
| Vertex, quad, range buffers | `render/gpu.zig`, `tile57_gpu_scene` | Tessellation and paint order are S-52 |
| The uniform block | `render/gpu.zig`, `tile57_gpu_uniforms` | It is the other half of the vertex contract |
| The shaders | [`shaders/`](https://github.com/beetlebugorg/tile57/tree/main/shaders) | They read the layouts above |
| Range → draw call | `render/batch.zig`, `tile57_gpu_batch` | It is a reading of `kind`/`prim`/`atlas`/`pattern` |

What stays with the host is what the engine genuinely cannot know: its device,
its pipeline objects, its textures, its command encoder, its swapchain — and
the per-frame *values* in the uniform block, which come from a camera the engine
never sees.

That division is not theoretical. Every row above except the first started life
in a host, written three times for three backends, and each one had already
drifted by the time it moved: two backends documented the uniform's `color` as
an SDF halo colour and the third as a flat fill colour (the shaders only ever
read it as the halo); one backend never merged draws at all, issuing one per
range where the others issued one per run.

## The pieces

### 1. Draw-ready buffers

`tile57_chart_gpu_scene` (or `tile57_compose_gpu_scene` for a whole library)
portrays a view into one scene. The structs are documented field by field in
[Draw-ready GPU scenes](./api/render.md#draw-ready-gpu-scenes-batched-buffers).

The whole view builds into **one** scene, which is what lets labels declutter
across it — a name cannot collide with itself over a tile seam.

### 2. The uniform block

`tile57_gpu_uniforms` is 128 bytes, and its layout is not the host's to choose:
the shaders below read exactly this, and a host that lays it out differently
gets silently wrong shading rather than an error.

```c
typedef struct {
    float mvp[16];       /* column-major world ([0,1] web-mercator) -> clip */
    float px_to_clip[2]; /* reference-px -> clip delta (the ox/oy channel)  */
    float size_scale;    /* density x mariner symbol size, on that channel  */
    float current_scale; /* the view's 1:N denominator, tested vs scamin    */
    uint32_t cat_mask;   /* bit per disp_cat; a 0 clears that category      */
    float wrap_x;        /* camera centre world-x (the antimeridian wrap)   */
    float rot_sin, rot_cos;
    float color[4];      /* SDF halo background; SDF fragment stage only    */
    float anchor_px[2];  /* pattern phase origin, framebuffer px            */
    float cell_px[2];    /* pattern cell period, framebuffer px             */
} tile57_gpu_uniforms;
```

The engine never fills this in — every field is per-frame host state. Three of
them vary *per draw* rather than per frame, and the batcher tells you what to
put there: `cat_mask` (soundings), `color` (label halos) and `cell_px`
(patterns). Everything else you set once per frame from your camera.

Two fields are worth understanding rather than copying:

- **`px_to_clip` and `size_scale`** drive the second, screen-space channel of
  every vertex (`ox`/`oy`). Geometry rides the chart; that channel holds a
  symbol at a constant on-screen size while its anchor moves — which is why a
  zoom needs no re-tessellation.
- **`current_scale` and `cat_mask`** are the visibility gates, tested in the
  vertex shader against each vertex's `scamin` and `disp_cat`. Baking them into
  a scene would force a rebuild on every zoom or category toggle.

### 3. The shaders

[`shaders/`](https://github.com/beetlebugorg/tile57/tree/main/shaders) carries
the reference programs in two languages: `lookout.metal` for Metal (compiled at
runtime from source) and `vk/*.vert` / `vk/*.frag` with pre-compiled `vk/*.spv`
for Vulkan and SDL_GPU. One `.spv` set serves both Vulkan-flavoured backends —
the raw-Vulkan pipeline layout mirrors SDL_GPU's set numbering (vertex UBO set
1, fragment sampler set 2, fragment UBO set 3).

There are four pipelines:

| Pipeline | Draws | Colour from |
|---|---|---|
| chart | flat-colour triangles | per vertex |
| pattern | area fills tiled from a cell texture | per vertex, modulated by the cell |
| sprite | symbol quads | the sprite atlas |
| SDF | label glyphs, with halo tiers | per vertex, haloed with the uniform's `color` |

A Zig consumer gets them from the package with `dep.path("shaders/...")`; any
other build can read them out of the source tree. They are reference
implementations — a host with its own shading language ports them, and the
layouts above are the contract it must honour.

### 4. The batcher

Ranges arrive in paint order, but a host still has to decide, per range, which
pipeline draws it, which atlas it samples, what the uniform should say, and
whether it folds into the previous draw. `tile57_gpu_batch` is that decision:

```c
size_t tile57_gpu_batch(const tile57_gpu_range *ranges, size_t range_count,
                        const tile57_gpu_batch_opts *opts,
                        tile57_gpu_draw *out, size_t out_cap);
```

It takes only the ranges — no vertex, quad or pattern buffer — so a host that
keeps just its uploaded ranges need not hold a whole scene alive to ask. It
allocates nothing and touches no GPU.

```c
typedef struct {
    bool text_on;             /* mariner text switch                          */
    bool sound_on;            /* mariner soundings switch                     */
    bool exclude_opaque_tris; /* you draw those in your own depth pass first   */
    uint8_t atlas_have;       /* bit per tile57_gpu_atlas you uploaded         */
    float halo[4];            /* palette background, for SDF label halos       */
} tile57_gpu_batch_opts;

typedef struct {
    uint32_t first, count;
    uint8_t prim;         /* tile57_gpu_prim                                   */
    uint8_t pipeline;     /* tile57_gpu_pipeline: CHART/PATTERN/SPRITE/SDF     */
    uint8_t atlas;        /* tile57_gpu_atlas, AFTER the missing-tier fallback */
    uint8_t _pad;
    uint32_t pattern;     /* index into scene patterns, or NO_PATTERN          */
    uint32_t cat_mask_or; /* OR into the uniform's cat_mask                    */
    float color[4];       /* the uniform's color (halo on SDF draws)           */
} tile57_gpu_draw;
```

Sizing `out`: `range_count` is always safe, since draws only ever merge, never
split. A return greater than `out_cap` means the buffer was too small and
**nothing** should be drawn from it — a truncated batch is missing chart,
silently. Pass `out = NULL` to ask for the count alone.

`atlas_have` is how the engine knows what you managed to upload. A missing bold
or italic glyph tier falls back to the regular glyph atlas; a missing regular
atlas or sprite sheet drops those ranges, because there is nothing to sample.

## Drawing a frame

```c
/* Once, at startup: bake the atlases at your display density and upload them.
 * Pass the SAME pixel_ratio to tile57_bake_sprite_mln and to the scene call,
 * or the sprite UVs will not index your texture. */

/* Once per rebuild (a pan or zoom out of the built area): */
tile57_gpu_scene scene;
tile57_chart_gpu_scene(chart, lon, lat, zoom, w, h, &mariner, density, &scene, &err);
upload(scene.vertices, scene.indices, scene.quads);   /* your buffers */
keep_a_copy(scene.ranges, scene.range_count);         /* the batcher needs these */
tile57_gpu_scene_free(&scene);                        /* pointers are borrowed */

/* Every frame: */
tile57_gpu_uniforms u = {0};
fill_from_camera(&u);                                  /* mvp, px_to_clip, gates */

tile57_gpu_batch_opts opts = {
    .text_on = mariner.show_text, .sound_on = mariner.show_soundings,
    .exclude_opaque_tris = false, .atlas_have = my_atlas_bits,
    .halo = { bg.r, bg.g, bg.b, 1 },
};
size_t n = tile57_gpu_batch(ranges, range_count, &opts, draws, draw_cap);
if (n > draw_cap) return;                              /* never draw a truncated batch */

for (size_t i = 0; i < n; i++) {
    tile57_gpu_draw d = draws[i];
    tile57_gpu_uniforms du = u;
    du.cat_mask |= d.cat_mask_or;
    if (d.pipeline == TILE57_GPU_PIPE_SDF) du.color = d.color;
    if (d.pipeline == TILE57_GPU_PIPE_PATTERN) {
        /* Your texture, so its size is yours to convert. A pattern whose cell
         * never rasterized draws nothing — the flat fill under it already did. */
        if (!have_cell(d.pattern)) continue;
        du.cell_px = cell_period_px(d.pattern);
    }
    bind(pipeline_for(d.pipeline), texture_for(d.atlas));
    push_uniform(&du);
    draw(d.prim, d.first, d.count);
}
```

That loop *is* the host obligation. Note what is absent from it: no sorting, no
tessellation, no decision about what a range means.

## Things worth knowing

**Paint order is the range order.** Ranges arrive sorted by `paint_key`; draw
them in sequence and the chart is correct. The batcher only ever merges
*contiguous* ranges that share a draw spec, so merged primitives rasterize in
the order they would have anyway — and a dropped range breaks contiguity, which
is what stops a merge from drawing through a gated-off hole.

**The opaque prepass is optional.** Ranges with `flags` bit 0 (OPAQUE) may be
drawn front-to-back with depth writes first, so stacked S-52 fills cost about
one shade per pixel instead of one per layer; the per-vertex `depth` encodes
that order. Correctness rests on that depth, not on draw order — the pass is an
early-Z optimization, not a portrayal rule. Set `exclude_opaque_tris` to keep
those ranges out of the main batch if you run it.

**The pattern phase is world-anchored.** `anchor_px` is the framebuffer position
of the scene's phase origin, a world-fixed point between rebuilds, so a fill
does not swim under a pan. Scale `cell_px` with the zoom so the tiling tracks
the geometry the MVP is scaling.

**Rotation is yours.** There is deliberately no rotation parameter on the scene
call: geometry stays north-up in world space and the host applies the view
rotation via `rot_sin`/`rot_cos`, so a continuously-turning course-up view never
rebuilds. The per-vertex `map_align` flag marks the symbols that must turn with
the chart.

**Check the ABI at startup.** `tile57_abi_gpu_layout()` packs the sizes of the
vertex, quad, range and uniform structs. Compare it against your compiled
`sizeof`s when you open — a header compiled against a different library renders
garbage (a sheared vertex stream, a uniform block read past its end) rather than
failing, and this turns that into a loud refusal.

## A worked implementation

[lookout-core](https://github.com/beetlebugorg/lookout-core) is a full host
against this contract, with three backends over one seam: Metal (Apple),
raw Vulkan (Android) and SDL_GPU (Windows/Linux). Each is roughly 700–1,300
lines, almost all of it device and window management — the chart-specific part
is the loop above.
