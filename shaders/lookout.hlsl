// lookout chart shaders — HLSL (D3D12).
//
// Direct port of lookout.metal (the reference). Compiled at runtime by the
// host's D3D12 shim (D3DCompile, SM 5.0), so there is no offline shader
// toolchain. Vertices arrive through input layouts whose offsets must stay
// byte-identical to tile57_gpu_vertex (32 B) / tile57_gpu_quad (44 B). The
// cbuffer must stay byte-identical to tile57_gpu_uniforms (128 B); its fields
// pack into eight 16-byte registers with no padding, so the C layout and the
// HLSL layout agree.

cbuffer U : register(b0)
{
    float4x4 mvp;           // column-major (HLSL default) == the engine's storage
    float2   px_to_clip;
    float    size_scale;
    float    current_scale;
    uint     cat_mask;
    float    wrap_x;        // camera center world-x: wrap each vertex to the NEAR world instance
    float    rot_sin;
    float    rot_cos;
    float4   color;         // per-range flat colour (straight alpha, 0..1)
    float2   anchor_px;     // pattern: framebuffer px of the scene's phase origin
    float2   cell_px;       // pattern: cell period in framebuffer px
};

Texture2D    atlas : register(t0);
SamplerState smp   : register(s0);

// ---- vertex streams (offsets pinned by the input layouts in the shim) ------
struct ChartVin                // tile57_gpu_vertex, 32 B
{
    float2 world  : WORLD;     // web-mercator [0,1], camera-relative
    float2 local  : LOCALPX;   // anchor-relative reference px
    float  scamin : SCAMIN;    // SCAMIN 1:N denominator (<=0 => always visible)
    uint   pack   : PACKED;    // low byte disp_cat, next byte map_align
    float4 color  : COLOR;     // R8G8B8A8_UNORM -> 0..1 straight alpha
    float  depth  : DEPTH;     // paint-order depth (0,1), later = smaller
};

struct QuadVin                 // tile57_gpu_quad, 44 B
{
    float2 world  : WORLD;
    float2 local  : LOCALPX;
    float2 uv     : TEXCOORD0;
    float4 color  : COLOR;     // sprite: white; text: glyph colour
    float  weight : WEIGHT;    // SDF halo width (0 for sprites)
    float  scamin : SCAMIN;
    uint   pack   : PACKED;    // disp_cat | map_align<<8 | flip<<16 | tangent_q<<24
    float  depth  : DEPTH;     // paint-order depth — brick quads sit UNDER fills
};

// Longitude is cyclic: draw each vertex at the world instance nearest the
// camera (x, x-1 or x+1), so a view straddling the antimeridian is seamless.
float4 project_world(float2 world_in)
{
    float2 world = float2(world_in.x + round(wrap_x - world_in.x), world_in.y);
    return mul(mvp, float4(world, 0.0, 1.0));
}

bool visible(uint disp_cat, float scamin)
{
    bool vis = (cat_mask & (1u << disp_cat)) != 0u;
    if (scamin > 0.0 && disp_cat != 0u && current_scale > scamin) vis = false;
    return vis;
}

// ---- chart: flat-colour triangles (area fills, line work) ------------------
struct ChartOut
{
    float4 pos   : SV_Position;
    float4 color : COLOR0;
};

ChartOut chart_vs(ChartVin v)
{
    uint disp_cat  = v.pack & 0xFFu;
    bool map_align = ((v.pack >> 8) & 0xFFu) != 0u;

    float4 clip = project_world(v.world);
    // line edges carry a constant-screen-size local px offset; area interiors
    // have local == 0. MAP-aligned marks turn with the chart.
    float2 local = v.local;
    if (map_align)
    {
        local = float2(local.x * rot_cos - local.y * rot_sin,
                       local.x * rot_sin + local.y * rot_cos);
    }
    clip.xy += local * px_to_clip * size_scale * clip.w;

    clip.z = v.depth * clip.w; // paint-order depth (ortho: w = 1)
    ChartOut o;
    o.pos = visible(disp_cat, v.scamin) ? clip : float4(0.0, 0.0, 2.0, 1.0); // z=2 -> clipped
    o.color = v.color;
    return o;
}

float4 chart_ps(ChartOut i) : SV_Target
{
    return i.color;
}

