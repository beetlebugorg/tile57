#version 450
// SDF text (Vulkan/SDL_GPU): sample the signed-distance field (.r), antialias
// with the screen-space derivative so text stays crisp at any zoom, tinted by
// the glyph colour. `v_weight` is the HALO width (SDF field units, 0 = none):
// the bold/italic name tiers carry a small value so a subtle halo in the
// palette's background colour lifts them off busy soundings. Matches
// lookout.metal sdf_frag — the halo colour is u.color.rgb (the active scheme's
// NODATA, set per SDF range by the host), so a night palette doesn't glare.
// Fragment sampler = set 2; fragment uniform = set 3.
layout(set = 2, binding = 0) uniform sampler2D atlas;
layout(set = 3, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float current_scale;
    uint  cat_mask;
    float wrap_x;
    float rot_sin;
    float rot_cos;
    vec4  color;        // halo background = active palette NODATA
    vec2  anchor_px;
    vec2  cell_px;
} u;

layout(location = 0) in  vec2  v_uv;
layout(location = 1) in  vec4  v_color;
layout(location = 2) in  float v_weight;
layout(location = 0) out vec4 o_color;

void main() {
    float d = texture(atlas, v_uv).r;
    float w = fwidth(d);
    float a = smoothstep(0.5 - w, 0.5 + w, d);
    if (v_weight > 0.0) {
        float halo_a = smoothstep(0.5 - v_weight - w, 0.5 - v_weight + w, d);
        float cov = max(a, halo_a);
        if (cov <= 0.0) discard;
        vec3 col = mix(u.color.rgb, v_color.rgb, a); // halo bg colour, glyph colour inside
        o_color = vec4(col, cov * v_color.a);
        return;
    }
    if (a <= 0.0) discard;
    o_color = vec4(v_color.rgb, v_color.a * a);
}
