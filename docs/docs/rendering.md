# The Rendering Engine

tile57 contains a full **native S-52 rendering engine**: it draws a finished
chart — raster PNG or vector PDF — straight from ENC charts, with no MapLibre,
browser, or GPU involved. This page explains how it works, how to use it, and
how to extend it.

## The one-paragraph version

Charts are turned into **draw calls**. The *scene generator* reads charts, runs
the official S-101 portrayal rules, and calls methods like `fillArea("DEPVS",
rings)` or `drawSymbol("BOYLAT13", point)` on a **Surface**. What happens next
depends on which Surface is listening: the tile surface *serializes* those
calls into MVT/MLT tiles for a MapLibre client to draw later; the pixel
surface *resolves* them (color tokens → RGB, symbol names → vector outlines)
and paints them onto a **Canvas** — a raster canvas for PNG, a PDF canvas for
print. One engine, pluggable outputs.

## The architecture

```
             ┌──────────────────────────────────────────────┐
 ENC chart ─►│  scene generator (src/scene/)                │
             │  parse → S-101 portrayal (embedded Lua) →    │
             │  project → clip → draw calls, per tile/view  │
             └───────────────────┬──────────────────────────┘
                                 │  the Surface interface (src/render/surface.zig)
                                 │  fillArea · fillPattern · strokeLine ·
                                 │  drawSymbol · drawSounding · drawText
              ┌──────────────────┼─────────────────────┐
              ▼                  ▼                     ▼
        TileSurface         NoopSurface           PixelSurface (src/render/pixel.zig)
        serialize the       discard (bench)       resolve + layout + declutter
        semantics                                      │
              │                                        │  the Canvas interface
              ▼                                        │  fillPath · strokePath ·
        MVT / MLT tiles                                │  fillPattern · drawGlyphRun
        + MapLibre style                     ┌─────────┴─────────┐
        (client draws them)                  ▼                   ▼
                                       RasterCanvas         PdfCanvas
                                       → PNG                → PDF (real text objects)
```

Two interfaces do all the work:

- **Surface** (`src/render/surface.zig`) — the *semantic* interface. Calls carry
  S-52 meaning: color **tokens** like `DEPVS`, symbol **names** like
  `BOYLAT13`, raw sounding depths, S-52 metadata (drawing priority, display
  category, SCAMIN). Nothing is resolved yet. This is what lets the tile
  surface emit *re-styleable* tiles — a MapLibre client can switch day/night
  palettes or the safety contour without re-baking, because the tiles still
  contain the names, not the pixels.

- **Canvas** (`src/render/canvas.zig`) — the *drawing* interface. By the time a
  call reaches a Canvas, everything is resolved: RGB colors, flattened
  polygon outlines, positioned glyphs. A Canvas knows nothing about charts.
  This is deliberately the same shape as a classic 2-D drawing API, so a new
  output format is one small file.

Between them sits the **PixelSurface**, written once and shared by every
pixel format. It does the genuinely chart-aware work:

- the **resolver** (`src/render/resolve.zig`) turns color tokens into RGB at
  the chosen palette and evaluates the mariner's display gates — display
  category, SCAMIN scale gating, viewing groups, text groups — *live*, at
  render time, from real settings;
- **symbols** replay the official catalogue SVGs as vector outlines
  (`src/render/symbols.zig` + the nanosvg-backed store in `src/sprite/`) —
  no bitmap blitting, crisp at any scale;
- **soundings** are composed digit-by-digit from the same SNDFRM04 routine
  the tile path uses, at the mariner's *actual* safety depth and display
  unit;
- **text** is shaped with a from-scratch TrueType reader
  (`src/render/font.zig`, embedded Noto Sans) and decluttered over the whole
  scene — higher drawing priority wins, exactly like a real ECDIS;
- everything is buffered, sorted into S-52 paint order (areas → patterns →
  lines → symbols → soundings → text), and painted through the Canvas.

The **PDF canvas** deserves a note: labels become *real PDF text objects*
(the font is embedded, with a ToUnicode map), so the output is selectable,
searchable, and print-sharp — not a picture of text. Both outputs are
byte-deterministic: the same scene renders the same file, every time.

### Why the mariner settings matter more here

