#!/usr/bin/env bash
# Build the Qt6 MapLibre chart viewer (chartplotter-qt).
#
# One-time heavy build of QMapLibre — the Qt6 MapLibre widget from
# vendor/maplibre-native-qt — plus the viewer in app/qt. Outputs:
#   build/qmaplibre        QMapLibre install (find_package prefix)
#   build/qt/chartplotter-qt   the viewer binary
#
# Re-run after updating the maplibre-native-qt submodule. Needs cmake + ninja +
# Qt6 (qmake6). Set QT_ROOT_DIR if Qt6 isn't under /usr.
#
# Then view a baked chart bundle (needs a display):
#   tile57 bundle <cell.000> -o out
#   build/qt/chartplotter-qt out/assets/style-day.json 38.97 -76.49 13
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/maplibre-native-qt"

# Locate Qt6: $QT_ROOT_DIR wins; else qmake6, else Homebrew's qt prefix, else /usr.
if [ -z "${QT_ROOT_DIR:-}" ]; then
  if command -v qmake6 >/dev/null 2>&1; then
    QT_ROOT_DIR="$(qmake6 -query QT_INSTALL_PREFIX 2>/dev/null || true)"
  fi
  if [ -z "${QT_ROOT_DIR:-}" ] && [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    QT_ROOT_DIR="$(brew --prefix qt 2>/dev/null || brew --prefix qt6 2>/dev/null || true)"
  fi
  QT_ROOT_DIR="${QT_ROOT_DIR:-/usr}"
fi
export QT_ROOT_DIR
TOOLCHAIN="$QT_ROOT_DIR/lib/cmake/Qt6/qt.toolchain.cmake"
PREFIX="$ROOT/build/qmaplibre"

if [ ! -f "$TOOLCHAIN" ]; then
  echo "Qt6 toolchain not found at: $TOOLCHAIN" >&2
  echo "Point QT_ROOT_DIR at your Qt6 prefix and re-run, e.g.:" >&2
  echo "  macOS (Homebrew):    brew install qt   # then:" >&2
  echo "                       QT_ROOT_DIR=\"\$(brew --prefix qt)\" $0" >&2
  echo "  Qt online installer: QT_ROOT_DIR=~/Qt/6.7.0/macos $0" >&2
  echo "  Linux:               install qt6-base (QT_ROOT_DIR=/usr)" >&2
  exit 1
fi

# Recursively init maplibre-native-qt + its own maplibre-native (heavy, one-time).
# Run from the repo root so the parent resets maplibre-native-qt to its pinned
# commit and then recurses — more robust than poking the nested submodule directly.
echo "==> fetching maplibre-native-qt + its maplibre-native submodule (heavy, one-time)" >&2
git -C "$ROOT" submodule update --init --recursive vendor/maplibre-native-qt

# Renderer MUST match Qt's RHI backend: Metal on macOS (Qt RHI hands the widget a
# Metal command buffer — an OpenGL mbgl crashes in createUniformBuffer), OpenGL on
# Linux. Switching renderer needs a clean build dir, so wipe it when it changes.
if [ "$(uname -s)" = "Darwin" ]; then
  RENDERER=(-DMLN_WITH_METAL=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0)
  RTAG=metal
else
  RENDERER=(-DMLN_WITH_OPENGL=ON)
  RTAG=opengl
fi
BUILDDIR="$ROOT/build/qmaplibre-build"
if [ -f "$BUILDDIR/.renderer" ] && [ "$(cat "$BUILDDIR/.renderer")" != "$RTAG" ]; then
  echo "==> renderer changed -> clean rebuild" >&2
  rm -rf "$BUILDDIR" "$PREFIX"
fi

# Build + install QMapLibre. Only the Widgets component is needed (no Location /
# Quick — those want Qt6Location/Qt6Quick). MLN_WITH_WERROR=OFF: maplibre-native's
# -Werror trips on warnings from very recent GCC/Clang.
echo "==> building + installing QMapLibre (Widgets, $RTAG) -> $PREFIX" >&2
cmake -S "$SRC" -B "$BUILDDIR" -GNinja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.19 \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DQT_VERSION_MAJOR=6 \
  "${RENDERER[@]}" \
  -DMLN_QT_WITH_INTERNAL_ICU=ON \
  -DMLN_QT_WITH_WIDGETS=ON \
  -DMLN_QT_WITH_LOCATION=OFF \
  -DMLN_QT_WITH_QUICK_PLUGIN=OFF \
  -DMLN_WITH_WERROR=OFF
echo "$RTAG" > "$BUILDDIR/.renderer"
cmake --build "$BUILDDIR"
cmake --install "$BUILDDIR"

# Build the viewer against the freshly-installed QMapLibre.
echo "==> building chartplotter-qt -> build/qt" >&2
cmake -S "$ROOT/app/qt" -B "$ROOT/build/qt" -GNinja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_PREFIX_PATH="$PREFIX"
cmake --build "$ROOT/build/qt"

echo >&2
echo "done -> $ROOT/build/qt/chartplotter-qt" >&2
echo "  view a bundle (needs a display):" >&2
echo "  build/qt/chartplotter-qt <bundle>/assets/style-day.json [lat lon zoom]" >&2
