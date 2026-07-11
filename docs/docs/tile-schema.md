---
id: tile-schema
title: Tile Schema
sidebar_position: 8
---

# Tile Schema

tile57's vector tiles use a fixed set of layers and fields. The generated
MapLibre style depends on this schema, so the names are a contract. Do not
rename a layer or a field without updating the style generator
(`src/style/maplibre.zig`) to match **and bumping the schema version**.

This vocabulary is versioned as **`tile57/2`**. The tiles and the portrayal
assets are generated from the same S-101 catalogue and stamped with that
`schema_version`, so a renderer can refuse a schema it doesn't speak. Any change
to a layer name or field key bumps it.

Every tile uses an extent of **4096** and a buffer of **64**.

:::note Live path coverage
Whether the tiles come from a pre-baked PMTiles archive or are generated live from
a raw S-57 chart, the schema is the same. The live path (`src/scene/`)
emits `areas`, `area_patterns`, `lines`, `point_symbols`, `soundings`, and
`text`. Features carrying SCAMIN (attr 133) keep it as the per-feature `scamin`
property, and every feature has a `draw_prio` for S-52 fill ordering. DEPCNT lines
carry `valdco` (the contour value, including the 0 m drying line) for line-centre
labels. The same schema is encoded as MLT or MVT (see
[architecture](./architecture.md)).
:::

## Color is always a name

Fields like `color_token` and `halo_color_token` hold S-101 color **names**, not
RGB values. The style resolves them against `colortables.json` to get the right
Day, Dusk, or Night color — which is how a renderer switches palette without
regenerating tiles.

## Zoom levels and navigational bands

A nautical chart is not one map at one scale. NOAA compiles each chart (an ENC *cell*) for a
**navigational purpose** — from a wide overview to a close-in berthing plan — and
the right chart to show depends on how far you are zoomed in. Each chart carries a
compilation scale (`CSCL`, a `1:N` denominator) that maps to a band, and each band
covers the Web-Mercator zoom range that matches its scale:

| Band | Zoom range |
| --- | --- |
| Overview | 5 – 8 |
| General | 8 – 10 |
| Coastal | 10 – 12 |
| Approach | 12 – 14 |
| Harbor | 14 – 16 |
| Berthing | 16 – 18 |

Vector tiles scale crisply, so a renderer **overzooms** the top level rather than
baking more. Within a band, a feature may carry an S-52 **SCAMIN** (the scale
below which it should disappear) as the per-feature `scamin` property; the style
hides the feature once the display is coarser than `1:scamin`, so minor features
drop out at their own thresholds and the chart never clutters. (Earlier schema
versions split these into separate `*_scamin` layers; `tile57/2` folds them back
into the base layers, gated by the per-feature property.)

## The six layers

Every feature also carries shared metadata the style and the pick report read,
regardless of layer:

| Field | Type | Meaning |
| --- | --- | --- |
| `class` | string | S-57 object-class acronym. |
| `cell` | string | Source chart stem. |
| `s57` | string | The feature's full S-57 attribute set as a JSON object (the pick report). |
| `draw_prio` | int | S-52 draw priority (fill/stroke ordering). |
| `cat` | int | Display category (base / standard / other gating). |
| `band` | int | Navigational band rank. |
| `scamin` | int | SCAMIN `1:N` denominator — present only on features that carry one. |

`bnd`, `pts`, `plane`, `vg`, and the `date_*` keys are additional gating
properties emitted only when relevant. The layer-specific fields follow.

### areas

Filled polygons, such as depth areas and land.

| Field | Type | Meaning |
| --- | --- | --- |
| `color_token` | string | Fill color name. |
| `drval1`, `drval2` | number | Depth-range min/max for depth areas (DEPARE/DRGARE). |
| `oscl` | int | Overscale denominator, present when the chart shows finer than its compilation scale. |

### area_patterns

Polygons filled with a repeating pattern instead of a flat color.

| Field | Type | Meaning |
| --- | --- | --- |
| `pattern_name` | string | Name of the fill pattern. |
| `oscl` | int | Overscale denominator, as above. |

### lines

Stroked lines, such as depth contours and coastline. Symbolized/complex line runs
and sector-light legs fold in here too.

| Field | Type | Meaning |
| --- | --- | --- |
| `color_token` | string | Stroke color name. |
| `width_px` | number | Stroke width in pixels. |
| `dash` | string | Dash pattern (empty = solid). |
| `valdco` | number | Contour value for DEPCNT lines (including the 0 m drying line), for line-centre labels. |
| `ls_style` | string | Complex line-style name (symbolized lines). |
| `ls_arc0` | number | Sector-arc start bearing (sector-light legs). |

### point_symbols

Single symbols placed at a point, such as buoys and beacons.

| Field | Type | Meaning |
| --- | --- | --- |
| `symbol_name` | string | Name of the symbol. |
| `rotation_deg` | number | Rotation in degrees. |
| `rot_north` | int | `1` = hold the symbol north-up (line-placed and point symbols). |
| `scale` | number | Scale factor. |
| `danger_depth`, `sym_deep` | number, string | Isolated-danger depth + the deep-water symbol variant (the DANGER01/DANGER02 swap). |

### soundings

Depth soundings, drawn as digit glyph strings (SNDFRM digit composition).

| Field | Type | Meaning |
| --- | --- | --- |
| `sym_s`, `sym_g` | string | Bold + faint digit glyph strings, in metres. |
| `sym_s_ft`, `sym_g_ft` | string | The same glyph strings, in feet. |
| `depth` | number | Sounding depth in metres. |

### text

Text labels (the name typically derives from `OBJNAM` via the `featureName`
attribute).

| Field | Type | Meaning |
| --- | --- | --- |
| `text` | string | The label text. |
| `font_size_px` | number | Font size in pixels. |
| `color_token` | string | Text color name. |
| `halo_color_token` | string | Halo color name (`""` = no halo). |
| `halo_width` | number | Halo width in pixels (`0` = none). |
| `halign`, `valign` | string | Horizontal and vertical alignment. |
| `loff` | string | Pixel offset `"ux,uy"` from the anchor, present only when nonzero. |
| `tgrp` | int | S-52 text viewing group. |