The tile path has to **freeze** the portrayal context at bake time (a tile
archive can't re-run Lua per user), and papers over it with swappable
properties the style toggles at runtime. The pixel path evaluates the
mariner's display gates — palette, display category, SCAMIN, viewing groups,
text groups, size scale — live at render time for any source. Rendering a
live chart (the CLI on a `.000`, or `Chart.openBytes` in Zig) goes further:
the S-101 rules themselves run with the mariner's *actual* safety contour,
boundary style, and point-symbol style — what you see is what the rules
decided for *your* settings, the ECDIS-faithful path. Rendering a baked
archive replays its tiles, so the rule outcomes are the bake's; the
swappable parts re-evaluate.

## Using it

### From the command line

```sh
# One tile of a chart, as a 512px PNG
tile57 png US5MD1MC.000 14 4712 6280 -o tile.png --size 512

# A view (any centre, fractional zoom, any size) from a single chart
tile57 png US5MD1MC.000 --view -76.48,38.974,15.1 --size 1600x1200 -o annapolis.png

# The same view as a vector PDF with selectable text
tile57 pdf US5MD1MC.000 --view -76.48,38.974,15.1 --size 1600x1200 -o annapolis.pdf

# From a baked PMTiles bundle instead of the source chart (tile replay)
tile57 png chart.pmtiles --view -76.48,38.974,15.1 --size 1024x768 -o out.png

# Mariner settings
tile57 png ... --safety 5 --safety-depth 5 --feet --palette night \
               --no-names --plain --simplified --dq --scale 1.5
```

### From C (and therefore Go, Python, C++, …)

Everything is bake, then render: open a baked archive as a chart and ask it
for a view (same allocate-`*out` / free-with-`tile57_free` convention as the
rest of the ABI):

```c
tile57 *c = NULL;
tile57_open("US5MD1MC.pmtiles", &c, NULL);   /* a baked archive */

tile57_mariner m;
tile57_mariner_defaults(&m);
m.safety_contour = 5.0;
m.scheme = TILE57_SCHEME_NIGHT;

uint8_t *png; size_t len;
tile57_png(c, -76.48, 38.974, 15.1, 1600, 1200, &m, &png, &len, NULL);
/* ... write/display png ... */
tile57_free(png);

uint8_t *pdf; size_t plen;
tile57_pdf(c, -76.48, 38.974, 15.1, 1600, 1200, &m, &pdf, &plen, NULL);
```

That renders ONE chart, no composition. A view across a whole chart library
is the same call on the compositor — `tile57_compose_png` / `_pdf` — which
composes every covering tile through the ownership partition first. See the
[C API](./c-api.md).

`m.size_scale` calibrates physical size (so 1 S-52 millimetre is a true
millimetre on your display) and doubles as the @2x knob. Every field of
`tile57_mariner` — categories, text groups, contours, units — evaluates live.

### From Zig

Both interfaces are directly available: build a `PixelSurface`, drive it with
`scene.generateTile` / `scene.generateView`, or replay a decoded tile with
`scene.replayTile`. See `tools/bake.zig`'s `runRender` for a complete worked
example.

## Extending it

**A new output format = one Canvas implementation.** Implement four methods
(`fillPath`, `strokePath`, `fillPattern`, `drawGlyphRun`) over your target —
an SVG writer, a framebuffer blitter, a plotter driver — and every chart
feature, symbol, and label arrives already resolved and positioned.
`src/render/pdf.zig` (~350 lines) is the model to copy.

**A new tile/serialization format = one Surface implementation.** Implement
the ten Surface methods and you receive the full semantic stream — this is
how MVT and MLT are done (`TileSurface` in `src/scene/scene.zig`), and how a
GeoJSON debug dump or a GPU display list would be done.

**From the C ABI:** both interfaces are exposed as callback tables.
`tile57_canvas` drives a `tile57_canvas_cb` — C function pointers receiving
resolved, flattened paths, patterns, and glyph outlines in pixel space, in
paint order (the Canvas seat). `tile57_surface` drives a `tile57_surface_cb` —
the world-space, semantically tagged stream (per-feature class + SCAMIN, world
anchors, reference-pixel outlines) a GPU host tessellates once and transforms
per frame (the Surface seat). Both have composed twins on the compositor
(`tile57_compose_canvas` / `tile57_compose_surface`). A custom output format in
Zig is still one small file in `src/render/`.

## What's deliberately not here (yet)

- Contour labels render horizontal (not rotated along the line).
- No kerning (chart labels are short; Noto's advances read fine).
- Translucent fills print opaque in PDF.
- Archive replay doesn't overzoom past the baked range (the compositor serves
  one fill-up zoom past it).
- The PDF embeds the whole label font (~600 KB) rather than a subset.
