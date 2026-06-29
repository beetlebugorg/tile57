#!/usr/bin/env bash
# Build the wasm style engine and copy it into the npm package so the package is
# self-contained (the .wasm is committed alongside index.js).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

cd "$ROOT"
zig build wasm
cp "$ROOT/zig-out/bin/style-engine.wasm" "$ROOT/bindings/js/style-engine.wasm"
echo "copied style-engine.wasm -> bindings/js/ ($(wc -c < "$ROOT/bindings/js/style-engine.wasm") bytes)"
