#version 450
// lookout chart vertex shader (Vulkan/SDL_GPU) — flat-colour triangles: area
// fills and line work. Ported from shaders/lookout.metal (chart_vert); kept in
// lock-step with it and with tile57_gpu_vertex. Colour is PER-VERTEX now (whole
// paint bands of one colour collapse into a single draw) and every vertex
// carries paint-order depth for the depth-tested opaque pass.

// tile57_gpu_vertex (32 B): world(0) local(8) scamin(16) packed(20)
//                           color(24, ubyte4) depth(28)
layout(location = 0) in vec2  a_world;   // web-mercator [0,1], camera-relative
layout(location = 1) in vec2  a_local;   // anchor-relative reference px (0 for interiors)
layout(location = 2) in float a_scamin;  // SCAMIN 1:N denominator (<=0 => always visible)
layout(location = 3) in uint  a_packed;  // low byte disp_cat, next byte map_align
layout(location = 4) in vec4  a_color;   // UBYTE4_NORM straight-alpha RGBA
layout(location = 5) in float a_depth;   // paint-order depth (0,1), later = smaller

layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float current_scale;
    uint  cat_mask;
    float wrap_x;
    float rot_sin;
    float rot_cos;
    vec4  color;        // unused on the per-vertex chart path (kept for layout parity)
    vec2  anchor_px;
    vec2  cell_px;
} u;

layout(location = 0) out vec4 v_color;

void main() {
    uint disp_cat = a_packed & 0xFFu;
    bool map_align = ((a_packed >> 8) & 0xFFu) != 0u;

    // Longitude is cyclic: draw this vertex at the world instance nearest the
    // camera (x, x-1 or x+1), so a view straddling the antimeridian is seamless.
    vec2 world = vec2(a_world.x + round(u.wrap_x - a_world.x), a_world.y);
    vec4 clip = u.mvp * vec4(world, 0.0, 1.0);

    // line edges carry a constant-screen-size local px offset; area interiors
    // have local == 0. MAP-aligned marks turn with the chart.
    vec2 local = a_local;
    if (map_align) {
        local = vec2(local.x * u.rot_cos - local.y * u.rot_sin,
                     local.x * u.rot_sin + local.y * u.rot_cos);
    }
    clip.xy += local * u.px_to_clip * u.size_scale * clip.w;
    clip.z = a_depth * clip.w; // paint-order depth (ortho: w = 1)

    bool vis = (u.cat_mask & (1u << disp_cat)) != 0u;
    if (a_scamin > 0.0 && disp_cat != 0u && u.current_scale > a_scamin) vis = false;

    gl_Position = vis ? clip : vec4(0.0, 0.0, 2.0, 1.0); // z=2 -> depth-clipped
    v_color = a_color;
}
