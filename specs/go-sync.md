# Go → Zig sync plan

Porting relevant improvements from `../chartplotter-go` into the Zig
chartplotter-native pipeline. Both projects run the **same** official IHO S-101
Portrayal Catalogue (Lua rules), so Go's *portrayal* fixes map onto our host
bindings / instruction adaptation / MVT emission:

| Go file | Zig equivalent |
|---------|----------------|
| `internal/engine/s101/*` (Host* callbacks) | `tilegen/csrc/lua_shim.c`, `tilegen/src/portray.zig` |
| `internal/engine/portrayal/*` (adapt → primitives) | `tilegen/src/s101_adapt.zig`, `s101_instr.zig`, `s57_mvt.zig` |
| `internal/s57/*` (model + geometry/topology) | `tilegen/src/s57.zig`, `iso8211.zig` |
| `internal/engine/bake/*` (multi-cell baking) | *no equivalent* — Zig generates live, single-cell |
| `web/src/chart-canvas/*` (style) | `style/build_style.py` |

Source: the per-commit analysis workflow (13 chartplotter-go commits, 2026-06-26).

## Port now — self-contained correctness wins

| Commit | What | Zig targets | Effort | Status |
|--------|------|-------------|--------|--------|
| `30db686` | Area-symbol placement: true centroid (shoelace) with even-odd inside test, pole-of-inaccessibility fallback only for concave/holed shapes. Symbols sit dead-centre instead of drifting. | `s57_mvt.zig` | M | **in progress** |
| `a9c8afd` | `surroundingDepth` derived attr for under/awash dangers (OBSTRN/WRECKS/UWTROC): shoalest DRVAL1 of any containing DEPARE/DRGARE. Stops UDWHAZ05 (ISODGR) over-triggering false danger marks in safe water. | `s101_adapt.zig` | M | todo |
| `49e9cd9` | Synthesize `zoneOfConfidence` complex attr from M_QUAL `CATZOC` so QualityOfBathymetricData.lua draws DQUAL data-quality symbology (currently absent). Needs complex-attr support in the Adapted struct (like `featureName`). | `s101_adapt.zig`, `portray.zig` | M | todo |
| `1b04ebb` | Parse `QUAPOS` (quality of position) on edges, aggregate per feature, expose to Lua so QUALIN02 dashes low-accuracy (approximate-position) lines. | `s57.zig`, `s101_adapt.zig`, `lua_shim.c` | M | todo |
| `f86b750` | Bake 0 m `VALDCO` (drying-line / chart-datum contour) into DEPCNT MVT; add a line-centre contour-label style layer. | `s57_mvt.zig`, `style/build_style.py` | M | todo |
| `3ca4d5f` | Emit S-52 `DrawingPriority` (already in the instruction stream, currently discarded) as a `draw_prio` MVT property; sort overlapping area fills by it in the style. Low visible impact on real ENC (no overlap), but a cheap correctness fix. | `s101_instr.zig`, `s57_mvt.zig`, `style/build_style.py` | S | todo |

## Defer — need a Zig feature that does not exist yet

| Commit | What | Blocked on |
|--------|------|-----------|
| `ec97fb2` | Place widely-spaced fill patterns (DQUALA*, MARCUL02, FSHFAC*, AIRARE02, SNDWAV01) as discrete lattice symbols (V1/V2 vectors, inset footprint test) instead of tiled textures. | Sparse-pattern placement + AreaFill metadata (V1/V2/SymbolRef) — Zig's `catalogue.zig` doesn't load AreaFills today. |
| `54de620` | Sparse-pattern symbols align on their design pivot (0,0), not the bbox centre. | Same — only matters once lattice patterns exist (`ec97fb2`). |
| `a402a5d` | Sector-light legs honor the AugmentedRay length CRS (ground metres vs display mm) so they don't shoot off-screen. | Sector-light figure rendering (rays/arcs) — `s101_adapt.zig` notes "sector arcs aren't rendered from the stream yet". |
| `98acc05` | `SY(INFORM01)` additional-information callouts at display priority 8 / category Other. | Display-category infrastructure in the tile format (cat/draw_prio filtering) — Zig tiles don't carry it yet. |

## Skip — Go batch-baking pipeline, N/A to live single-cell generation

| Commit | Why N/A |
|--------|---------|
| `72eff4e` | Cross-band line double-draw suppression via derived coverage — Zig has no multi-cell band pipeline. |
| `940191b` | Best-available coverage for cells without M_COVR + scale-boundary width — offline multi-cell coordination only. |

A pre-baked PMTiles archive from chartplotter-go already contains all the
deferred/skipped fixes; they only matter for Zig's *live* generation path.

## Bigger items (separate efforts)

- `ab9b63a` (SYMINS for NEWOBJ + SWPARE fallback + true symbol size) is high-value
  but large (~330-line `symins.go`, plus a global symbol-size change touching every
  point feature). Worth its own focused pass after the smaller ports land.
