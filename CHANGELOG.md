# Changelog

All notable changes to chartplotter-native. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0 and the
C ABI is not yet frozen.

## [Unreleased]

### Added — S-52 overscale indication (AP(OVERSC01), specs/overscale.md)
- **Baked overscale hatch geometry**: every cell contributing to a tile
  (including band-handoff carried cells) now emits its M_COVR (CATCOV=1)
  data-coverage polygon, clipped per tile, into the `area_patterns` source
  layer as pattern `OVERSC01`, tagged with a new int prop `oscl` = the cell's
  compilation scale quantized UP the scamin ladder (same crossing alignment as
  the `smax` handoff). Area fills carry the same `oscl` tag.
- **The occlusion sandwich** (style builder): the base `areas` fill layer
  splits into `fill-areas#oscl` (fills of overscaled cells) UNDER the new
  `overscale` layer (fill-pattern `pat:OVERSC01`, source-layer
  `area_patterns`) UNDER `fill-areas` (at-scale fills) — a finer cell's opaque
  DEPARE/LNDARE occlude a coarser cell's hatch, so the hatch survives only on
  coarse-only patches, with zero polygon boolean ops. The generic pattern
  layers exclude `OVERSC01`.
- **The oscl gate clause** (client-injected, exact shape pinned by test):
  `[">", ["coalesce",["get","oscl"], 0], DENOM]` on the hatch + under-hatch
  fills, and its `["!", …]` negation on the at-scale fills. DENOM is the SAME
  injected literal as the scamin/smax clauses (filter-gate mode), a
  zoom-derived denominator in bucket/fallback modes, and the 1e12 show-all
  placeholder at boot (hatch hidden, all fills at-scale, until the client
  injects the live denom).
- **`show_overscale` mariner toggle** (default true; S-52 §10.1.10): drives the
  `overscale` layer's `layout.visibility` only, so a toggle is a single
  `setLayoutProperty` style-diff op. C ABI: `tile57_mariner.show_overscale`
  (appended; `tile57_mariner_defaults` sets true); bindings/go:
  `Mariner.ShowOverscale`.
- **Pixel/ascii surfaces**: `resolve.osclVisible` mirrors the style gate, so
  render_view/pdf/ascii draw the hatch consistently (via the normal AP path);
  hidden under `ignore_scamin` and when `show_overscale` is off.
- **Manifest ladder**: emitted `oscl` values join the archive/live `scamin`
  ladder (bundle prop scan + per-cell quantized-cscl fold), so the client's
  discrete crossing machinery fires exactly at every emitted gate value.

### Changed — MLT is the default tile format
- **MLT (MapLibre Tiles) is now the DEFAULT bake/storage tile format**;
  MVT stays available explicitly (`--format mvt`, `tile57_bake_opts.format =
  TILE57_TILE_TYPE_MVT`). There is NO transcode layer anywhere: the wire format
  follows the storage format, and maplibre-gl ≥ 5.12 decodes MLT natively via
  the vector-source `encoding` option.
- **Bake parity gap closed**: the bundle's post-bake collection (sprite-mln
  sounding composites + the SCAMIN manifest feeding the client's ladder) now
  decodes baked tiles with the codec matching the bake format, so an MLT bake
  produces byte-identical sprite-mln output and the same `scamin` metadata as
  an MVT bake of the same input.
- C ABI: `tile57_bake_opts` gained `format` (0 = default = MLT; honored by
  `tile57_bake_pmtiles` AND `tile57_bake_bundle`); `tile57_chart_info` gained
  `tile_type` (the encoding `tile57_chart_tile` returns — the stored type for a
  PMTiles chart, the live generation format for a cell chart); new
  `tile57_chart_set_tile_format` selects the live-generation encoding on a
  cell-backed chart (cell charts still OPEN generating MVT so existing MVT-only
  embedders are unaffected); `tile57_style_template` gained `tile_encoding`
  (emits `"encoding":"mlt"` on the chart source; the hint survives
  `tile57_build_style` / `tile57_style_diff`); the stale "decompressed MVT
  bytes" doc on `tile57_chart_tile` now states tiles serve verbatim in the
  chart's tile encoding. Bundle styles (`style-{day,dusk,night}.json`) carry
  `"encoding":"mlt"` on their `pmtiles://` source for MLT bundles.
