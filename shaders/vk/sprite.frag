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
    o_color = texture(atlas, v_uv) * v_color;
}
