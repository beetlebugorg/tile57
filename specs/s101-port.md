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

## Status

- Lua 5.4 embedded + self-test passing.
- S-101 framework **loads** in 5.4 (`--s101check`).
- S-101 framework **executes** in 5.4 with stub Host callbacks + empty features
  (`--s101run` -> FeaturePortrayalItems=0). Runtime is 5.4-compatible.
- classify() placeholder in s57_mvt.zig covers DEPARE/LNDARE/COALNE/DEPCNT/etc.
  with live depth shading.

**Next (no remaining unknowns):** step 3 — implement the real Host* callbacks
(C stubs in lua_shim.c -> back them with the Zig s57.Cell via small extern
accessors) + step 4 (FeatureCatalogue.xml for type codes) + step 5 (instruction
-> MVT), then dispatch each cell feature through its rule.
