# Changelog

All notable changes to chartplotter-native. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0 and the
C ABI is not yet frozen.

## [Unreleased]

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
- M3 interactive pan/zoom window (`chartplotter`) serving live Zig tiles.
- Live S-57 → MVT portrayal now emits soundings (SNDFRM04 glyphs), area fill
  patterns, and feature names (synthesized from OBJNAM).
- In-process tile cache in the generator (memoizes generated/decoded tiles).
- Project docs: `docs/API.md` (C ABI reference), this changelog; `docs/BUILD.md`
  now documents the project's own binaries and runtime knobs.
- MIT `LICENSE`.
