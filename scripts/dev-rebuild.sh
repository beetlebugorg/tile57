#!/usr/bin/env bash
# One-shot "after a git pull" refresh. Regenerates the styles (they're generated,
# not version-controlled, so `git pull` never updates them) and rebuilds our host
# targets: the headless `chartshot-zig` and, when the build dir has GLFW enabled,
# the interactive window `chart-glfw-zig`. Both render the same in-process Zig
# tile pipeline. (MapLibre's own `mbgl-glfw` is unrelated to our code.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pick whichever build dir exists, preferring the GLFW/desktop dirs (a superset:
# they build both the headless host and the interactive window).
BUILD=""
for d in build-macos-desktop build-desktop build-macos build; do
  [[ -d "$ROOT/$d" ]] && BUILD="$d" && break
done

# Reference data (tiles + assets) is gitignored and regenerated per machine. If
# it's missing, generate it from the Go binary; otherwise just refresh styles.
if [[ ! -f "$ROOT/reference/assets/colortables.json" ]]; then
  echo "==> reference data missing — generating tiles + assets (needs ../chartplotter-go)" >&2
  "$ROOT/scripts/gen-reference.sh"
else
  echo "==> regenerating styles" >&2
  "$ROOT/scripts/gen-style.sh"
fi

if [[ -n "$BUILD" ]]; then
  echo "==> reconfiguring (picks up CMake/new-file changes)" >&2
  cmake -S "$ROOT" -B "$ROOT/$BUILD" >/dev/null
  echo "==> building chartshot-zig in $BUILD" >&2
  ninja -C "$ROOT/$BUILD" chartshot-zig
  # The interactive window only exists when this build dir has GLFW enabled.
  WIN=""
  if grep -q 'chart-glfw-zig' "$ROOT/$BUILD/build.ninja" 2>/dev/null; then
    echo "==> building chart-glfw-zig (interactive window) in $BUILD" >&2
    ninja -C "$ROOT/$BUILD" chart-glfw-zig
    WIN="$BUILD/chart-glfw-zig"
  fi
  echo "done."
  echo "  headless PNG:  $BUILD/chartshot-zig reference/tiles/annapolis.pmtiles style/chart-zig-day.json 38.978 -76.487 14 out.png"
  if [[ -n "$WIN" ]]; then
    echo "  interactive:   $WIN reference/tiles/annapolis.pmtiles style/chart-zig-day.json"
    echo "                 (drag to pan, scroll to zoom; pass a .000 cell for live generation)"
  else
    echo "  (no interactive window in this build dir — use a desktop preset:"
    echo "   cmake --preset macos-desktop   # or: desktop   on Linux)"
  fi
else
  echo "no build dir found; run 'cmake --preset <headless|desktop|macos|macos-desktop>' first" >&2
fi
