---
id: limitations
title: Known Limitations
sidebar_position: 8
---

# Known Limitations

tile57 runs the official IHO S-101 Portrayal Catalogue, and on the
test cells (`US4MD81M.000`, `US5MD1MC.000` + updates) **every feature portrays
with zero rule errors** — depth areas and contours, soundings, coastline and land,
buoys and beacons, lights (including sector legs and arcs), dangers
(obstructions / wrecks / rocks), data-quality zones, restricted/anchorage areas,
and text labels.

But "no rule errors" is not the same as "pixel-perfect S-52", and this project is
an AI-built experiment and learning tool — **do not use it for navigation**. This
page is an honest list of what is still incomplete, taken from the engine code.

:::warning Not for navigation
See the warning on the [introduction](./intro.md). NOAA ENC charts are U.S. public
domain and not for navigation; this renderer adds its own gaps on top.
:::

## Portrayal gaps

- **Ignored portrayal-instruction keys.** The instruction translator
  (`src/s100/s101_instr.zig`) lowers the drawing vocabulary the catalogue
  actually leans on (point/line/text instructions, colour fills, area-fill and
  viewing-group references, `AugmentedRay` / `ArcByRadius` / `AugmentedPoint`
  construction — that is how light-sector legs and arcs render). A few keys are
  skipped: `AugmentedPath` (its path-grouping semantics — the grouped figures
  stroke individually instead), `AlertReference` (non-visual ECDIS alert
  metadata), `DisplayPlane`, `Hover`, `LinePlacement`, `TextVerticalOffset`,
  and the rare standalone `ScaleMinimum` / `ScaleMaximum` / `Dash` forms.
- **Full-length sector lines are not baked.** Sector legs render at their fixed
  S-52 display length; the mariner's *full-length sector line* variant (legs
  drawn to the light's nominal range) is not emitted, so the
  `show_full_sector_lines` setting currently has nothing to act on.
- **Sector figures stop at the cell's tile span.** Legs and arcs are
  tessellated per tile, and only tiles covering the source cell's bounding box
  are generated for that cell — a fixed-display-size arc near a cell edge is
  chopped where the neighbouring tile isn't baked from that cell.
- **Single-primitive rules vs. non-conformant geometry.** Some S-101 rules
  handle only one primitive (e.g. RecommendedTrack is Curve-only); a cell that
  encodes the feature with another primitive (an area-encoded recommended
  track) errors in the rule and the feature is suppressed.
- **Low-accuracy sounding ring via spatial QUAPOS.** SNDFRM04's low-accuracy
  ring triggers on the direct quality attributes (QUASOU/STATUS); the rule's
  fallback to the *spatial* quality-of-position (QUAPOS on the geometry) is not
  wired, so a sounding whose only low-accuracy signal is spatial QUAPOS misses
  its ring. (Approximate-position **line** dashing from spatial QUAPOS *is*
  applied.)
- **M_NSYS direction-of-buoyage arrow.** The IALA-A/IALA-B system boundary
  (MARSYS51 / NAVARE51 linestyles) is drawn; the ORIENT-driven DIRBOY01/A1/B1
  arrow (CentreOnArea) is not yet ported.

## Display / style gaps

- **Overscale hatch occlusion is tile-path only.** The S-52 §10.1.10 overscale
  indication (`OVERSC01`, see [architecture](./architecture.md)) is gated
  correctly everywhere, but only the generated MapLibre style sandwiches the
  hatch under finer at-scale fills. The PNG/PDF/ASCII surfaces draw in S-52
  priority order without that sandwich, so where a finer cell overlaps a
  coarser one the hatch can show through fills that should occlude it.
- **SCAMIN gating snaps to integer zooms outside bucket mode.** With a SCAMIN
  manifest, the style builds per-value layers with exact fractional native
  minzooms. The no-manifest zoom-filter fallback and the filter-gate mode
  still honour each feature's value, but MapLibre re-evaluates filters at
  integer zoom steps, so features appear/disappear on whole-zoom boundaries
  rather than at their precise 1:N display scale.

The `tile57` CLI baker runs the same full S-101 portrayal as the live chart
path, so a baked archive matches live generation. The native PNG/PDF renderer
has its own short list of deliberate gaps — see
[The Rendering Engine](./rendering.md#whats-deliberately-not-here-yet).

## ENC_ROOT loading

Opening an ENC_ROOT (`Chart.openPath` / `openCellsStreaming`) builds a cheap
spatial index (band + bbox per cell) and generates tiles **on demand**, parsing +
portraying only the cells a requested tile needs (best-available scale band per
tile, recent cells held in an LRU). The catalogue opens in seconds; memory stays
bounded. Caveats:

- **First-view latency.** The first tile over a fresh area parses + portrays its
  1–4 cells (tens of ms), then they're cached. Opening the whole NOAA catalogue
  also pays a one-time index scan (a few seconds, parsing every cell header).
- **Pre-bake for smooth panning.** For low first-view latency everywhere, bake the
  ENC_ROOT once with `tile57 bake` (per-cell tiles + an ownership partition) and
  serve tiles from the compositor. The whole catalogue is a multi-minute one-time
  bake; a region is far quicker.
- **Low zoom is style-gated.** The generated style's vector-source `minzoom` is
  the bake's tile floor (default 8), and MapLibre never requests tiles below a
  source's minzoom — nothing draws below it regardless of the data.
