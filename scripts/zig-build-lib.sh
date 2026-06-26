#!/usr/bin/env bash
# Build libtilegen.a via `zig build`. On macOS, re-pack the archive with Apple's
# libtool: Zig's archive members aren't 8-byte aligned and Apple's ld64 rejects
# them ("64-bit mach-o member ... not 8-byte aligned"). Zig self-caches, so this
# is cheap to run unconditionally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"
OPT="${1:-ReleaseFast}"

cd "$ROOT/tilegen"
"$ZIG" build "-Doptimize=$OPT"

LIB="$ROOT/tilegen/zig-out/lib/libtilegen.a"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "==> re-packing $LIB with libtool (macOS ld alignment)" >&2
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  ( cd "$tmp" && ar x "$LIB" )
  # Re-archive all extracted objects with proper alignment + symbol table.
  libtool -static -o "$LIB" "$tmp"/*.o
fi
