// lookout chart shaders — Metal Shading Language.
//
// Direct MSL port of the GLSL sources this file replaces (chart.vert/.frag,
// sprite.vert/.frag, sdf.frag, pattern.vert/.frag — kept alongside for
// reference). Compiled at runtime by metal_shim.m (newLibraryWithSource), so
// there is no offline shader toolchain at all.
//
// Vertices are fetched by index from the raw tile57 buffers ([[buffer(0)]])
// instead of through a vertex descriptor — the structs below must stay
// byte-identical to tile57_gpu_vertex (24 B) / tile57_gpu_quad (40 B).
// The uniform block must stay byte-identical to gpu.zig's Uniforms (128 B).

#include <metal_stdlib>
using namespace metal;

// ---- shared uniform block (== gpu.zig Uniforms, 128 bytes) ------------------
struct U {
    float4x4 mvp;
    float2   px_to_clip;
    float    size_scale;
    float    current_scale;
    uint     cat_mask;
    float    wrap_x;    // camera center world-x: wrap each vertex to the NEAR world instance
    float    rot_sin;
    float    rot_cos;
    float4   color;     // per-range flat colour (straight alpha, 0..1)
    float2   anchor_px; // pattern: framebuffer px of the scene's phase origin
    float2   cell_px;   // pattern: cell period in framebuffer px
};

// ---- vertex streams (== tile57 ABI structs) --------------------------------
struct ChartVertex {            // tile57_gpu_vertex, 32 B
    // packed_float2 keeps the stride EXACTLY the CPU struct's — natural float2
    // alignment once sheared a 28-byte layout to a 32-byte stride and every
    // vertex after the first read garbage. 32 happens to be 8-aligned today;
    // packed stays anyway so a future field can't re-open the trap.
    packed_float2 world;        // web-mercator [0,1], camera-relative
    packed_float2 local;        // anchor-relative reference px
    float  scamin;              // SCAMIN 1:N denominator (<=0 => always visible)
    uint   packed;              // low byte disp_cat, next byte map_align
    uchar4 color;               // straight-alpha RGBA — per-vertex so ranges of
                                // different colours merge into one draw
    float  depth;               // paint-order depth (0,1), later = smaller;
                                // opaque pass: LESS+write, blended: LESS only
};

struct QuadVertex {             // tile57_gpu_quad, 44 B
    // packed_float2: 44 is not 8-aligned — natural float2 would pad the stride
    // to 48 and shear the stream (see ChartVertex).
    packed_float2 world;
    packed_float2 local;
    packed_float2 uv;
    uchar4 color;               // sprite: white; text: glyph colour
    float  weight;              // SDF halo width (0 for sprites)
    float  scamin;
    uint   packed;              // disp_cat | map_align<<8 | flip<<16 | tangent_q<<24
    float  depth;               // paint-order depth — brick quads sit UNDER fills
};

// Longitude is cyclic: draw each vertex at the world instance nearest the
// camera (x, x-1 or x+1), so a view straddling the antimeridian is seamless.
static inline float4 project(constant U &u, float2 world_in) {
    float2 world = float2(world_in.x + rint(u.wrap_x - world_in.x), world_in.y);
    return u.mvp * float4(world, 0.0, 1.0);
}

static inline bool visible(constant U &u, uint disp_cat, float scamin) {
    bool vis = (u.cat_mask & (1u << disp_cat)) != 0u;
    if (scamin > 0.0 && disp_cat != 0u && u.current_scale > scamin) vis = false;
    return vis;
}

// ---- chart: flat-colour triangles (area fills, line work) ------------------
struct ChartOut {
    float4 pos [[position]];
    float4 color;
};

vertex ChartOut chart_vert(uint vid [[vertex_id]],
                           const device ChartVertex *verts [[buffer(0)]],
                           constant U &u [[buffer(1)]]) {
    ChartVertex v = verts[vid];
    uint disp_cat = v.packed & 0xFFu;
    bool map_align = ((v.packed >> 8) & 0xFFu) != 0u;

    float4 clip = project(u, v.world);
    // line edges carry a constant-screen-size local px offset; area interiors
    // have local == 0. MAP-aligned marks turn with the chart.
    float2 local = v.local;
    if (map_align) {
        local = float2(local.x * u.rot_cos - local.y * u.rot_sin,
                       local.x * u.rot_sin + local.y * u.rot_cos);
    }
    clip.xy += local * u.px_to_clip * u.size_scale * clip.w;

    clip.z = v.depth * clip.w; // paint-order depth (ortho: w = 1)
    ChartOut out;
    out.pos = visible(u, disp_cat, v.scamin) ? clip : float4(0.0, 0.0, 2.0, 1.0); // z=2 -> clipped
    out.color = float4(v.color) / 255.0;
    return out;
}

