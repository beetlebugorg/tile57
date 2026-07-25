---
title: MapLibre style
slug: /zig-api/style
---

# Build a MapLibre style

`tile57.style` turns a MapLibre style template + the mariner's S-52 display
settings + the S-52 colour tables into a concrete style JSON, in pure Zig (no
libc/fs — you read the catalogue bytes and pass them in). The style and the tiles
come from the same S-101 catalogue, so the two stay in sync: RGB lives only in the
colour tables, and the tiles carry colour *tokens*. The same `tile57.Mariner`
settings configure the [render surfaces](./render.md#render-surfaces).

```zig
// Regenerate every layer from a template + the mariner settings baked in. The
// template carries only the host's source config (sprite / glyphs / chart
// tiles+zoom); this lifts that out and rebuilds the layer set. Returns
// alloc-owned bytes; a bad template or unusable colortables returns the template
// unchanged. now_unix drives date-dependent features.
pub fn style.buildFromTemplate(alloc: std.mem.Allocator, template_json: []const u8,
                               m: *const style.mariner.Settings, colortables_json: []const u8,
                               enabled_bands: ?[]const i32, now_unix: i64) ![]u8

// Same, threading a SCAMIN manifest (the distinct denominators present + a
// representative latitude) so the runtime style gets the SAME per-value
// native-minzoom bucket layers the offline bundle does. Empty scamin == plain
// buildFromTemplate.
pub fn style.buildFromTemplateScamin(alloc: std.mem.Allocator, template_json: []const u8,
                                     m: *const style.mariner.Settings, colortables_json: []const u8,
                                     enabled_bands: ?[]const i32, now_unix: i64,
                                     scamin: []const u32, scamin_lat: f64) ![]u8

// Build a style.json directly from Options (the lower-level entry the two builders
// call). style.Options is the full input set.
pub fn style.json(alloc: std.mem.Allocator, opts: style.Options) ![]u8

// The minimal MapLibre style-mutation ops to turn old_json into new_json — for
// flicker-free mariner toggles (retint / refilter without a full reload).
pub fn style.diff(alloc: std.mem.Allocator, old_json: []const u8, new_json: []const u8) ![]u8
```

`tile57.Mariner` (`style.mariner.Settings`) is the S-52 mariner display-options
struct — colour scheme, safety/shallow/deep contours, category and text switches,
size scales, SCAMIN and date-dependent gates. `style.mariner` also holds the
builders that encode those settings as MapLibre expressions.

## Colour tables + line styles

The colour tables and line styles the style references are produced from the S-101
catalogue XML, also in pure Zig:

```zig
// Parse ColorProfiles/colorProfile.xml -> colortables.json:
//   {"day":{TOKEN:"#rrggbb",…},"dusk":{…},"night":{…}}. Tokens sorted per palette.
pub fn style.colorTablesJson(alloc: std.mem.Allocator, xml: []const u8) ![]u8

// Parse the LineStyles/*.xml sources -> linestyles.json (period, dash array, pen
// colour token + width, placed symbols). ids sorted; pure-symbol styles dropped.
pub fn style.linestylesJson(alloc: std.mem.Allocator, srcs: []const style.LineStyleSrc) ![]u8
```

The sprite + pattern atlases the style references come from `tile57.sprite` (see
[Portrayal assets](./assets.md)).
