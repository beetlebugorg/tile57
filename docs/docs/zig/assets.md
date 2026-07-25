---
title: Portrayal assets
slug: /zig-api/assets
---

# Portrayal assets

`tile57.sprite` rasterizes the S-101 portrayal symbols and area-fill patterns into
the atlases a host loads once and draws from — the same atlas the
[host-surface `draw_sprite` / `draw_pattern` callbacks](../api/render.md#host-surface-vector-callbacks)
and the [draw-ready GPU scene](../api/render.md#draw-ready-gpu-scenes-batched-buffers)
sample by name. Inputs are the catalogue's SVG symbol / area-fill sources + the CSS;
output is an `Atlas` (packed PNG + a JSON index of cell rects). Colour tables and
line styles live with the [MapLibre style](./style.md) builders.

```zig
// The point-symbol atlas: every S-101 symbol packed into one sheet.
pub fn sprite.spriteAtlas(a: std.mem.Allocator, srcs: []const sprite.SvgSrc,
                          css_data: []const u8) !sprite.Atlas

// The area-fill pattern atlas (fill patterns + the symbols they place).
pub fn sprite.patternAtlas(a: std.mem.Allocator, fills: []const sprite.AreaFillSrc,
                           symbols: []const sprite.SvgSrc, css_data: []const u8) !sprite.Atlas

// The MapLibre "sprite-mln" atlas — every symbol + area-fill pattern in one sheet,
// each cell centered on its pivot, at display density `ratio` (1, 2, …). This is
// the atlas a GPU host uploads; pass the SAME ratio you pass renderGpuScene /
// tile57_bake_sprite_mln, or the sprite UVs won't index it.
pub fn sprite.spriteMln(a: std.mem.Allocator, symbols: []const sprite.SvgSrc,
                        fills: []const sprite.AreaFillSrc, css_data: []const u8,
                        soundings: []const []const u8, ratio: f64) !sprite.Atlas
```

`sprite.Atlas` carries the packed pixels + the `{name → CellRect}` index.
`sprite.glyph.build(a, font, cps, em_px, pad)` is the SDF label-glyph counterpart,
for a host that draws text as SDF quads.
