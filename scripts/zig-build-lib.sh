#!/usr/bin/env bash
# Build libchartplotter.a via `zig build`. On macOS, re-pack the archive with Apple's
# libtool: Zig's archive members aren't 8-byte aligned and Apple's ld64 rejects
# them ("64-bit mach-o member ... not 8-byte aligned"). Zig self-caches, so this
# is cheap to run unconditionally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"
OPT="${1:-ReleaseFast}"

cd "$ROOT/tilegen"
"$ZIG" build "-Doptimize=$OPT"

LIB="$ROOT/tilegen/zig-out/lib/libchartplotter.a"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "==> re-packing $LIB for macOS ld alignment" >&2

  dump_syms() { # $1=label $2=archive-or-object
    command -v nm >/dev/null || return 0
    echo "  [diag] $1:" >&2
    nm "$2" 2>/dev/null | grep -iE 'cp_source_open|cp_source_close|cp_diag_lua_version' | head >&2 \
      || echo "    (no cp_* symbols)" >&2
  }
  dump_syms "pre-repack (zig-built archive)" "$LIB"

  # Apple's ld64 rejects archive members whose offsets aren't 8-byte aligned,
  # and Zig's `ar` doesn't align them. Earlier attempts to re-archive the .o
  # members with libtool produced an aligned archive but lost the *global*
  # export aliases (`T _cp_*`), keeping only the module-local `_capi.cp_*`.
  #
  # Robust fix: partial-link all members into ONE relocatable object with
  # `ld -r`. That (a) removes per-member alignment from the equation entirely
  # and (b) preserves every global symbol (ld -r keeps globals global; we pass
  # no -unexported_symbols_list). Then wrap that single object in an archive
  # with Apple's libtool, which guarantees the lone member is aligned.
  LIBTOOL="${LIBTOOL:-/usr/bin/libtool}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  ( cd "$tmp" && "$ZIG" ar x "$LIB" )
  if [[ -z "$(ls "$tmp"/*.o 2>/dev/null)" ]]; then
    echo "ERROR: no objects extracted from $LIB" >&2
    exit 1
  fi
  # llvm-ar's deterministic mode zeroes the permission bits, so extracted objects
  # come out mode 000 and the linker can't read them (errno=13). Make them readable.
  chmod u+rw "$tmp"/*.o

  combined="$tmp/chartplotter_combined.o"
  # -r: relocatable (partial) link; undefined libc refs from Lua are fine here.
  # The newer ld-prime has historically had `-r` gaps; fall back to the classic
  # linker if the default one can't do the partial link.
  if ! ld -r -o "$combined" "$tmp"/*.o 2>"$tmp/ld.err"; then
    cat "$tmp/ld.err" >&2
    echo "  [diag] ld -r failed; retrying with -ld_classic" >&2
    ld -r -ld_classic -o "$combined" "$tmp"/*.o
  fi
  dump_syms "post ld -r (combined object)" "$combined"

  "$LIBTOOL" -static -o "$LIB" "$combined"
  dump_syms "post-repack (final archive)" "$LIB"

  if command -v nm >/dev/null && ! nm "$LIB" 2>/dev/null | grep -qi 'cp_source_open'; then
    echo "ERROR: cp_source_open missing after re-pack (see diag above)." >&2
    exit 1
  fi
fi
