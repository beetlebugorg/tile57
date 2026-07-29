#version 450
// Tile ONE pattern cell across the polygon at a constant screen size, anchored
// to the CHART. Phase = (fragment - world-origin) / cell, both in framebuffer
// px, so a pan leaves the difference invariant (fixed to the chart, not the
// screen). Matches lookout.metal pattern_frag. Fragment sampler = set 2.
layout(location = 0) in vec2 v_anchor; // framebuffer px of the world origin
layout(location = 1) in vec2 v_cell;   // cell period, framebuffer px

layout(set = 2, binding = 0) uniform sampler2D cell;

layout(location = 0) out vec4 frag;

void main() {
    vec2 sz = max(v_cell, vec2(1.0));
    vec2 uv = fract((gl_FragCoord.xy - v_anchor) / sz);
    vec4 c = texture(cell, uv);
    if (c.a < 0.02) discard; // pattern cells are mostly transparent
    frag = c;
}
