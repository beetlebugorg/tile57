#version 450
// Flat-colour fragment shader. Colours arrive already resolved for the active
// S-52 palette (straight-alpha, per-vertex), blended in paint order by the
// fixed-function blend state. Matches lookout.metal chart_frag.
layout(location = 0) in  vec4 v_color;
layout(location = 0) out vec4 o_color;
void main() { o_color = v_color; }
