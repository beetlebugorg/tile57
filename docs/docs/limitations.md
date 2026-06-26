---
id: limitations
title: Known Limitations
sidebar_position: 7
---

# Known Limitations

chartplotter-native runs the official IHO S-101 Portrayal Catalogue, so most
everyday ENC features draw correctly: depth areas and contours, soundings,
coastline and land, buoys and beacons, lights, restricted/anchorage areas, and
text labels. On a representative harbor cell (`US4MD81M.000`), about **96% of
features** (≈6,900 of 7,200) portray via their real rules.

But the portrayal is **not complete**, and this project is an AI-built experiment
and learning tool — **do not use it for navigation**. This page is an honest list
of what does *not* render fully today, taken from the engine code.

:::warning Not for navigation
See the warning on the [introduction](./intro.md). NOAA ENC charts are U.S. public
domain and not for navigation; this renderer adds its own gaps on top.
:::

## Features dropped on a rule error

Some S-101 line and area rules need parts of the S-57 spatial topology that the
portrayal host does not model yet. When such a rule errors, the feature is
**suppressed** — drawn as nothing rather than as a placeholder — so it simply does
not appear. This is the most significant gap: an affected feature is missing, not
just mis-styled. The known offenders include Sounding edge cases,
Obstruction/Wreck/UnderwaterAwashRock (VALSOU depth-value handling), and
SpanOpening (complex clearance synthesis).

## Geometry-construction instructions

The catalogue builds some figures from geometry-construction instructions
(`AugmentedRay`, `AugmentedPath`, `ArcByRadius`, `CoverageFill`). The engine does
not lower all of these into tile geometry — features that depend on a construction
the engine does not handle lose that constructed part (the rest of the feature —
its symbol, fill, or label — still draws).

## Live-path layer gaps

The live cell→MVT path emits seven of the layers in the
[tile schema](./tile-schema.md). Still to come:

- **`*_scamin` declutter buckets** — per-SCAMIN layer splits so minor features
  drop out at their own zoom thresholds. Without them, the live path does not yet
  declutter as aggressively as a Go-baked archive.
- **Light sectors** — sectored/directional light legs and arcs are not yet emitted
  by the live path (they exist in the Go baker).

A pre-baked PMTiles archive from chartplotter-go does not have these gaps; they are
specific to live in-process generation.

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
