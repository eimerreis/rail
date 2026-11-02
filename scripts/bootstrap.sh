#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Rail currently targets Apple Silicon macOS." >&2
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
if [[ ! -x "$ROOT/.tools/go/bin/go" || "$("$ROOT/.tools/go/bin/go" version)" != "go version go1.27.3 darwin/arm64" ]]; then
  mkdir -p "$ROOT/.tools/downloads"
  archive="$ROOT/.tools/downloads/go1.27.3.darwin-arm64.tar.gz"
  curl --fail --location --retry 3 https://go.dev/dl/go1.27.3.darwin-arm64.tar.gz --output "$archive"
  expected=dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2
  actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
  [[ "$actual" == "$expected" ]] || { echo "Go archive checksum mismatch" >&2; exit 1; }
  rm -rf "$ROOT/.tools/go"
  tar -xzf "$archive" -C "$ROOT/.tools"
fi
"$ROOT/.tools/bin/python" "$ROOT/scripts/fetch-cef.py"