- bindings/go: `BakeOpts.Format`, `ChartInfo.TileType` / `Meta.TileType`,
  `Source.SetTileFormat`, `TileFormat` (+ `Encoding()`/`EncodingFormat`), and an
  `encoding TileFormat` parameter on `StyleTemplate`/`Style`.
- `tile57 inspect` now decodes MLT tiles (same layer/feature dump as MVT)
  instead of hex-dumping them.

### Fixed — scamin-aware band handoff (the band-floor blank window)
- **Zooming through a band boundary no longer blanks the chart** while the finer
  band's SCAMIN-gated bulk is still hidden. Each band's floor-zoom tiles now bake
  in the next-coarser band's pass with BOTH bands' cells alive; where a tile's
  display window opens coarser than the covering finer cell's compilation scale,
  the coarser band's features are carried down tagged with a new integer tile
  property **`smax`** (the handoff denominator, quantized up onto the archive's
  real SCAMIN ladder) instead of being best-band suppressed. Styles gate it with
  `["<", ["coalesce",["get","smax"],0], DENOM]` beside the scamin clause (the
  same injected literal in filter-gate mode; a zoom-derived denominator on the
  bucket/fallback paths), so the copy hands off at the exact crossing where the
  finer content activates — no hole, no double-draw. The live cells backend
  applies the same rule per request (`bake_enc.carryGate`, shared).
- **Bundle bakes no longer lose every zoom below the coarsest populated band's
  floor.** The coarsest band with cells now extends down to the archive minzoom
  (mirroring the live path's coarsest-band fallback), so a pack without overview
  cells still gets low-zoom tiles instead of blank basemap.
- Bake callers hold at most **two adjacent bands'** cells at once (the deferred
  band rides into the next pass; portrayal is reused, never recomputed).
  `Baker.bakeBand`/`plannedTiles` grew an own/carry split (`own_len`) and a
  `FloorMode` (`defer_down`/`extend_min`).

### Changed — chart-centric C ABI (breaking, pre-1.0)
- **The tile-source C ABI (`include/tile57.h`) was reworked into a chart-centric
  surface** (see `chart-api.md`); the internal Zig type `Source` in `src/source.zig`
  is likewise renamed **`Chart`** in `src/chart.zig`, so the engine and the ABI use
  the same word. The opaque handle is `tile57_chart` and the open/serve entry points
  are prefixed `tile57_chart_*`.
  - **Open** splits the old single `tile57_source_open(data, len, format, rules_dir)`
    (and its `TILE57_FORMAT_*` enum) into three explicit functions:
    `tile57_chart_open(path)` (an on-disk ENC_ROOT directory or a single `.000`,
    streamed on demand), `tile57_chart_open_bytes(base, len)` (one in-memory S-57
    cell), and `tile57_chart_open_pmtiles(path)` (a baked PMTiles bundle). The
    many-cells / streaming C openers (`tile57_source_open_cells{,_streaming}`) and
    the resolved-format getter `tile57_source_format` are gone.
  - **Metadata** — the four `tile57_source_{zoom_range,bands,bounds,anchor}` getters
    fold into one `tile57_chart_get_info(chart, &info)` filling a `tile57_chart_info`
    struct; a new `tile57_chart_scamin` returns the live SCAMIN manifest.
  - **Tiles / lifetime** — `tile57_tile_get` → `tile57_chart_tile`,
    `tile57_source_clear_cache` → `tile57_chart_clear_cache`, `tile57_source_close`
    → `tile57_chart_close`. The per-kind frees collapse into one universal
    `tile57_free(ptr, len)` (replacing `tile57_tile_free`).
- **Bake surface.** `tile57_bake_cells` → `tile57_bake_pmtiles`, now taking a
  `tile57_cell` array (renamed from `tile57_cell_input`) plus a `tile57_bake_opts`
  options struct (rules/catalog dir, zoom clamp, pick attrs, progress); the
  `tile57_bake_progress` callback gains band index/count/name. New
  `tile57_bake_bundle(input, out_dir, opts, …)` writes the full on-disk bundle the
  `tile57 bake … -o out/` CLI emits.
