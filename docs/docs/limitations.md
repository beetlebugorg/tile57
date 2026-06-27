---
id: limitations
title: Known Limitations
sidebar_position: 7
---

# Known Limitations

chartplotter-native runs the official IHO S-101 Portrayal Catalogue, and on the
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
- **Baker portrayal.** `chartplotter-bake` emits the `classify()` fallback styling,
  not full S-101 portrayal (the embedded Lua isn't linked into that exe yet).

A pre-baked PMTiles archive from chartplotter-go does not have these gaps; they are
specific to live in-process generation / the native baker.

## ENC_ROOT loading

Pointing a host at an ENC_ROOT directory loads every base cell and applies its
S-57 update files (`.001…`). Two caveats:

- **Overlay, not best-available.** All cells are drawn on top of each other; there
  is no per-zoom navigational-band selection yet, so overlapping cells of
  different compilation scales both render. (Go's baker does best-available band
  suppression at bake time; the live path does not.)
- **Update merge gaps.** Feature/vector insert/delete/modify and the SGCC/FSPC
  control fields (indexed coordinate / spatial-pointer edits) are applied; VRPC
  (indexed edits to an edge's begin/end node pointers) is not modelled — a VRPT
  update is taken as a full replacement.

## Native / platform

- **No platform chrome yet.** The current hosts are a headless PNG renderer
  (`chartplotter-render`) and a bare GLFW window (`chartplotter`). Real
  application chrome (SwiftUI on macOS, GTK4 on Linux) is future work.
- **macOS idle-blank escape hatch.** The interactive window renders on-demand by
  default. On displays where the layer goes blank when drawing stops, set
  `CHART_CONTINUOUS=1` to present every frame (see
  [Architecture → macOS rendering notes](./architecture.md#macos-interactive-rendering-notes)).
