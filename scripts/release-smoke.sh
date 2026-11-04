#!/usr/bin/env bash
# The real-engine checks a change must pass, on pull requests and before publishing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
uv pip install --python .tools/bin/python 'pillow==13.0.0'
export PATH="$PWD/.tools/bin:$PATH"
node scripts/smoke-test.mjs
node scripts/projects-smoke.mjs
node scripts/devtools-smoke.mjs
node scripts/context-menu-smoke.mjs
node scripts/theme-smoke.mjs
node scripts/find-smoke.mjs
node scripts/passwords-smoke.mjs
node scripts/reading-smoke.mjs
