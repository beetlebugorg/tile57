# The Rendering Engine

tile57 contains a full **native S-52 rendering engine**: it draws a finished
chart — raster PNG or vector PDF — straight from ENC cells, with no MapLibre,
browser, or GPU involved. This page explains how it works, how to use it, and
how to extend it.

## The one-paragraph version

Charts are turned into **draw calls**. The *scene generator* reads cells, runs
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
 ENC cells ─►│  scene generator (src/scene/)                │
             │  parse → S-101 portrayal (embedded Lua) →    │
             │  project → clip → draw calls, per tile/view  │
             └───────────────────┬──────────────────────────┘
                                 │  the Surface interface (src/render/surface.zig)
                                 │  fillArea · fillPattern · strokeLine ·
                                 │  drawSymbol · drawSounding · drawText
              ┌──────────────────┼─────────────────────┐
              ▼                  ▼                     ▼
        MvtSurface          NoopSurface           PixelSurface (src/render/pixel.zig)
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

- **Surface** (`src/render/surface.zig`) — the *semantic* seam. Calls carry
  S-52 meaning: color **tokens** like `DEPVS`, symbol **names** like
  `BOYLAT13`, raw sounding depths, S-52 metadata (drawing priority, display
  category, SCAMIN). Nothing is resolved yet. This is what lets the tile
  surface emit *re-styleable* tiles — a MapLibre client can switch day/night
  palettes or the safety contour without re-baking, because the tiles still
  contain the names, not the pixels.

- **Canvas** (`src/render/canvas.zig`) — the *primitive* seam. By the time a
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
properties the style toggles at runtime. The native path has no such limit:
`render_view` runs the S-101 rules with the mariner's *actual* safety
contour, boundary style, and point-symbol style. What you see is what the
rules decided for *your* settings — the ECDIS-faithful path.

## Using it

### From the command line

```sh
# One tile of a cell, as a 512px PNG
tile57 png US5MD1MC.000 14 4712 6280 -o tile.png --size 512

# A view (any centre, fractional zoom, any size) from a whole ENC_ROOT —
# cells are selected and quilted per band automatically
tile57 png ~/charts/ENC_ROOT --view -76.48,38.974,15.1 --size 1600x1200 -o annapolis.png

# The same view as a vector PDF with selectable text
tile57 pdf ~/charts/ENC_ROOT --view -76.48,38.974,15.1 --size 1600x1200 -o annapolis.pdf

# From a baked PMTiles bundle instead of source cells (tile replay)
tile57 png chart.pmtiles --view -76.48,38.974,15.1 --size 1024x768 -o out.png

# Mariner settings
tile57 png ... --safety 5 --safety-depth 5 --feet --palette night \
               --no-names --plain --simplified --dq --scale 1.5
```

### From C (and therefore Go, Python, C++, …)

Two calls in `include/tile57.h`, mirroring `tile57_chart_tile`:

```c
tile57_chart *c = tile57_chart_open("/path/to/ENC_ROOT");

tile57_mariner m;
tile57_mariner_defaults(&m);
m.safety_contour = 5.0;
m.scheme = TILE57_SCHEME_NIGHT;

uint8_t *png; size_t len;
tile57_chart_render_view(c, -76.48, 38.974, 15.1, 1600, 1200, &m, &png, &len);
/* ... write/display png ... */
tile57_free(png, len);

uint8_t *pdf; size_t plen;
tile57_chart_render_pdf(c, -76.48, 38.974, 15.1, 1600, 1200, &m, &pdf, &plen);
```

`m.size_scale` calibrates physical size (so 1 S-52 millimetre is a true
millimetre on your display) and doubles as the @2x knob. Every field of
`tile57_mariner` — categories, text groups, contours, units — evaluates live.

### From Zig

The full seams are available: build a `PixelSurface`, drive it with
`scene.generateTileSurface` / `generateViewSurface`, or replay a decoded
tile with `scene.replayTileSurface`. See `tools/bake.zig`'s `runRender` for
a complete worked example.

## Extending it

**A new output format = one Canvas implementation.** Implement four methods
(`fillPath`, `strokePath`, `fillPattern`, `drawGlyphRun`) over your target —
an SVG writer, a framebuffer blitter, a plotter driver — and every chart
feature, symbol, and label arrives already resolved and positioned.
`src/render/pdf.zig` (~350 lines) is the model to copy.

**A new tile/serialization format = one Surface implementation.** Implement
the ten Surface methods and you receive the full semantic stream — this is
how MVT and MLT are done (`MvtSurface` in `src/scene/scene.zig`), and how a
GeoJSON debug dump or a GPU display list would be done.

**From the C ABI?** Not today — honestly. The Surface and Canvas seams are
Zig interfaces; the C ABI exposes the *products* (tiles, PNG, PDF, styles,
assets) and the *inputs* (charts, mariner settings), not the seams
themselves. A C-callback Canvas (your C function pointers receiving resolved
paths and glyph runs) is a feasible future addition — the seam was designed
so that would be mechanical — but it does not exist yet. If you need a
custom output, today the answer is a small Zig file in `src/render/`; the
build wires it in one place.

## What's deliberately not here (yet)

- Contour labels render horizontal (not rotated along the line).
- No kerning (chart labels are short; Noto's advances read fine).
- Translucent fills print opaque in PDF.
- PMTiles replay doesn't overzoom past the archive's baked range.
- The PDF embeds the whole label font (~600 KB) rather than a subset.
