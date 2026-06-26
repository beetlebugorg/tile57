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
  echo "==> re-packing $LIB with Apple libtool (macOS ld alignment)" >&2
  # Use Apple's libtool explicitly — Homebrew's GNU libtool may shadow it in
  # PATH and its `-static -o` means something entirely different (it would drop
  # the symbol table -> "Undefined symbols" at link). Feeding the archive back
  # to Apple libtool re-aligns members and rebuilds the symbol table.
  LIBTOOL="${LIBTOOL:-/usr/bin/libtool}"
  "$LIBTOOL" -static -o "$LIB.aligned" "$LIB"
  mv -f "$LIB.aligned" "$LIB"
  # Sanity check: the C ABI entry point must be present.
  if command -v nm >/dev/null && ! nm "$LIB" 2>/dev/null | grep -q ' T _tg_open_bytes'; then
    echo "ERROR: _tg_open_bytes missing after re-pack (wrong libtool?)" >&2
    exit 1
  fi
fi
