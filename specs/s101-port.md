# S-101 portrayal engine — port plan

The S-101 portrayal (the successor to S-52) is an **executable specification**:
216 Lua rule files (~15.3K LOC) under the IHO Portrayal Catalogue. The decision
(see [[chartplotter-native-port]]) is to **embed Lua and run the rules**, not
re-port them. Lua 5.4 is embedded in `libchartplotter.a` (proven working).

## How it works (from the Go reference, internal/engine/s101)

- A Lua **framework** is loaded first:
  `require 'S100Scripting'; require 'PortrayalModel'; require 'PortrayalAPI';
   require 'Default'; require 'main'`. These define `PrimitiveType`, the feature
  object model, and `featurePortrayal:AddInstructions(...)` / `SimpleLineStyle`,
  plus globals (`sqParams`, `unknownValue`, `nilMarker`, `scaminInfinite`, …).
- Each **feature class** has a rule function, e.g. `DepthArea(feature,
  featurePortrayal, contextParameters)`, which emits instruction strings like
  `ColorFill:DEPVS`, `AreaFillReference:PRTSUR01`, `SimpleLineStyle('solid',
  0.64,'CHGRD')`, `PointSymbol:...`. Rules `require` shared sub-rules
  (`require 'DEPARE03'`).
- The `feature.*` properties (PrimitiveType, attributes, depthRange…) are backed
  by ~28 **Host\*** callbacks the host registers into Lua:
  HostGetFeatureIDs, HostFeatureGetCode, HostFeatureGetSimpleAttribute,
  HostFeatureGetComplexAttributeCount, HostFeaturePrimitive, HostFeaturePoints,
  HostGetSpatial, HostPortrayalEmit, HostGet*TypeInfo/TypeCodes (catalogue),
  HostFeatureGetSpatialAssociations, Host*GetAssociated*IDs, HostDebuggerEntry, …
- Dispatch: for each S-57 feature → look up its rule by object class → call it →
  collect emitted instructions → translate to drawing primitives → MVT.

## Inputs needed

1. **The Lua rules + framework** — load from a directory at runtime (the IHO
   catalogue's redistribution terms are unconfirmed; the Go repo does NOT commit
   it, embedding only in opt-in `_s101` builds). So: a `--s101 <dir>` path,
   defaulting to the Go repo's
   `internal/engine/s101catalog/catalog/PortrayalCatalog/Rules`. Do NOT vendor
   the rules into this repo.
2. **The Feature/Portrayal Catalogue** (FeatureCatalogue.xml) for type codes,
   attribute codes, complex-attribute structure — feeds the Host*TypeInfo calls.
   Parse with a streaming XML reader.

## Port steps (M6d remainder)

1. **[✅ validated] Lua 5.4 compatibility.** Go uses gopher-lua (Lua 5.1), but
   the full framework (S100Scripting/PortrayalModel/PortrayalAPI/Default/main —
   the most complex files) **loads cleanly in embedded Lua 5.4**
   (`chartplotter-render --s101check <rules-dir>`). The 5.4 decision holds; no LuaJIT
   needed. (Per-rule parse of all 216 is exercised lazily via `require` during
   dispatch; framework success is strong evidence they'll parse too.)
2. Implement `require` via `package.path = '<dir>/?.lua'` (stock Lua searcher).
3. Implement the ~28 Host\* callbacks as Lua C functions backed by the Zig
   `s57.Cell` + a "current feature" context (lua_pushcfunction + upvalues, or a
   registry-stored context pointer). Start with the subset DepthArea/Coastline/
   Sounding need; grow per rule.
4. Parse FeatureCatalogue.xml for the type/attribute code tables.
5. Translate emitted instructions (ColorFill / SimpleLineStyle / PointSymbol /
   TextInstruction / AreaFillReference …) into the MVT layers the existing style
   consumes (areas/lines/point_symbols/soundings/text + color_token etc.),
   replacing `s57_mvt.classify()`.
6. Differential-test the emitted instructions against the Go engine for a sample
   of features.

## Status: CORE DONE

Live S-101 portrayal works end to end — a raw S-57 cell renders as a real S-101
ECDIS chart in MapLibre, generated entirely in Zig (decode -> adapt via the real
Feature Catalogue -> embedded-Lua IHO rules -> instructions -> MVT). On
US4MD81M.000: **6933 / 7216 features (~96%) portray** via their actual rules —
land, coastlines, depth areas + contours, lit buoys (light flares +
characteristics), beacons, daymarks, landmarks, mooring/anchor symbols, labels.

Pass the rules dir as `chartplotter_source_open`'s `rules_dir` argument (or set the
`CHARTPLOTTER_S101_RULES` env var as a fallback when it is NULL). It defaults to
the vendored official catalogue at
`vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules`; otherwise the crude
classify() fallback is used.

