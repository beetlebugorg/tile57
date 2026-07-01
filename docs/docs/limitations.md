---
id: limitations
title: Known Limitations
sidebar_position: 8
---

# Known Limitations

tile57 runs the official IHO S-101 Portrayal Catalogue, and on the
test cells (`US4MD81M.000`, `US5MD1MC.000` + updates) **every feature now portrays
with zero rule errors** — depth areas and contours, soundings, coastline and land,
buoys and beacons, lights, dangers (obstructions / wrecks / rocks), data-quality
zones, restricted/anchorage areas, and text labels.

But "no rule errors" is not the same as "pixel-perfect S-52", and this project is
an AI-built experiment and learning tool — **do not use it for navigation**. This
page is an honest list of what is still incomplete, taken from the engine code.

:::warning Not for navigation
See the warning on the [introduction](./intro.md). NOAA ENC charts are U.S. public
domain and not for navigation; this renderer adds its own gaps on top.
:::

## Geometry-construction instructions

The catalogue builds some figures from geometry-construction instructions
(`AugmentedRay`, `AugmentedPath`, `ArcByRadius`, `CoverageFill`). The engine does
not lower all of these into tile geometry — features that depend on a construction
the engine does not handle lose that constructed part (the rest of the feature —
its symbol, fill, or label — still draws).

## Portrayal / live-path gaps

The live cell→MVT path emits the layers in the [tile schema](./tile-schema.md)
including the `*_scamin` declutter buckets and `draw_prio` ordering. The spatial /
geometry Host binding now serves real point geometry to the rules (so dangers and
soundings portray without the earlier nil-depth crash / "C stack overflow"), and
orientation + clearance complex attributes are synthesized. Remaining gaps:

- **Approximate-position (QUAPOS) dashing.** QUAPOS is parsed and aggregated per
  feature, but the solid→dashed line-style switch for low-accuracy geometry is not
  applied yet.
- **Light sectors** — sectored/directional light legs and arcs are not yet emitted
  by the live path (they exist in the Go baker).
- **Native S-52 fallbacks for unportrayed classes.** Some S-57 classes have no
  usable S-101 rule output and the Go reference draws a native S-52 placeholder.
  SweptArea/SWPARE (dashed CHGRD boundary + SWPARE51 bracket + "swept to" label)
  and the NEWOBJ new-object box (dashed CHMGF outline) are now drawn; the
  navigational-system-of-marks boundary (M_NSYS, Go's `navSystemBuild`) is still
  omitted.
- **Single-primitive rules vs. non-conformant geometry.** Some S-101 rules handle
  only one primitive (e.g. RecommendedTrack is Curve-only); a cell that encodes the
  feature with another primitive (an area-encoded recommended track) errors in the
  rule and the feature is suppressed — the Go reference behaves identically.

A pre-baked PMTiles archive from chartplotter-go does not have these gaps; they are
specific to tile57's own portrayal. The `tile57` CLI baker runs the same full
S-101 portrayal as the live `Source` path, so a baked archive matches live
generation.

## ENC_ROOT loading

Opening an ENC_ROOT (`Source.openCells` / `openCellsStreaming`) builds a cheap
spatial index (band + bbox per cell) and generates tiles **on demand**, parsing +
portraying only the cells a requested tile needs (best-available scale band per
tile, recent cells held in an LRU). The catalogue opens in seconds; memory stays
bounded. Caveats:

- **First-view latency.** The first tile over a fresh area parses + portrays its
  1–4 cells (tens of ms), then they're cached. Opening the whole NOAA catalogue
  also pays a one-time index scan (a few seconds, parsing every cell header).
- **Offline bake.** For smooth panning everywhere, bake the ENC_ROOT once to a
  cached PMTiles archive (`tile57 bake`, or `bakeArchive` /
  `tile57_bake_pmtiles`) and open that instead. The whole catalogue is a
  multi-minute one-time bake; a region is far quicker.
- **Low zoom is style-gated.** The generated style's vector-source `minzoom`
  (9 in the bundled styles) means nothing draws below it regardless of the data.
- **Update merge gaps.** Feature/vector insert/delete/modify and the SGCC/FSPC
  control fields (indexed coordinate / spatial-pointer edits) are applied; VRPC
  (indexed edits to an edge's begin/end node pointers) is not modelled — a VRPT
  update is taken as a full replacement.
