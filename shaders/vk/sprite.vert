#version 450
// Textured-quad vertex shader (Vulkan/SDL_GPU) for sprite symbols and SDF text.
// One quad per symbol/glyph, 6 verts, non-indexed. Same anchor + screen-space
// local-px model as chart.vert, plus a UV and paint-order depth. Matches
// lookout.metal sprite_vert.

// tile57_gpu_quad (44 B): world(0) local(8) uv(16) color(24, ubyte4)
//   weight(28) scamin(32) packed(36)=disp_cat|map_align<<8|flip<<16|tangent_q<<24
//   depth(40)
layout(location = 0) in vec2  a_world;
layout(location = 1) in vec2  a_local;
layout(location = 2) in vec2  a_uv;
layout(location = 3) in vec4  a_color;   // UBYTE4_NORM; sprite: white, text: glyph colour
layout(location = 4) in float a_weight;  // SDF halo width (0 for sprites)
layout(location = 5) in float a_scamin;
layout(location = 6) in uint  a_packed;  // disp_cat | map_align<<8 | flip<<16 | tangent_q<<24
layout(location = 7) in float a_depth;   // paint-order depth (brick quads sit under fills)

layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float current_scale;
    uint  cat_mask;
    float wrap_x;
    float rot_sin;
    float rot_cos;
    vec4  color;
    vec2  anchor_px;
    vec2  cell_px;
} u;

layout(location = 0) out vec2  v_uv;
layout(location = 1) out vec4  v_color;
layout(location = 2) out float v_weight;

void main() {
    uint disp_cat  = a_packed & 0xFFu;
    bool map_align = ((a_packed >> 8) & 0xFFu) != 0u;
    bool flip      = ((a_packed >> 16) & 0xFFu) != 0u;
    float tangent  = float((a_packed >> 24) & 0xFFu) / 256.0 * 6.2831853071795864;

    vec2 world = vec2(a_world.x + round(u.wrap_x - a_world.x), a_world.y);
    vec4 clip = u.mvp * vec4(world, 0.0, 1.0);
    vec2 local = a_local;
    // Keep a tangent-rotated run (a depth-contour value) upright: if the run,
    // once the view rotation is added, would read into the screen's left
    // half-plane, turn it 180° about the anchor.
    if (flip && (cos(tangent) * u.rot_cos - sin(tangent) * u.rot_sin) < 0.0) {
        local = -local;
    }
    if (map_align) {
        local = vec2(local.x * u.rot_cos - local.y * u.rot_sin,
                     local.x * u.rot_sin + local.y * u.rot_cos);
    }
    clip.xy += local * u.px_to_clip * u.size_scale * clip.w;
    clip.z = a_depth * clip.w;

    bool vis = (u.cat_mask & (1u << disp_cat)) != 0u;
    if (a_scamin > 0.0 && disp_cat != 0u && u.current_scale > a_scamin) vis = false;

    gl_Position = vis ? clip : vec4(0.0, 0.0, 2.0, 1.0);
    v_uv = a_uv;
    v_color = a_color;
    v_weight = a_weight;
}