Remaining (~4%, diminishing returns): Sounding (needs the SG3D multipoint
geometry wired into _HostFeaturePoints), Obstruction/Wreck/UnderwaterAwashRock
(VALSOU depth-value handling), SpanOpening (complex clearance synthesis —
Go's `clearances` map), and attribute-dependent class aliasing (LIGHTS ->
LightAllAround/Sectored, MORFAC by CATMOR). Also: differential-test instruction
streams vs Go; wire live generation into the interactive GLFW window (M3).

## History

- Lua 5.4 embedded + self-test passing.
- S-101 framework **loads** in 5.4 (`--s101check`).
- S-101 framework **executes** in 5.4 with stub Host callbacks + empty features
  (`--s101run` -> FeaturePortrayalItems=0). Runtime is 5.4-compatible.
- **Real S-101 rule proven end to end** (`--s101portray`): the actual
  `DepthArea`/`DEPARE03` rule, with a minimal hardcoded catalogue + one
  synthetic feature + the 13 context parameters + spatial glue, emits correct
  S-52 instructions: `ColorFill:DEPMS; AreaFillReference:DIAMOND1;
  AlertReference:SafetyContour; ...`. The whole portrayal path works.
- classify() placeholder in s57_mvt.zig covers DEPARE/LNDARE/COALNE/DEPCNT/etc.
  with live depth shading.

**Remaining (no unknowns; the connecting wire-up):**
- **step 5 DONE:** `s101_instr.zig` parses an instruction stream into a Portrayal
  (fill/patterns/lines/points/texts), tested on the real DEPARE03 output.
- **resolveCode** (`complex.go`): most S-57 classes map to a same-NAMED S-101
  class iff it exists in the catalogue, plus special aliasing (LIGHTS ->
  LightAllAround/Sectored/…, ADMARE, MORFAC by CATMOR, sector lights, …).
  Catalogue-driven.
- **buildRoot** (`complex.go`): synthesize the S-101 attribute tree from S-57
  attrs (acronym -> camelCase name aliasing, complex-attribute nesting,
  clearances map, derived attrs like depthRange{Min,Max}Value, featureName).
- **FeatureCatalogue.xml** parse -> FeatureTypes{bindings}, SimpleAttrs{valueType},
  ComplexAttrs, InformationTypes (feeds HostGet*TypeInfo/TypeCodes). Or a
  pragmatic per-class minimal catalogue to start (proven works for DepthArea).
- **Cell-backed Host binding:** drive Lua from Zig (@cImport lua.h) so the Host*
  read the live `s57.Cell` directly, OR a C accessor bridge. Run portrayal ONCE
  per cell (cache featureID -> instruction stream), then per tile translate
  (s101_instr) + emit geometry into MVT, replacing s57_mvt.classify().

Recommended order: minimal per-class catalogue + resolveCode/buildRoot for
DEPARE/COALNE/DEPCNT/SOUNDG -> Zig-driven Lua over real cell features ->
s101_instr -> MVT (visible real-S-101 render of a few classes) -> then expand to
the full FeatureCatalogue.xml + all classes.

---

## Live-generation layer parity (status 2026-06-26)

The live path (`engine/src/s57_mvt.zig`) now emits **areas, area_patterns,
lines, point_symbols, soundings, text** — the visible content roughly matches a
Go-baked render (depth shading, soundings at correct size, symbols, dashed
leading lines, patterned dredged/foul areas). The remaining `_scamin` /
`complex_lines_scamin` source-layers are SCAMIN *declutter* splits, not missing
data: those features still render via the base layers (decluttering is the
deferred SCAMIN-gating item).

**Fixed 2026-06-26 (this session):**
- Geometry assembly (`Cell.lineGeometryParts`) — disjoint rings/parts were
  joined by a spurious straight jump (CTNARE etc.) drawn as long crossing lines.
  Now split into connected parts (reverse-aware).
- Line styling — complex/named line styles (NAVLNE/RECTRC leading lines, CTNARE
  limits) now render dashed, not bold solid.
- Soundings — SOUNDG multipoint depths (SNDFRM04 digit composition). See item 1.
- Area fill patterns — AreaFillReference -> `area_patterns` layer.
- Symbol/sounding scale — was `0.08` (icon-size 1.0, ~2.8x too big); now the
  baker's `SYMBOL_SCALE` (0.02834627777, icon-size ~0.354).
- Test cells re-fetchable: `https://charts.noaa.gov/ENCs/US5MD1MC.zip` (+ US4MD81M).

**BIGGEST REMAINING GAP — feature-name text.** Only ~41/3156 features emit any
TextInstruction; the rest are *names*, which come from the `featureName` COMPLEX
attribute the adapter doesn't synthesize. The framework's contract (reverse-
engineered from PortrayalAPI.lua LookupAttributeValue):
  1. `featureName` must be in the feature's TypeInfo `AttributeBindings`
     (catalogue: `HostGetFeatureTypeInfo`) AND known as a complex attribute with
     a `name` sub-attribute (`HostGetComplexAttributeTypeInfo`).
  2. `HostFeatureGetComplexAttributeCount(id, '', 'featureName')` -> 1 when the
     feature has OBJNAM (code 116).
  3. `HostFeatureGetSimpleAttribute(id, 'featureName:1', 'name')` -> the OBJNAM
     value (path is `AttributeCode:Index` of the parent complex value).
