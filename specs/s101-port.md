# S-101 portrayal engine — port plan

The S-101 portrayal (the successor to S-52) is an **executable specification**:
216 Lua rule files (~15.3K LOC) under the IHO Portrayal Catalogue. The decision
(see [[chartplotter-native-port]]) is to **embed Lua and run the rules**, not
re-port them. Lua 5.4 is embedded in `libtilegen.a` (proven working).

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
   (`chartshot-zig --s101check <rules-dir>`). The 5.4 decision holds; no LuaJIT
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

Set `TG_S101_RULES=<rules dir>` (default vendored at tilegen/vendor/s101/Rules)
to enable; otherwise the crude classify() fallback is used.

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
