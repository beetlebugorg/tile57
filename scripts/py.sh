#!/usr/bin/env bash
# Run a Python script in the project's auto-managed virtualenv (.venv), so the
# tooling's deps (Pillow, for the sprite builder) are isolated — no global pip
# install needed. Usage: scripts/py.sh path/to/script.py [args...]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"
STAMP="$VENV/.deps-installed"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "==> creating Python venv (.venv)" >&2
  python3 -m venv "$VENV"
fi

# (Re)install deps if the venv is new or requirements.txt changed.
if [[ ! -f "$STAMP" || "$ROOT/requirements.txt" -nt "$STAMP" ]]; then
  echo "==> installing Python deps into .venv (Pillow)" >&2
  "$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null
  "$VENV/bin/python" -m pip install --quiet -r "$ROOT/requirements.txt"
  touch "$STAMP"
fi

exec "$VENV/bin/python" "$@"
