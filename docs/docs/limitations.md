---
id: limitations
title: Known Limitations
sidebar_position: 9
---

# Known Limitations

tile57 runs the official IHO S-101 Portrayal Catalogue, and on the
test charts (`US4MD81M.000`, `US5MD1MC.000` + updates) **every feature portrays
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

## Native S-101 charts

A native S-101 (S-100 Part 10a) chart is read directly into the S-101 portrayal
model with no conversion — the format is auto-detected from the file, so `png`,
`bake`, and the C API accept a native S-101 `.000` transparently, and its
sequential `.001…` update files are applied (record-level insert / delete /
modify by identity). On the SHOM France test datasets and the S-164 update
conformance set every feature portrays (no errors), including complex attributes
such as light sectors and buoy topmarks. The cursor-pick report serves each
feature's S-101 class and full attribute tree (nested complex attributes
included), with text preserved as UTF-8. One area is not yet wired for native
S-101:

- **Feature-to-feature associations.** `FASC`/`INAS` records are parsed but the
  StructureEquipment relationship (e.g. a light *supportedBy* its beacon) is not
  yet resolved for the query report's related-feature grouping. It carries no
  portrayal weight for the test charts, so rendering is unaffected.

## S-57 → S-101 conversion

An S-57 chart's portrayal rules are S-101, so an S-57 chart passes through an
S-57 → S-101 adapter (`src/s101/adapter.zig`) before the rules run (a native
S-101 chart skips this — it is already in the S-101 model). S-57 has no perfect
S-101 translation; the adapter follows the IHO S-65 conversion guidance, and the
result is **best effort**:

- **Missing S-101 content stays missing.** S-101 attributes and features with
  no S-57 source are never invented; rules that test them take their fallback
  branch.
- **Unconvertible objects fall back or drop.** An S-57 object class with no
  S-101 equivalent portrays as the S-52 question mark (QUESMRK1) — or, where
  the S-65 guidance says the object is simply not carried into S-101 (e.g. an
  area-geometry recommended track), it is dropped.

## Portrayal gaps

- **Ignored portrayal-instruction keys.** The instruction translator
  (`src/s101/instructions.zig`) lowers the drawing vocabulary the catalogue
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
- **Sector figures can stop at a tile boundary beyond the owning chart.** The
  compositor keeps a light's sector legs and arcs WHOLE across ownership
  boundaries (they are fixed-size decorations anchored at the light, exempt
  from face clipping). The remaining gap: a figure reaching into a tile where the owning
  chart holds no ground at all is absent there — the compositor never consults
  that chart for the tile — so a figure within roughly one tile of the chart's
  owned ground can cut at that tile's edge (directional ground-length legs can
  reach further).
- **Single-primitive rules vs. non-conformant geometry.** Some S-101 rules
  handle only one primitive (e.g. RecommendedTrack is Curve-only); a chart that
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
  priority order without that sandwich, so where a finer chart overlaps a
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

Opening an ENC_ROOT (`Chart.openPath` / `openChartsStreaming`) builds a cheap
spatial index (band + bbox per chart) and reads a chart's bytes only when a
metadata or feature query needs them — the catalogue opens in seconds and
memory stays bounded. It serves metadata and extraction only: tiles and views
always come from a bake (bake each chart once, then compose on demand).
Caveats:

- **Baking is the import step.** The whole NOAA catalogue is a multi-minute
  one-time bake (`tile57 bake` / `tile57_bake_tree`); a region is far quicker,
  and re-runs are incremental — only charts whose source changed re-bake.
- **Index-scan cost.** Opening the whole catalogue as a streaming chart pays a
  one-time index scan (a few seconds, parsing every chart header).
- **Low zoom is style-gated.** The generated style's vector-source `minzoom` is
  the bake's tile floor (default 8), and MapLibre never requests tiles below a
  source's minzoom — nothing draws below it regardless of the data.