- **Portrayal assets folded.** The four generators (`tile57_colortables`,
  `tile57_linestyles`, `tile57_sprite_atlas`, `tile57_pattern_atlas`) and the
  `tile57_named_bytes` blob type are replaced by one `tile57_bake_assets(catalog_dir,
  &assets)` filling a `tile57_assets` struct (colortables + linestyles + sprite +
  pattern buffers), freed with `tile57_assets_free`. `tile57_colortables_default` /
  `tile57_style_template` still build a style with no on-disk catalogue, and
  `tile57_build_style` / `tile57_style_diff` take the SCAMIN manifest.

### Changed — repository split into the tile57 engine + the Qt demo
- **chartplotter-native is now the standalone tile57 engine.** The Zig engine
  moved from `engine/` to the repository root, so a top-level **`zig build`**
  produces `zig-out/bin/tile57` (CLI) + `zig-out/lib/libtile57.a` (C ABI). A plain
  `zig build` now defaults to **ReleaseFast** (a Debug bake is ~2.6x slower);
  use `-Doptimize=Debug` for development.
- **Removed the C++ render layer.** The headless renderer (`chartplotter-render` /
  `libchartplotter`), its mbgl `FileSource` adapter, the vendored
  `maplibre-native` submodule, `include/chartplotter.h`, the root CMake build, and
  the PNG-render helper scripts are gone. The repo is now pure Zig
  tile/style/asset generation behind the C ABI (`include/tile57.h` +
  `tile57_diag.h`).
- **The Qt6 viewer moved to a standalone repo, `tile57-demo`**, which consumes the
  tile57 engine as a git submodule (built via `zig build`) and QMapLibre.

### Changed — interactive window is now Qt6 (QMapLibre)
- **Replaced the GLFW / macOS-Metal MapLibre Native window with a Qt6 viewer**,
  `chartplotter-qt` (`app/qt`), built on the QMapLibre widget (maplibre-native-qt,
  vendored as a submodule + built by `scripts/build-qmaplibre.sh`). It loads a baked
  chart bundle's `style.json` (PMTiles + portrayal assets) into a
  `QMapLibre::MapWidget` — no mbgl internals, no custom FileSource.
- **Removed** the GLFW + Metal/native-host window code (`app/chartplotter_main.cpp`,
  `chart_native_host`, `metal_backend`, `chart_renderer_frontend`), the
  `MLN_WITH_GLFW` CMake path + the `chartplotter` exe, the desktop/macos-desktop
  presets, and the `chartplotter_view_*` C API. `libchartplotter` is now the headless
  renderer (`chartplotter_render_png` + `chartplotter-render`); ChartTileSource /
  enc_root and the offline baker are unchanged.

### Changed — engine reshaped into foundational packages
- **`iso8211`, `s57`, `s100` are now standalone Zig packages** (`engine/src/{iso8211,
  s57,s100}/`), mirroring the Go oracle's `pkg/iso8211`, `pkg/s57`, `pkg/s100` one
  for one. They are pure (no libc/Lua) and target-agnostic, so the same modules
  compile into both the unit tests (glibc) and the static-musl baker. Pure refactor
  — behavior identical; the C ABI (`tile57_*`) is unchanged.

### Added — offline chart-bundle baker
- **`tile57 bundle <cell> -o <dir>`** emits a self-contained,
  relocatable **chart bundle**: `tiles/chart.pmtiles` + `assets/colortables.json` +
  `assets/style-{day,dusk,night}.json` + `manifest.json`. The tiles carry S-52 colour
  *tokens* (palette-independent); the assets carry the RGB and the style layers. Both
  halves come from the same S-101 catalogue and are stamped with a `schema_version`
  (`tile57/1`) so a renderer can refuse a mismatched bundle.