Implement in `s101_adapt` (synthesize a featureName complex attr from OBJNAM) +
`lua_shim.c` (`lp_feature_complex_*`, currently `HostFeatureGetComplexAttribute
Count` = l_zero) + ensure `catalogue.json` binds `featureName`. Also drives
light characteristics and other name-derived labels.

### featureName DONE 2026-06-26
`featureName` complex attribute is now synthesized from OBJNAM (s101_adapt
captures it; `tgp_name`/`tgp_complex_count`; `lua_shim` serves the
`featureName:1` -> `name` sub-attribute). Verified: rules read real names. Few
new visible labels on US5MD1MC (named features are buoys, unlabeled by S-52
default) but it's required infra and labels named areas/regions elsewhere.

### Remaining text/portrayal gaps (investigated 2026-06-26)
Only ~41/3156 features emit text. By feature code: LightAllAround (lights),
DredgedArea, MagneticVariation. The big visible gaps + 83 portrayal errors:

1. **Light characteristic text** ("Fl R 4s 10M") — biggest visible gap. LIGHTS
   now classify as LightAllAround and the rule calls LITDSN02. LITDSN02
   *hardcodes* the value->abbreviation maps (LITCHR 2 -> "Fl", COLOUR 3 -> "R"),
   so it does NOT need catalogue enum labels — it reads the parsed attribute
   *value*. The description comes out empty, so this is the SAME root cause as
   the errors below: simple-attribute values aren't being parsed into the
   framework's value model (`.Value`). lp_simple_info reports ValueType, but the
   value wrapping (HostFeatureGetSimpleAttribute returns `{string}`; the
   framework must turn it into `{Value=number/enum, ...}` per ValueType) isn't
   yielding a usable `.Value`. Fix the value model and lights + many errors
   resolve together.
2. **Portrayal errors (83)** — `S100Scripting.lua:264 arithmetic on nil 'Value'`
   for Obstruction/Wreck/UnderwaterAwashRock (VALSOU/depth ScaledDecimal not
   provided); `SpanOpening` nil `verticalClearanceClosed`; `NavigationLine` nil
   `orientation`; `Sounding` "Invalid primitive type" (harmless — soundings are
   handled directly in s57_mvt, so the portrayal SOUNDG failure is ignorable, or
   feed MultiPoint to silence it). These need the missing simple attrs provided.
3. **Light sector arcs** — LightSectored (SECTR1/SECTR2/VALNMR) emits sector
   limit rays/arcs; the stream path can't carry them yet (needs AugmentedRay /
   the sector_lines geometry). Style layer exists (added 2026-06-26).
1. **soundings** — DONE 2026-06-26. `s57.Cell.soundingsFor` gathers a SOUNDG
   feature's SG3D multipoint; `s57_mvt.sndfrmSyms` ports SNDFRM04's core digit
   composition; each sounding is emitted into the `soundings` layer with
   sym_s/sym_g/depth. Verified on US5MD1MC.000. *Remaining:* the
   swept/low-accuracy-ring (`B1`/`C2`/`C3`)/negative prefixes (need quality
   attrs via the spatial-quality association) — those soundings don't yet match
   a sprite composite. Fully-correct alternative: feed `_HostFeaturePoints` real
   soundings + a MultiPoint spatial association so the Lua SOUNDG03/SNDFRM04 run
   and emit `AugmentedPoint:GeographicCRS,X,Y` + PointInstructions (parse those
   in `s101_instr`).
2. **sector_lines** — light sector limit rays (LIGHTS w/ SECTR1/SECTR2/VALNMR).
   Style layer now exists (added 2026-06-26); the live path must emit the layer.
3. **area_patterns** — `AreaFillReference` instructions -> `area_patterns` layer
   (`pattern_name`), so DRGARE/FOUL/quality fills tile.
4. **_scamin variants + complex_lines** — needs the SCAMIN split + complex
   (symbolised) line baking the Go path does.

## Deferred style-fidelity items (PMTiles + live)

- **SCAMIN gating** (`build_style.py`): `_scamin` layers + soundings/text draw
  unconditionally at all zooms (over-cluttered, heavy collision drop). Add a
  scale-vs-`scamin` zoom gate + mariner text-group (`tgrp`) filter. *Risk:* wrong
  zoom math hides features — verify against the Go web reference before shipping.
- **complex line symbology**: `complex_lines*` carry `linestyle_name` (e.g.
  CTNARE51) but are drawn as flat solid strokes. Approximate with a
  `line-dasharray` match on `linestyle_name`, or bake decorations into geometry.
- **@2x sprite** (NOT a bug): `sprite-mln@2x.png` is a 1x copy w/ `pixelRatio:1`
  — renders at *correct physical size* on retina (verified at ratio 2.0), just
  not extra-crisp. True crispness needs 2x SVG rasterization in the Go pipeline.
