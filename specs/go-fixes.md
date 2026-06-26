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

<!-- Add new findings below this line. -->