- **New `assets` module** (mirrors the Go oracle's `internal/engine/assets.EmitS101`)
  and **`tile57 assets <catalog-dir> -o <dir>`** emit the portrayal
  assets independent of a cell. First artifact: `colortables.json` (token → hex per
  day/dusk/night palette, parsed from `ColorProfiles/colorProfile.xml`) — **byte-
  identical to the Go oracle's output**.
- **MapLibre `style.json` generation** (`assets/style.zig`, a port of
  ported from the web `s52-style.mjs`/`chart-style.mjs`): `tile57 style`
  emits one style per palette, and `bundle` writes the three styles + references them
  in `manifest.portrayal.styles`, so a bundle is **directly renderable**.

### Removed
- **The legacy Python style generator `style/build_style.py`** (and the
  transitional `scripts/check-style-parity.sh`). `engine/src/assets/style.zig` is
  now the sole style generator — verified full-file identical to `build_style.py`
  (27 layers × 3 palettes) before removal — and `scripts/gen-style.sh` drives
  `tile57 style`. Line styles, sprite/pattern atlases (SVG raster), and
  glyphs (SDF) — to light up the symbol/text layers — are next.

### Added — on-demand ENC_ROOT + offline baker
- **Lazy on-demand tile generation (the new default for an ENC_ROOT).** Pointing a
  host at an ENC_ROOT used to parse + portray *every* cell at open and hold them all
  (≈34 GB for the ~7400-cell NOAA catalogue — a blue, never-finishing window). Now
  `tile57_source_open_cells` builds a cheap spatial index (per cell: compilation-
  scale band + bbox, via `s57.peekMeta`, in parallel) and parses + portrays only
  the cells a *requested tile* needs, choosing the best-available scale band per
  tile and keeping recent cells in an LRU. The full catalogue opens in seconds and
  renders a view by touching ~a dozen cells (≈5 GB transient at open, far less
  steady-state). Coverage gaps at a zoom are filled by overzooming the coarsest
  band present, so tiles aren't blank.
- **No band-boundary tile gaps + scale-clamped navigation.** A tile now overlays
  *all* overlapping cells whose band range includes the zoom (coarse→fine, finer on
  top), so a finer cell that covers only part of a tile no longer blanks the coarser
  fill (the earlier best-band single-pick left holes); a zoom in a coverage gap
  overzooms the coarsest band. The window clamps navigation to the chart scale range
  ~1:10,000,000 .. 1:4,000 (z≈5.8..17.1) and the vector source minzoom drops to 5
  (`gen-style.sh`) so overview scales actually draw. LRU budget raised to 256 cells
  for wide views.
- **Initial-view framing.** When no explicit camera is given, the host fits the
  data bounds if that lands at a usable zoom (a single cell / a region); for a
  continental ENC_ROOT — whose bounds would fit at ~z2, below the style's source
  minzoom, i.e. blank — it instead opens on a representative harbour cell near the
  data median (`tile57_source_anchor`), robust to scattered IHO test cells. Fixes
  "the window comes up but I see nothing." `chartplotter-render` with zoom `0`
  exercises the same path.
- **Offline streaming banded baker** (`engine/src/bake_enc.zig`): for precomputing
  a shareable PMTiles archive. Groups cells into navigational bands by CSCL (Band,
  matching the Go reference), bakes finest → coarsest with best-band dedup, holding
  one band at a time. Portrayal + per-tile MVT generation run across all cores
  (`parallelFor`; thread-local Lua context, warmed catalogue, quiet flag); per-cell
  geometry is assembled once (`buildGeoCache`) and reused. CLI `tile57
  bake-root <ENC_ROOT> -o out.pmtiles`; C ABI `tile57_bake_cells`. The app can use
  it on open via `CHARTPLOTTER_BAKE=1` (cached under `$XDG_CACHE_HOME/chartplotter`,
  `CHARTPLOTTER_BAKE_MIN/MAXZOOM` to set the range) for smooth-everywhere offline
  use; the default is lazy.

### Added — offline baker + portrayal/style refinements
- **Spatial / geometry Host binding**: `HostGetSpatial` now serves real point
  geometry (`#P` points, `#M` multipoints, `#S` surfaces) to the S-101 rules via
  `_HostFeaturePoints` (backed by per-feature point geometry). A `#P` point must be
  a real Point or the framework's `GetSpatial` recurses forever — this was the
  Obstruction/Wreck "C stack overflow". With it + derived depths + the
  orientation/clearance complex attrs below, the test cells (US4MD81M, US5MD1MC)
  now portray with **zero rule errors**.
- **Orientation + clearance complex attributes** synthesized from S-57 simple
  attrs (ORIENT, VERCCL/VERCLR/VERCOP, HORCLR) so NavigationLine / RecommendedTrack
  / SpanOpening read `feature.<complex>.<value>` instead of crashing on a nil
  complex (Go sync: the `clearances` map + orientation alias).
- **`tile57` CLI** (`engine/tools/bake.zig`): pre-bake a cell to a
  PMTiles archive — `tile57 bake <cell.000> -o out.pmtiles
  [--rules DIR] [--minzoom N --maxzoom N] [updates…]` — over the cell's bounds,
  plus `inspect`, `cell`, and `version`. The precache path that mirrors
  chartplotter-go's `bake`.
- **Full S-101 portrayal in the baker.** `tile57` now runs the same
  embedded-Lua S-101 rule engine as the live library (not the `classify()`
  fallback), so baked tiles carry the full S-101 layer set
  (areas/area_patterns/lines/point_symbols/soundings/text + `*_scamin` declutter
  buckets). The baker's engine module (`src/bake_root.zig`) adds `portray.zig` +
  the C/Lua sources on top of the pure `root.zig`; the unit-test build stays pure
  Zig. On a glibc Linux host the baker links against Zig's own static musl (the
  self-hosted ELF linker rejects a modern glibc `crt1.o`'s `.sframe`
  relocations). Portrayal failure (e.g. rules dir not found) falls back to
  `classify()` as before. Default rules dir resolves like the C++ host
  (`--rules`, else `TILE57_S101_RULES`, else the vendored catalogue).
