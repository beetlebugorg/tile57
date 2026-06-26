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
  echo "==> re-packing $LIB for macOS ld alignment" >&2
  # Apple's ld64 rejects archive members that aren't 8-byte aligned, and Zig's
  # archive isn't. Feeding the archive back to libtool only copies the bad
  # members (it warns + drops them). The fix is to EXTRACT the objects and
  # re-archive them from the .o files (fresh members get aligned). Extract with
  # Zig's own ar (reads its archive reliably); re-archive with Apple's libtool
  # (NOT Homebrew's GNU libtool, whose `-static` is unrelated to archiving).
  LIBTOOL="${LIBTOOL:-/usr/bin/libtool}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  ( cd "$tmp" && "$ZIG" ar x "$LIB" )
  if [[ -z "$(ls "$tmp"/*.o 2>/dev/null)" ]]; then
    echo "ERROR: no objects extracted from $LIB" >&2
    exit 1
  fi
  # llvm-ar's deterministic mode zeroes the permission bits, so extracted objects
  # come out mode 000 and libtool can't read them (errno=13). Make them readable.
  chmod u+rw "$tmp"/*.o
  "$LIBTOOL" -static -o "$LIB" "$tmp"/*.o
  if command -v nm >/dev/null; then
    # Match the symbol name only (macOS prefixes with _, type column varies).
    if ! nm "$LIB" 2>/dev/null | grep -q 'tg_open_bytes'; then
      echo "ERROR: tg_open_bytes missing after re-pack. tg_* symbols found:" >&2
      nm "$LIB" 2>/dev/null | grep -i 'tg_' | head -5 >&2
      exit 1
    fi
  fi
fi
