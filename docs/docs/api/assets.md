---
title: Portrayal assets
slug: /c-api/assets
---

# Generate portrayal assets

`tile57_bake_assets` produces all portrayal assets in memory — colour tables,
line styles, and the sprite / area-fill pattern atlases — from the library's
embedded catalogue (`catalog_dir` NULL/"") or an on-disk `PortrayalCatalog`.
Every non-NULL buffer is owned by the library; release the whole struct with
`tile57_assets_free`.

```c
typedef struct {
    uint8_t *colortables;  size_t colortables_len;
    uint8_t *linestyles;   size_t linestyles_len;
    uint8_t *sprite_json;  size_t sprite_json_len;   uint8_t *sprite_png;  size_t sprite_png_len;
    uint8_t *pattern_json; size_t pattern_json_len;  uint8_t *pattern_png; size_t pattern_png_len;
} tile57_assets;

tile57_status tile57_bake_assets(const char *catalog_dir, tile57_assets *out,
                                 tile57_error *err);
void tile57_assets_free(tile57_assets *out);
```

`tile57_bake_sprite_mln` is a focused variant that fills only the `sprite_json` /
`sprite_png` fields with a MapLibre **sprite-mln** atlas: every S-101 symbol packed
into one PNG, each atlas cell centered on its symbol's pivot, plus a JSON index of
`{name: {x, y, width, height, pixelRatio}}`. A GPU host loads this atlas once and
draws point symbols and area patterns as textured quads by name — the atlas the
[host-surface `draw_sprite`/`draw_pattern` callbacks](./render.md#host-surface-vector-callbacks)
hand back. `tile57_bake_glyph_sdf` is its text counterpart: an RGBA
signed-distance-field atlas of the label font, for a host that draws text as SDF
quads. Free either with `tile57_assets_free` as above.

```c
tile57_status tile57_bake_sprite_mln(const char *catalog_dir, tile57_assets *out,
                                     tile57_error *err);
tile57_status tile57_bake_glyph_sdf(tile57_assets *out, tile57_error *err);
```