- **Honest portrayal diagnostics.** A feature whose S-101 class has no rule file
  (e.g. SweptArea/SWPARE — an IHO catalogue gap) is now counted as *unportrayed*
  rather than an *error*, matching the Go reference's silent suppression; the
  per-error log prints the primitive's name (`Point`/`Curve`/`Surface`) instead
  of a useless `table: 0x…` address. (Shared `csrc/lua_shim.c` driver, so the
  live path benefits too.)
- **Native S-52 fallback for SweptArea (SWPARE).** The S-101 catalogue ships no
  SweptArea rule (an IHO gap), so the Lua engine emits nothing for it. The MVT
  layer now draws the Go reference's `sweptAreaBuild` fallback directly: a dashed
  `CHGRD` boundary on each ring, the `SWPARE51` swept-depth bracket at the area's
  representative point, and a `swept to <DRVAL1>` label. (`engine/src/s57_mvt.zig`,
  shared by the baker and the live path.)
- **Native S-52 fallback for NEWOBJ.** NEWOBJ-derived features (e.g.
  VirtualAISAidToNavigation) whose S-101 rule doesn't portray the encoded geometry
  — wrong primitive, unofficial stub — now draw the Go reference's `newObjectBuild`
  placeholder, a dashed `CHMGF` (magenta) outline on the line/area geometry, rather
  than being dropped. A genuine rule error on any *other* class is still suppressed
  (no output), matching the Go reference. (`engine/src/s57_mvt.zig`.)
- **SCAMIN decluttering**: the live path now routes features carrying SCAMIN
  (attr 133) into `*_scamin` MVT buckets, and the generated style gives those layers
  a per-feature `minzoom` derived from the SCAMIN 1:N denominator, so minor
  features drop out below their scale (replacing the M1 "both shown" stub).
- **S-52 draw priority**: `draw_prio` (from the S-101 instruction stream) is now
  emitted on features and used as the area fill-sort-key (Go sync `3ca4d5f`).
- **Drying-line contour**: 0 m `VALDCO` is emitted on DEPCNT lines + a
  line-centre contour-label style layer (Go sync `f86b750`).
- **M_QUAL data quality**: `zoneOfConfidence` is synthesized from CATZOC (via a
  generalized complex-attribute binding) so `QualityOfBathymetricData` portrays
  (Go sync `49e9cd9`).
- QUAPOS quality-of-position is parsed + aggregated per feature (Go sync
  `1b04ebb`); the approximate-position dashed-line *application* is still to come.
- Derived depth attrs (`defaultClearanceDepth`/`surroundingDepth`, Go sync
  `a9c8afd`) are computed + supplied to under/awash dangers; combined with the
  spatial binding above this clears the danger-rule crashes. Blank S-57 attributes
  are now treated as absent (they were served as `""`, building a malformed
  `ScaledDecimal{Value=nil}` that crashed the depth comparison).

### Fixed
- **Guaranteed attribute bindings no longer clobber the catalogue's multiplicity.**
  `inTheWater`/`orientationValue`/`topmark` were bound unconditionally (Upper=1)
  *after* the catalogue bindings, overwriting a feature type's real multiplicity —
  e.g. RadioCallingInPoint's array-valued `orientationValue` (Upper=2), so the rule
  crashed indexing `feature.orientationValue[1]`. Now added only when the catalogue
  doesn't already bind them (matches Go's `withGuaranteed`). Clears the
  RadioCallingInPoint errors on real NOAA cells; the directional RDOCAL symbols and
  labels now portray. (`engine/csrc/lua_shim.c`.)

