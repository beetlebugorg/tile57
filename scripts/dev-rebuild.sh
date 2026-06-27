#!/usr/bin/env bash
# One-shot "after a git pull" refresh. Regenerates the styles (they're generated,
# not version-controlled, so `git pull` never updates them) and rebuilds the
# headless render host `chartplotter-render`.
#
# The interactive window is now a separate Qt6 app, `chartplotter-qt` — build it
# with scripts/build-qmaplibre.sh (not part of the main CMake build).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pick whichever render build dir exists (headless / macOS).
BUILD=""
for d in build-macos build; do
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
  echo "==> building chartplotter-render in $BUILD" >&2
  ninja -C "$ROOT/$BUILD" chartplotter-render
  echo "done."
  echo "  headless PNG:  $BUILD/chartplotter-render reference/tiles/annapolis.pmtiles style/chart-zig-day.json 38.978 -76.487 14 out.png"
  echo "  interactive:   the Qt window is chartplotter-qt — build it once with scripts/build-qmaplibre.sh,"
  echo "                 then: build/qt/chartplotter-qt <bundle>/assets/style-day.json [lat lon zoom]"
else
  echo "no build dir found; run 'cmake --preset headless' (or 'macos') first" >&2
fi
