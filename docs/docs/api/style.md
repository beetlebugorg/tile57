---
title: MapLibre style
slug: /c-api/style
---

# Build a MapLibre style

`tile57_style_build` turns a MapLibre style template + the mariner's S-52 display
options + the S-52 colortables into a concrete style JSON, client-side. The
template + colortables come from the built-in `tile57_style_template` /
`tile57_colortables_default` (or the generated [assets](./assets.md)); the host fills
`tile57_mariner` from its UI. The same `tile57_mariner` struct configures the
[render surfaces](./render.md#render-surfaces).

```c
typedef enum { TILE57_SCHEME_DAY=0, TILE57_SCHEME_DUSK=1, TILE57_SCHEME_NIGHT=2 } tile57_scheme;
typedef enum { TILE57_DEPTH_METERS=0, TILE57_DEPTH_FEET=1 } tile57_depth_unit;
typedef enum { TILE57_BOUNDARY_SYMBOLIZED=0, TILE57_BOUNDARY_PLAIN=1 } tile57_boundary_style;

typedef struct tile57_mariner {
    tile57_scheme scheme;
    double shallow_contour, safety_contour, deep_contour, safety_depth;
    bool four_shade_water;
    tile57_depth_unit depth_unit;
    bool display_base, display_standard, display_other;
    bool data_quality, show_inform_callouts, show_meta_bounds, show_isolated_dangers_shallow;
    tile57_boundary_style boundary_style;
    bool simplified_points, show_full_sector_lines;
    bool text_names, show_light_descriptions, text_other;
    bool date_dependent, highlight_date_dependent;
    char date_view[9];              /* "YYYYMMDD" or "" (empty -> today) */
    bool ignore_scamin;             /* debug: drop SCAMIN scale-gating (not S-52) */
    double size_scale;              /* physical-scale multiplier; 1.0 = catalogue sizes */
    const int32_t *viewing_groups_off;  /* S-52 §14.5 deny-list of `vg` ids turned off */
    uint32_t viewing_groups_off_len;
    bool scamin_filter_gate;        /* gate SCAMIN with a live filter, not bucket layers */
    bool show_overscale;            /* S-52 §10.1.10 overscale indication: the
                                     * AP(OVERSC01) hatch over regions displayed finer
                                     * than their compilation scale. Defaults true. */
    double text_size_scale;         /* extra size multiplier for TEXT labels, on top of
                                     * size_scale (the engine scales glyph + collision box
                                     * together). 1.0 = none; 0 reads as 1.0. */
    double sounding_size_scale;     /* extra size multiplier for SOUNDINGS, on top of
                                     * size_scale (scales each digit + spacing together).
                                     * 1.0 = none; 0 reads as 1.0. */
    double device_scale;            /* device px per reference px — the HiDPI density the
                                     * SURFACE paths are drawn at (2.0 on a Retina backing
                                     * store). Describes the DISPLAY where size_scale
                                     * describes the mariner; the two multiply. Sizes text
                                     * and symbols AND their collision boxes in the units
                                     * the host actually draws in. The pixel outputs ignore
                                     * it (that density is already in the requested
                                     * width/height). 1.0 = a 1x framebuffer; 0 reads as
                                     * 1.0. */
    bool national_names;            /* label a feature with its national-language name
                                     * (NOBJNM) where the cell has one. The bake stores
                                     * that name beside the portrayed one, so this
                                     * switches without a re-bake. A feature with only
                                     * NOBJNM is labelled with it whatever this says. */
} tile57_mariner;

void tile57_mariner_defaults(tile57_mariner *m);   /* canonical defaults, date_view = "" */

/* enabled_bands: NULL = show all; else only features whose band rank is in the
 * array. scamin: the distinct SCAMIN denominators present in the source (e.g.
 * from tile57_chart_scamin) — when non-NULL the `_scamin` layers split into per-value
 * native-minzoom buckets; scamin_lat is the representative latitude. */
tile57_status tile57_style_build(const char *template_json, size_t template_len,
                                 const tile57_mariner *m,
                                 const char *colortables_json, size_t colortables_len,
                                 const int32_t *enabled_bands, size_t enabled_band_count,
                                 const int32_t *scamin, size_t scamin_count, double scamin_lat,
                                 uint8_t **out, size_t *out_len, tile57_error *err);

/* Minimal MapLibre style-mutation ops to turn the style for `old_m` into the style
 * for `new_m` (same inputs as tile57_style_build) — for flicker-free mariner
 * toggles. Writes a JSON op array to *out/*out_len (free with tile57_free). */
tile57_status tile57_style_diff(const char *template_json, size_t template_len,
                                const tile57_mariner *old_m, const tile57_mariner *new_m,
                                const char *colortables_json, size_t colortables_len,
                                const int32_t *enabled_bands, size_t enabled_band_count,
                                const int32_t *scamin, size_t scamin_count, double scamin_lat,
                                uint8_t **out, size_t *out_len, tile57_error *err);
```

The S-52 colortables and base style template are baked into the library, so a host
can build a complete style with no on-disk catalogue or template file (free each
buffer with `tile57_free`):

```c
/* colortables.json (S-52 token -> hex per day/dusk/night) from the baked profile. */
tile57_status tile57_colortables_default(uint8_t **out, size_t *out_len,
                                         tile57_error *err);

/* Base MapLibre style template (layers + chart source + sprite/glyph URLs). scheme
 * selects the palette; source_tiles is the {z}/{x}/{y} URL (NULL -> a default
 * pmtiles:// source); sprite/glyphs are base URLs (NULL omits those layers);
 * minzoom is the chart source's tile floor, emitted verbatim (pass the archive's
 * real minzoom); maxzoom 0 -> engine default. tile_encoding is the source's tile
 * type (from tile57_info.tile_type): TILE57_TILE_TYPE_MLT emits "encoding":"mlt"
 * on the source so maplibre-gl >= 5.12 decodes MLT natively; 0 / MVT emits
 * nothing. */
tile57_status tile57_style_template(tile57_scheme scheme, const char *source_tiles,
                                    const char *sprite, const char *glyphs,
                                    uint32_t minzoom, uint32_t maxzoom,
                                    uint8_t tile_encoding,
                                    uint8_t **out, size_t *out_len, tile57_error *err);
```
