---
id: tile-schema
title: Tile Schema
sidebar_position: 6
---

# Tile Schema

The vector tiles use a fixed set of layers and fields. The style depends on this
schema, so the names are a contract — it matches
[chartplotter-go's schema](https://beetlebugorg.github.io/chartplotter/tile-schema)
so the same generated S-52 style works against either. Do not rename a layer or a
field without updating `style/build_style.py` to match.

Every tile uses an extent of **4096** and a buffer of **64**.

:::note Live path coverage
Whether the tiles come from a pre-baked PMTiles archive or are generated live from
a raw S-57 cell, the schema is the same. The live path
(`tilegen/src/s57_mvt.zig`) currently emits `areas`, `area_patterns`, `lines`,
`complex_lines`, `point_symbols`, `soundings`, and `text`; the `*_scamin`
declutter buckets are still to come (see [Known limitations](./limitations.md)).
:::

## Color is always a name

Fields like `color_token` and `halo_color_token` hold S-101 color **names**, not
RGB values. The style resolves them against `colortables.json` to get the right
Day, Dusk, or Night color — which is how the viewer switches palette without
regenerating tiles.

## Zoom levels and navigational bands

A nautical chart is not one map at one scale. NOAA compiles each ENC cell for a
**navigational purpose** — from a wide overview to a close-in berthing plan — and
the right cell to show depends on how far you are zoomed in. Each cell carries a
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

Vector tiles scale crisply, so the viewer **overzooms** the top level rather than
baking more. Within a band, each feature carries an S-52 **SCAMIN** (the scale
below which it should disappear); honoring it per-feature is what the `*_scamin`
buckets are for, so minor features drop out at their own thresholds and the chart
never clutters.

## The seven layers

### areas

Filled polygons, such as depth areas and land.

| Field | Type | Meaning |
| --- | --- | --- |
| `color_token` | string | Fill color name. |
| `class` | string | S-57 object class. |
| `draw_prio` | int | Draw priority. |
| `cat` | — | Category. |
| `bnd` | — | Boundary-pass marker. |

### area_patterns

Polygons filled with a repeating pattern instead of a flat color.

| Field | Type | Meaning |
| --- | --- | --- |
| `pattern_name` | string | Name of the fill pattern. |
| `class` | string | S-57 object class. |
| `draw_prio` | int | Draw priority. |

### lines

Stroked lines, such as depth contours. Sector-light legs and arcs also go here.

| Field | Type | Meaning |
| --- | --- | --- |
| `class` | string | S-57 object class. |
| `color_token` | string | Stroke color name. |
| `width_px` | int | Stroke width in pixels. |
| `dash` | — | Dash pattern. |

### complex_lines

Lines drawn with a named, repeating line style.

| Field | Type | Meaning |
| --- | --- | --- |
| `class` | string | S-57 object class. |
| `linestyle_name` | string | Name of the line style. |

### point_symbols

Single symbols placed at a point, such as buoys and beacons.

| Field | Type | Meaning |
| --- | --- | --- |
| `class` | string | S-57 object class. |
| `symbol_name` | string | Name of the symbol. |
| `rotation_deg` | number | Rotation in degrees. |
| `scale` | number | Scale factor. |
| `offset_x`, `offset_y` | number | Pixel offset from the point. |
| `halo_color_token` | string | Halo color name. |
| `draw_prio` | int | Draw priority. |

### soundings

Depth soundings, drawn as digit symbols (SNDFRM04 digit composition).

| Field | Type | Meaning |
| --- | --- | --- |
| `class` | string | S-57 object class. |
| `symbol_names` | string | The digit symbols that make up the sounding. |
| `scale` | number | Scale factor. |
| `draw_prio` | int | Draw priority. |

### text

Text labels (the name typically derives from `OBJNAM` via the `featureName`
attribute).

| Field | Type | Meaning |
| --- | --- | --- |
| `class` | string | S-57 object class. |
| `text` | string | The label text. |
| `font_size_px` | number | Font size in pixels. |
| `color_token` | string | Text color name. |
| `halign`, `valign` | — | Horizontal and vertical alignment. |
| `offset_x`, `offset_y` | number | Pixel offset from the anchor. |
| `halo_color_token` | string | Halo color name. |
| `draw_prio` | int | Draw priority. |