fragment float4 chart_frag(ChartOut in [[stage_in]]) {
    return in.color;
}

// ---- pattern: area fill patterns (S-52 AP(...)) ----------------------------
// The tessellated polygon interior projects like chart_vert; the tiling is done
// per-fragment so the cell keeps a constant screen size and stays ANCHORED TO
// THE CHART (world) under a pan instead of swimming with the screen.
struct PatternOut {
    float4 pos [[position]];
    float2 anchor;
    float2 cell;
};

vertex PatternOut pattern_vert(uint vid [[vertex_id]],
                               const device ChartVertex *verts [[buffer(0)]],
                               constant U &u [[buffer(1)]]) {
    ChartVertex v = verts[vid];
    uint disp_cat = v.packed & 0xFFu;
    float4 clip = project(u, v.world);
    clip.z = v.depth * clip.w; // paint-order depth: patterns depth-test too
    PatternOut out;
    out.pos = visible(u, disp_cat, v.scamin) ? clip : float4(0.0, 0.0, 2.0, 1.0);
    out.anchor = u.anchor_px;
    out.cell = u.cell_px;
    return out;
}

// Phase = (fragment - world-origin) / cell, both in framebuffer px: a pan moves
// both by the same amount, so the pattern is fixed to the chart, not the screen.
fragment float4 pattern_frag(PatternOut in [[stage_in]],
                             texture2d<float> cell [[texture(0)]],
                             sampler smp [[sampler(0)]]) {
    float2 sz = max(in.cell, float2(1.0));
    float2 uv = fract((in.pos.xy - in.anchor) / sz);
    float4 c = cell.sample(smp, uv);
    if (c.a < 0.02) discard_fragment(); // pattern cells are mostly transparent
    return c;
}

// ---- sprite/SDF quads: symbols and text ------------------------------------
struct QuadOut {
    float4 pos [[position]];
    float2 uv;
    float4 color;
    float  weight;
};

vertex QuadOut sprite_vert(uint vid [[vertex_id]],
                           const device QuadVertex *verts [[buffer(0)]],
                           constant U &u [[buffer(1)]]) {
    QuadVertex v = verts[vid];
    uint disp_cat  = v.packed & 0xFFu;
    bool map_align = ((v.packed >> 8) & 0xFFu) != 0u;
    bool flip      = ((v.packed >> 16) & 0xFFu) != 0u;
    float tangent  = float((v.packed >> 24) & 0xFFu) / 256.0 * 6.2831853071795864;

    float4 clip = project(u, v.world);
    float2 local = v.local;
    // Keep a tangent-rotated run (a depth-contour value) upright: if the run,
    // once the view rotation is added, would read into the screen's left
    // half-plane, turn it 180° about the anchor.
    if (flip && (cos(tangent) * u.rot_cos - sin(tangent) * u.rot_sin) < 0.0) {
        local = -local;
    }
    if (map_align) {
        local = float2(local.x * u.rot_cos - local.y * u.rot_sin,
                       local.x * u.rot_sin + local.y * u.rot_cos);
    }
    clip.xy += local * u.px_to_clip * u.size_scale * clip.w;
    clip.z = v.depth * clip.w; // paint-order depth: brick quads lose to fills above

    QuadOut out;
    out.pos = visible(u, disp_cat, v.scamin) ? clip : float4(0.0, 0.0, 2.0, 1.0);
    out.uv = v.uv;
    out.color = float4(v.color) / 255.0;
    out.weight = v.weight;
    return out;
}

fragment float4 sprite_frag(QuadOut in [[stage_in]],
                            texture2d<float> atlas [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    return atlas.sample(smp, in.uv) * in.color;
}

// SDF text: sample the signed-distance field (.r), antialias with the
// screen-space derivative. `weight` is the white HALO width (SDF field units,
// 0 = none) that lifts the name tiers off busy soundings.
fragment float4 sdf_frag(QuadOut in [[stage_in]],
                         constant U &u [[buffer(1)]],
                         texture2d<float> atlas [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    float d = atlas.sample(smp, in.uv).r;
    float w = fwidth(d);
    float a = smoothstep(0.5 - w, 0.5 + w, d);
    if (in.weight > 0.0) {
        float halo_a = smoothstep(0.5 - in.weight - w, 0.5 - in.weight + w, d);
        float cov = max(a, halo_a);
        if (cov <= 0.0) discard_fragment();
        // Halo in the PALETTE's background colour (u.color = NODATA of the
        // active scheme, set per SDF range by the host): a hardcoded white
        // halo glared at night — light glyphs in a white outline on a dark
        // chart, the opposite of night vision.
        float3 col = mix(u.color.rgb, in.color.rgb, a);
        return float4(col, cov * in.color.a);
    }
    if (a <= 0.0) discard_fragment();
    return float4(in.color.rgb, in.color.a * a);
}
