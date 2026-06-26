#!/usr/bin/env bash
# One-shot "after a git pull" refresh. Regenerates the styles (they're generated,
# not version-controlled, so `git pull` never updates them) and rebuilds our
# host target. NOTE: `mbgl-glfw` is MapLibre's own binary and does NOT depend on
# our code — pulling our changes never recompiles it; only a MapLibre submodule
# bump does. Our code lives in `chartshot-zig` and the styles.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pick whichever build dir exists.
BUILD=""
for d in build build-macos build-desktop build-macos-desktop; do
  [[ -d "$ROOT/$d" ]] && BUILD="$d" && break
done

echo "==> regenerating styles" >&2
"$ROOT/scripts/gen-style.sh"

if [[ -n "$BUILD" ]]; then
  echo "==> reconfiguring (picks up CMake/new-file changes)" >&2
  cmake -S "$ROOT" -B "$ROOT/$BUILD" >/dev/null
  echo "==> building chartshot-zig in $BUILD" >&2
  ninja -C "$ROOT/$BUILD" chartshot-zig
  echo "done. (For the interactive window, mbgl-glfw reads the style at runtime —"
  echo " just re-run it; no rebuild needed for style changes.)"
else
  echo "no build dir found; run 'cmake --preset <headless|desktop|macos|macos-desktop>' first" >&2
fi
