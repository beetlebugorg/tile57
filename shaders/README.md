# Reference shaders

The shader half of the GPU-scene contract. `render/gpu.zig` decides the vertex,
quad and uniform layouts; these are the programs that read them.

They live here for the same reason `include/tile57.h` does: the engine does not
compile or run them, but it does own what they mean. They were maintained as two
hand-synced copies in a host repo, one per language, under comments that said
"matches the other one" — and by the time they moved, they no longer did. The
Metal copy documented `color` as a per-range flat colour when both languages had
only ever read it as the SDF halo background.

| file | stages | consumed by |
|---|---|---|
| `lookout.metal` | all four pipelines, one file | Metal, compiled at runtime from source |
| `vk/*.vert`, `vk/*.frag` | GLSL sources | reference; edit these |
| `vk/*.spv` | pre-compiled SPIR-V | Vulkan and SDL_GPU, embedded at build time |

One `.spv` set serves both Vulkan-flavoured backends: the raw-Vulkan pipeline
layout mirrors SDL_GPU's set numbering (vertex UBO set 1, fragment sampler set
2, fragment UBO set 3).

## The four pipelines

| pipeline | vertex | fragment | draws |
|---|---|---|---|
| chart | `chart.vert` | `chart.frag` | flat-colour triangles; colour per vertex |
| pattern | `pattern.vert` | `pattern.frag` | area fills tiled from a pattern cell |
| sprite | `sprite.vert` | `sprite.frag` | symbol quads from the sprite atlas |
| SDF | `sprite.vert` | `sdf.frag` | label glyphs, with the halo tiers |

## Editing

The `.spv` blobs are committed artifacts — there is no `glslc` step in either
build. Recompile them by hand after touching a `.glsl` source, and keep
`lookout.metal` in step: it is a separate language expressing the same
portrayal, so a change to one is a change to both. That duplication is the cost
of two shading languages; keeping the copies in one directory, next to the
layouts they read, is what makes a drift visible instead of silent.