### Changed — two-library architecture + C APIs (breaking, pre-1.0)
- The project is now two C libraries with distinct roles:
  - **`libtile57`** — the Zig S-57 tile generator (was `libtilegen.a` / `tg_*`).
    Prefix `tile57_*`, headers `include/tile57.h` + `include/tile57_diag.h`. The
    sources live under `engine/` (Zig module `engine`). Env var
    `TILE57_S101_RULES`.
  - **`libchartplotter`** — the embeddable chart **widget** that opens a window
    and renders (it wraps MapLibre Native + libtile57). Prefix `chartplotter_*`,
    header `include/chartplotter.h`. (`libchartplotter` previously named the tile
    generator; that role is now `libtile57`.)
- Redesigned the tile-source C ABI: one opener
  `tile57_source_open(data, len, format, rules_dir)` with a `TILE57_FORMAT_AUTO`
  sniff (replacing two openers + the duplicated try/fallback) plus
  `tile57_source_open_cells` for an ENC_ROOT; `tile57_source_format/zoom_range/
  bounds/clear_cache`, a named `tile57_tile_status`, `tile57_version`, and the
  S-101 rules dir as an argument (env `TILE57_S101_RULES` is only a NULL
  fallback). Lifetime + threading contracts documented in the header.
- App binaries: `chart-glfw-zig` → **`chartplotter`** (window), `chartshot-zig`
  → **`chartplotter-render`** (headless PNG); both are now thin mains over
  `libchartplotter`. C++ FileSource adapter `ZigTileSource` → **`ChartTileSource`**.

### Removed
- The dead `CHART_ASYNC` worker path in the tile-source adapter (an artifact of
  the flicker investigation; the flicker is fixed at its source, so the worker
  was unused and made the threading contract ambiguous).
- Dead `#import <QuartzCore/QuartzCore.h>` in `app/metal_backend.mm` (left over
  from the reverted `CATransaction`/`presentsWithTransaction` attempts).

### Fixed
- **macOS interactive flicker** (the headline fix): `ChartTileSource` now issues
  conditional tile requests (stable `etag` + `notModified`), so MapLibre reuses
  its already-parsed tiles instead of re-parsing + re-uploading them 15-60×/sec.
- Low idle CPU in the interactive window via on-demand rendering (default;
  `CHART_CONTINUOUS=1` opts back into present-every-frame).
- macOS Metal `nextDrawable` nil-guard + `setAllowsNextDrawableTimeout(false)`
  to stop whole-screen blanks on fast pan; async present matching MapLibre's
  macOS SDK.
- macOS link warning: the Zig archive is now built for the same deployment
  target as the C++ host (`CMAKE_OSX_DEPLOYMENT_TARGET`, default 14.3).

### Added
- **`libchartplotter` chart-widget library**: `chartplotter_view_open/run/close`
  (open an interactive window) + `chartplotter_render_png` (headless) + the
  `chartplotter_view_options` (size/title/style/rules/camera). The MapLibre glue
  the two hosts used to duplicate now lives once in the library.
- **ENC_ROOT support**: point a host at a directory to load every base cell plus
  its sequential `.001…` update files, overlaid. New
  `tile57_source_open_cells` C API + a `cells` backend
  (`s57_mvt.generateTileMulti`); the host walks the directory (`app/enc_root.hpp`).
- **S-57 update application** (`parseCellWithUpdates`): record-level merge by FOID
  / (RCNM,RCID) with RUIN insert/delete/modify and the SGCC/FSPC control fields.
- M3 interactive pan/zoom window (`chartplotter`) serving live Zig tiles.
- Live S-57 → MVT portrayal now emits soundings (SNDFRM04 glyphs), area fill
  patterns, and feature names (synthesized from OBJNAM).
- Area labels placed at the true centroid when inside (Go sync `30db686`).
- In-process tile cache in the generator (memoizes generated/decoded tiles).
- A **Docusaurus documentation site** under `docs/` (Introduction, Installation,
  Getting Started, C API, Architecture, Tile Schema, Known Limitations),
  deployed to GitHub Pages; this changelog; `specs/go-sync.md` Go-port plan.
- MIT `LICENSE`.
