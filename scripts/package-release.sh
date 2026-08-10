#!/usr/bin/env bash
# Stage a built tree into the release archive for one target, and — when a
# Debian architecture is given — the matching .deb. Run it after
# `zig build -Dtarget=<target> -Doptimize=ReleaseFast`; everything lands in
# dist/. Invoked per target by .github/workflows/release.yml.
#
# Usage: package-release.sh <version> <target> [deb-arch]
set -euo pipefail

version="$1"
target="$2"
deb_arch="${3:-}"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/dist"
name="tile57-$version-$target"
stage="$out/$name"

exe=tile57
case "$target" in *windows*) exe=tile57.exe ;; esac

rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/lib" "$stage/include"
cp "$root/zig-out/bin/$exe" "$stage/bin/"
cp "$root"/zig-out/lib/* "$stage/lib/"
cp "$root/include/tile57.h" "$stage/include/"
cp "$root/LICENSE" "$root/THIRD_PARTY_LICENSES.md" "$root/README.md" "$stage/"

cd "$out"
case "$target" in
  *windows*) rm -f "$name.zip" && zip -qr "$name.zip" "$name" ;;
  *) tar czf "$name.tar.gz" "$name" ;;
esac

# The same payload under /usr, for `apt install ./tile57_*.deb`. There is no
# apt repository — the .deb is a release asset.
if [ -n "$deb_arch" ]; then
  pkg="$out/deb"
  rm -rf "$pkg"
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib" "$pkg/usr/include" \
           "$pkg/usr/share/doc/tile57"
  install -m755 "$stage/bin/tile57" "$pkg/usr/bin/"
  install -m644 "$stage/lib/libtile57.a" "$pkg/usr/lib/"
  install -m644 "$stage/include/tile57.h" "$pkg/usr/include/"
  install -m644 "$root/LICENSE" "$pkg/usr/share/doc/tile57/copyright"
  cat > "$pkg/DEBIAN/control" <<EOF
Package: tile57
Version: $version
Architecture: $deb_arch
Maintainer: Jeremy Collins <jeremy.collins@beetlebug.org>
Section: science
Priority: optional
Homepage: https://github.com/beetlebugorg/tile57
Description: Nautical chart engine for IHO S-101 and S-57 charts
 tile57 reads IHO S-101 and S-57 electronic navigational charts and renders
 them with the official IHO S-101 Portrayal Catalogue: vector tiles with a
 matching MapLibre S-52 style, a draw-ready GPU scene, PNG, and PDF. It also
 reads raster charts (MBTiles, BSB/KAP) and draws the official chart over
 them. Ships the tile57 CLI plus libtile57.a and its C header.
 .
 Not for navigation.
EOF
  dpkg-deb --build --root-owner-group "$pkg" "$out/tile57_${version}_${deb_arch}.deb"
  rm -rf "$pkg"
fi

rm -rf "$stage"
ls -l "$out"
