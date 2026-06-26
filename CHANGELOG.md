# Changelog

All notable changes to chartplotter-native. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0 and the
C ABI is not yet frozen.

## [Unreleased]

### Added — offline baker + portrayal/style refinements
- **`chartplotter-bake` CLI** (`engine/tools/bake.zig`): pre-bake a cell to a
  PMTiles archive — `chartplotter-bake bake <cell.000> -o out.pmtiles
  [--minzoom N --maxzoom N] [updates…]` — over the cell's bounds, plus `inspect`,
  `cell`, and `version`. The precache path that mirrors chartplotter-go's `bake`.
  (Bakes with the `classify()` fallback styling for now; full S-101 portrayal in
  the baker needs the embedded Lua linked into the exe — tracked as follow-up.)
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
  `a9c8afd`) are computed + supplied to dangers; the under/awash danger rules
  still error pending mariner-settings binding work (a deeper portrayal gap).

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
