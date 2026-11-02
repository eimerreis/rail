#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_TYPE="${BUILD_TYPE:-Release}"
if [[ "${1:-}" == --no-build ]]; then
  shift
else
  "$ROOT/scripts/build.sh"
fi
APP="$ROOT/build/$BUILD_TYPE/Rail.app"
if [[ ! -d "$APP" ]]; then
  echo "App is missing: $APP. Run scripts/build.sh first." >&2
  exit 1
fi
exec /usr/bin/open -n "$APP" --args "$@"
