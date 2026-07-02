#!/usr/bin/env bash
# Re-pack a Zig-built static archive so Apple's ld64 accepts it. Zig's archiver
# leaves 64-bit mach-o members on non-8-byte offsets, and ld64 rejects those
# ("64-bit mach-o member ... not 8-byte aligned"). Partial-link (`ld -r`) every
# member into ONE relocatable object — which drops per-member alignment from the
# picture entirely and keeps every global symbol global — then wrap that single
# object with Apple's libtool, which guarantees the lone member is aligned.
#
# Invoked from build.zig as a post-build step on macOS so a plain `zig build`
# emits an ld64-compatible libtile57.a with no wrapper script.
#
# Usage: macho-align.sh <in-archive> <out-archive>
set -euo pipefail

ZIG="${ZIG:-zig}"
LIBTOOL="${LIBTOOL:-/usr/bin/libtool}"

# Absolutise both paths: Zig passes the archive as a build-root-relative path,
# and we `cd` into a temp dir to extract, which would break a relative path.
abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
in="$(abspath "$1")"
out="$(abspath "$2")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

( cd "$tmp" && "$ZIG" ar x "$in" )
if [[ -z "$(ls "$tmp"/*.o 2>/dev/null)" ]]; then
  echo "macho-align: no objects extracted from $in" >&2
  exit 1
fi
# llvm-ar's deterministic mode zeroes the permission bits, so extracted objects
# come out mode 000 and ld can't read them (errno=13). Make them readable.
chmod u+rw "$tmp"/*.o

combined="$tmp/combined.o"
# -r: relocatable (partial) link; undefined libc refs from Lua are fine here.
# ld-prime has historically had `-r` gaps, so fall back to the classic linker.
if ! ld -r -o "$combined" "$tmp"/*.o 2>"$tmp/ld.err"; then
  cat "$tmp/ld.err" >&2
  echo "macho-align: ld -r failed; retrying with -ld_classic" >&2
  ld -r -ld_classic -o "$combined" "$tmp"/*.o
fi

"$LIBTOOL" -static -o "$out" "$combined"
