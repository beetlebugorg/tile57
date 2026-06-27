# Changelog

All notable changes to chartplotter-native. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0 and the
C ABI is not yet frozen.

## [Unreleased]

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
  geometry is assembled once (`buildGeoCache`) and reused. CLI `chartplotter-bake
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
- **`chartplotter-bake` CLI** (`engine/tools/bake.zig`): pre-bake a cell to a
  PMTiles archive — `chartplotter-bake bake <cell.000> -o out.pmtiles
  [--rules DIR] [--minzoom N --maxzoom N] [updates…]` — over the cell's bounds,
  plus `inspect`, `cell`, and `version`. The precache path that mirrors
  chartplotter-go's `bake`.
- **Full S-101 portrayal in the baker.** `chartplotter-bake` now runs the same
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
  (attr 133) into `*_scamin` MVT buckets, and `build_style.py` gives those layers
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
