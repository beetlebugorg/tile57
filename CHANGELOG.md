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

### Changed — public identity & C API (breaking, pre-1.0)
- Library renamed `libtilegen.a` → **`libchartplotter.a`**; public header
  `include/tilegen.h` → **`include/chartplotter.h`**; C ABI prefix `tg_` → `chartplotter_`.
  The Zig tile-generator sources moved from `tilegen/` to **`engine/`** (Zig
  module also renamed `tilegen` → `engine`).
- Redesigned the C ABI for coherence (see `docs/API.md`):
  - one opener `chartplotter_source_open(data, len, chartplotter_format, rules_dir)` with a
    `CHARTPLOTTER_FORMAT_AUTO` sniff, replacing the two openers + the try/fallback both
    hosts duplicated; `chartplotter_source_format()` reports the resolved backend.
  - S-101 rules dir is now an argument (env `CHARTPLOTTER_S101_RULES`, renamed
    from `TG_S101_RULES`, is only a fallback when it is NULL).
  - `chartplotter_source_zoom_range()` folds the two zoom getters into one call;
    `chartplotter_tile_get` returns a named `chartplotter_tile_status`.
  - added `chartplotter_source_clear_cache()`, `chartplotter_version()` + `CHARTPLOTTER_VERSION_*`.
  - documented lifetime (must outlive the renderer) + threading (not internally
    synchronized) contracts in the header.
  - moved the Lua/S-101 self-tests to `include/chartplotter_diag.h` (`chartplotter_diag_*`).
- App binaries renamed: `chart-glfw-zig` → **`chartplotter`** (interactive
  window), `chartshot-zig` → **`chartplotter-render`** (headless PNG host).
- C++ FileSource adapter renamed `ZigTileSource` → **`ChartTileSource`**
  (`app/zig_tile_source.*` → `app/chart_tile_source.*`).

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
- **ENC_ROOT support**: point a host at a directory to load every base cell plus
  its sequential `.001…` update files, overlaid. New
  `chartplotter_source_open_cells` C API + a `cells` backend
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
