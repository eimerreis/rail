#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_TYPE="${BUILD_TYPE:-Release}"
"$ROOT/scripts/bootstrap.sh"
"$ROOT/.tools/bin/cmake" -S "$ROOT" -B "$ROOT/build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$ROOT/.tools/bin/ninja" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DPROJECT_ARCH=arm64 -DUSE_SANDBOX=ON "$@"
"$ROOT/.tools/bin/cmake" --build "$ROOT/build" --config "$BUILD_TYPE" --parallel "${BUILD_JOBS:-6}"
"$ROOT/.tools/bin/ctest" --test-dir "$ROOT/build" --build-config "$BUILD_TYPE" --output-on-failure
echo "Built $ROOT/build/$BUILD_TYPE/Rail.app"