// ---- pattern: area fill patterns (S-52 AP(...)) ----------------------------
// The tessellated polygon interior projects like chart_vs; the tiling is done
// per-fragment so the cell keeps a constant screen size and stays ANCHORED TO
// THE CHART (world) under a pan instead of swimming with the screen.
struct PatternOut
{
    float4 pos    : SV_Position;
    float2 anchor : TEXCOORD0;
    float2 cell   : TEXCOORD1;
};

PatternOut pattern_vs(ChartVin v)
{
    uint disp_cat = v.pack & 0xFFu;
    float4 clip = project_world(v.world);
    clip.z = v.depth * clip.w; // paint-order depth: patterns depth-test too
    PatternOut o;
    o.pos = visible(disp_cat, v.scamin) ? clip : float4(0.0, 0.0, 2.0, 1.0);
    o.anchor = anchor_px;
    o.cell = cell_px;
    return o;
}

// Phase = (fragment - world-origin) / cell, both in framebuffer px: a pan moves
// both by the same amount, so the pattern is fixed to the chart, not the screen.
float4 pattern_ps(PatternOut i) : SV_Target
{
    float2 sz = max(i.cell, float2(1.0, 1.0));
    float2 uv = frac((i.pos.xy - i.anchor) / sz);
    float4 c = atlas.Sample(smp, uv);
    if (c.a < 0.02) discard; // pattern cells are mostly transparent
    return c;
}

// ---- sprite/SDF quads: symbols and text ------------------------------------
struct QuadOut
{
    float4 pos    : SV_Position;
    float2 uv     : TEXCOORD0;
    float4 color  : COLOR0;
    float  weight : TEXCOORD1;
};

QuadOut sprite_vs(QuadVin v)
{
    uint  disp_cat  = v.pack & 0xFFu;
    bool  map_align = ((v.pack >> 8) & 0xFFu) != 0u;
    bool  flip      = ((v.pack >> 16) & 0xFFu) != 0u;
    float tangent   = float((v.pack >> 24) & 0xFFu) / 256.0 * 6.2831853071795864;

    float4 clip = project_world(v.world);
    float2 local = v.local;
    // Keep a tangent-rotated run (a depth-contour value) upright: if the run,
    // once the view rotation is added, would read into the screen's left
    // half-plane, turn it 180° about the anchor.
    if (flip && (cos(tangent) * rot_cos - sin(tangent) * rot_sin) < 0.0)
    {
        local = -local;
    }
    if (map_align)
    {
        local = float2(local.x * rot_cos - local.y * rot_sin,
                       local.x * rot_sin + local.y * rot_cos);
    }
    clip.xy += local * px_to_clip * size_scale * clip.w;
    clip.z = v.depth * clip.w; // paint-order depth: brick quads lose to fills above

    QuadOut o;
    o.pos = visible(disp_cat, v.scamin) ? clip : float4(0.0, 0.0, 2.0, 1.0);
    o.uv = v.uv;
    o.color = v.color;
    o.weight = v.weight;
    return o;
}

float4 sprite_ps(QuadOut i) : SV_Target
{
    return atlas.Sample(smp, i.uv) * i.color;
}

// SDF text: sample the signed-distance field (.r), antialias with the
// screen-space derivative. `weight` is the halo width (SDF field units,
// 0 = none) that lifts the name tiers off busy soundings.
float4 sdf_ps(QuadOut i) : SV_Target
{
    float d = atlas.Sample(smp, i.uv).r;
    float w = fwidth(d);
    float a = smoothstep(0.5 - w, 0.5 + w, d);
    if (i.weight > 0.0)
    {
        float halo_a = smoothstep(0.5 - i.weight - w, 0.5 - i.weight + w, d);
        float cov = max(a, halo_a);
        if (cov <= 0.0) discard;
        // Halo in the PALETTE's background colour (color_* = NODATA of the
        // active scheme, set per SDF range by the host): a hardcoded white
        // halo glared at night — light glyphs in a white outline on a dark
        // chart, the opposite of night vision.
        float3 col = lerp(color.rgb, i.color.rgb, a);
        return float4(col, cov * i.color.a);
    }
    if (a <= 0.0) discard;
    return float4(i.color.rgb, i.color.a * a);
}
