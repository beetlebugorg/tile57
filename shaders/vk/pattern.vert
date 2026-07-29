#version 450
// Area FILL PATTERN (S-52 AP(...)) interior, Vulkan/SDL_GPU. Same
// tile57_gpu_vertex buffer as chart.vert; only projects + gates the interior
// and forwards the world-anchor + cell period the fragment tiles with. Carries
// paint-order depth so patterns depth-test with the fills. Matches
// lookout.metal pattern_vert.
layout(location = 0) in vec2  a_world;
layout(location = 2) in float a_scamin;
layout(location = 3) in uint  a_packed;
layout(location = 5) in float a_depth;

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
    vec2  anchor_px;   // framebuffer px of the scene's world origin
    vec2  cell_px;     // cell period in framebuffer px (constant screen size)
} u;

layout(location = 0) out vec2 v_anchor;
layout(location = 1) out vec2 v_cell;

void main() {
    uint disp_cat = a_packed & 0xFFu;
    vec2 world = vec2(a_world.x + round(u.wrap_x - a_world.x), a_world.y);
    vec4 clip = u.mvp * vec4(world, 0.0, 1.0);
    clip.z = a_depth * clip.w;
    bool vis = (u.cat_mask & (1u << disp_cat)) != 0u;
    if (a_scamin > 0.0 && disp_cat != 0u && u.current_scale > a_scamin) vis = false;
    gl_Position = vis ? clip : vec4(0.0, 0.0, 2.0, 1.0);
    v_anchor = u.anchor_px;
    v_cell = u.cell_px;
}
