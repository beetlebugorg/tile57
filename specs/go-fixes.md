# Go reference — issues found during the Zig port

A running list of bugs / dead code / clarity issues spotted in
`../chartplotter-go` while porting to Zig. Feed to the Go agent. Each item notes
where it is, why it's wrong, and a suggested fix. Nothing here blocks the port
(the Zig side works around or re-derives), but they're worth cleaning up.

---

## 1. `pkg/iso8211/ddr.go` — field-control parsing keys off a non-existent `"0001"` field

**Where:** `parseFieldControls` (and `parseSubfields`) in `pkg/iso8211/ddr.go`.

**What:** It looks for the field-control field `"0000"`, then expects all field
*definitions* in a single field tagged `"0001"`, splitting that by unit
terminator. But in ISO 8211 / S-57 there is no `"0001"` field — **each data
field is described by its own DDR entry keyed by the real tag** (`DSID`, `FRID`,
`VRID`, `ATTF`, `SG2D`, …). A descriptive field's content is
`<field-control-length bytes><name> UT <array-descriptor> UT <format-controls>`,
where the array descriptor carries the `!`-joined subfield labels.

**Effect:** On real ENC cells the `defEntry == nil` (`"0001"` missing) branch
returns an error *unless* the `"0000"` control field is also missing, in which
case it silently falls through to the "basic field controls from directory"
fallback — producing field controls with `DataStructCode/DataTypeCode = 0`, no
real subfields, and empty format controls. So `pkg/iso8211` never actually
surfaces the real per-field structure/subfield schema; `pkg/s57` must be
hardcoding S-57 semantics downstream (which is fine, but then this code is
misleading). The `SUB0/SUB1` placeholder labels in `parseSubfields` are likewise
never the real labels.

**Suggested fix:** Iterate the DDR's own directory entries (skip `"0000"`); for
each, parse `struct_code`/`type_code` from the first two bytes, skip the
`FieldControlLength` controls, then split the remainder on UT into
name / array-descriptor / format-controls. The subfield *labels* are in the
array descriptor (`!`-separated), not synthesized. (This is what the Zig
`iso8211.parseFieldControls` does; it yields ~15 field controls for
`US4MD81M.000` vs the Go path's degenerate fallback.) If the real schema isn't
needed because S-57 semantics are hardcoded in `pkg/s57`, consider deleting the
`"0001"`/`parseSubfields` machinery to avoid the impression that it works.

## 2. Baker emits MVT features unsorted — S-52 `draw_prio` not honored within a layer

**Where:** the tile baker (whatever writes `areas`/`lines`/etc. MVT layers in
`../chartplotter-go`).

**What:** MapLibre paints features within a fill/line layer in **feature order**
(it cannot sort a fill layer by an attribute). In `reference/tiles/annapolis.pmtiles`
tile `14/4711/6262`, the `areas` layer's feature order is `OBSTRN`(draw_prio 24),
`OBSTRN`(24), then ~86 `DEPARE` depth fills (draw_prio 9) — so the prio-9 water
fills paint **on top of** the prio-24 obstruction fills (z-inversion). Observed
class→prio tiers: `{3:LNDARE, 6:PONTON, 9:DEPARE, 12:BUISGL, 24:OBSTRN/DRGARE}`.

**Effect:** higher-priority area fills can be hidden under lower-priority ones;
the base-vs-`_scamin` source-layer split also forces a fixed cross-layer order
that ignores the single global S-52 `draw_prio`.

**Suggested fix:** within each MVT layer, emit features **pre-sorted ascending by
`draw_prio`** (array order = back-to-front). For the base/`_scamin` split, ensure
both variants share a priority tier or are interleaved consistently. (Symbol
layers can instead use `symbol-sort-key` from `draw_prio`; the Zig live path
should sort the same way when it reaches layer parity.)

## 3. Baker doesn't emit `sym_deep` / `danger_depth` / `pivot_center` on point symbols

**Where:** point-symbol portrayal in the baker.

**What:** The ported style (`style/build_style.py` `point_symbol_image` /
`soundings_image`) implements the S-52 danger-symbol swap (use `sym_deep` when
`danger_depth` is deeper than the safety contour) and the `pivot_center` (`ctr:`)
variant — but the Go-baked `point_symbols` features never carry `sym_deep`,
`danger_depth`, or `pivot_center`, so those branches are dead.

**Effect:** isolated dangers (WRECKS/OBSTRN/UWTROC) don't get the deep-vs-shoal
symbol swap relative to the mariner's safety contour; they always render the
shoal symbol.

**Suggested fix:** decide where the danger swap belongs. Either (a) emit
`sym_deep`/`danger_depth`/`pivot_center` from the baker so the style logic
activates, or (b) bake the resolved symbol directly and drop the dead style
branches (keep the style honest). Same choice will apply to the Zig live path.

<!-- Add new findings below this line. -->
