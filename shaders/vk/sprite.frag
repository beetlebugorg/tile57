#version 450
// Sprite fragment shader: straight RGBA atlas sample, tinted by v_color (white
// for pre-coloured sprite cells). Matches lookout.metal sprite_frag. SDL_GPU
// Vulkan: fragment samplers are set 2.
layout(set = 2, binding = 0) uniform sampler2D atlas;
layout(location = 0) in  vec2  v_uv;
layout(location = 1) in  vec4  v_color;
layout(location = 2) in  float v_weight; // unused for sprites
layout(location = 0) out vec4 o_color;
void main() {
    vec4 c = texture(atlas, v_uv) * v_color;
    // A fully transparent fragment must not reach the depth buffer. The
// raster underlay draws through this pipeline WITH DEPTH WRITE, to hide the
// chart's opaque area fills exactly where a picture covers them; a baked RNC is
// transparent outside its neat line, and without this those transparent pixels
// wrote depth and cut holes in the chart underneath. Costs nothing for a sprite
// or a glyph: both draw with depth write off, so this only skips a fragment
// that would have blended to nothing.
    if (c.a < (1.0 / 255.0)) discard;
    o_color = c;
}
