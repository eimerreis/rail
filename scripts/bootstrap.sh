#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Eimerrail currently targets Apple Silicon macOS." >&2
  exit 1
fi
xcrun --find clang >/dev/null
# An existing tool environment can build and test without uv on the agent's PATH.
if [[ ! -x "$ROOT/.tools/bin/python" || ! -x "$ROOT/.tools/bin/cmake" || ! -x "$ROOT/.tools/bin/ninja" ]]; then
  UV="${UV:-$(command -v uv || true)}"
  if [[ -z "$UV" && -x "$HOME/.local/bin/uv" ]]; then
    UV="$HOME/.local/bin/uv"
  fi
  if [[ -z "$UV" ]]; then
    echo "Install uv (https://docs.astral.sh/uv/getting-started/installation/) and rerun bootstrap." >&2
    exit 1
  fi
fi
if [[ ! -x "$ROOT/.tools/bin/python" ]]; then
  "$UV" venv --python 3.12 "$ROOT/.tools"
fi
if [[ ! -x "$ROOT/.tools/bin/cmake" || ! -x "$ROOT/.tools/bin/ninja" ]]; then
  "$UV" pip install --python "$ROOT/.tools/bin/python" 'cmake==4.1.3' 'ninja==1.13.0'
fi
"$ROOT/.tools/bin/python" "$ROOT/scripts/fetch-cef.py"
