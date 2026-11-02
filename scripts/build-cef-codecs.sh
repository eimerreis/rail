#!/usr/bin/env bash
# Build Rail's pinned CEF from upstream source with H.264/AAC enabled.
# Keeps vendor/cef and the installed Rail.app intact. See README.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=build
if [[ "${1:-}" == --check || "${1:-}" == --plan ]]; then
  MODE="${1#--}"
  shift
fi
if [[ $# -gt 1 || "${1:-}" == --* ]]; then
  echo "Usage: $0 [--check|--plan] [build-directory]" >&2
  exit 2
fi
WORK="${1:-$ROOT/.cache/cef-codecs}"
PYTHON="${PYTHON:-python3}"
# These pins correspond to cef.lock.json; update all three together.
CEF_VERSION='156.0.14+g4fa4ab5+chromium-156.0.8078.48'
CEF_COMMIT='4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f'
BUILDER_SHA256='94d3ddd1e0d35482132f45dc101a593c9371b6eb2d8ff4af6cfe2734d2e48c6a'
"$PYTHON" - "$ROOT/cef.lock.json" "$CEF_VERSION" <<'PY'
import json, sys
if json.load(open(sys.argv[1]))['cef_version'] != sys.argv[2]:
    sys.exit('CEF source pins differ from cef.lock.json; update build-cef-codecs.sh first.')
PY
WORK="$("$PYTHON" - "$WORK" <<'PY'
from pathlib import Path
import sys
path = str(Path(sys.argv[1]).expanduser().resolve())
if any(c.isspace() for c in path) or not path.isascii():
    sys.exit('CEF build paths must contain only ASCII characters and no whitespace.')
print(path)
PY
)"
BUILDER="$WORK/automate-git.py"
export GN_DEFINES='is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=0'
export CEF_ARCHIVE_FORMAT=tar.bz2
ARGS=("--download-dir=$WORK/chromium" "--depot-tools-dir=$WORK/depot_tools"
  --branch=8078 "--checkout=$CEF_COMMIT" --chromium-checkout=refs/tags/156.0.8078.48
  --no-chromium-history --arm64-build --no-debug-build --build-target=cef
  --minimal-distrib-only --no-distrib-symbols --no-distrib-docs)
if [[ "$MODE" == plan ]]; then
  printf 'GN_DEFINES=%q CEF_ARCHIVE_FORMAT=%q ' "$GN_DEFINES" "$CEF_ARCHIVE_FORMAT"
  printf '%q ' "$PYTHON" "$BUILDER" "${ARGS[@]}"
  printf '\n'
  exit 0
fi
# Fail before downloading Chromium or creating its build tree. Budget 150 GiB
# for source, toolchains and Release outputs; actual use can vary.
"$PYTHON" - "$WORK" <<'PY'
from pathlib import Path
import platform, shutil, subprocess, sys
errors = []
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    errors.append('An Apple Silicon Mac is required.')
if platform.system() == 'Darwin':
    version = lambda s: tuple(int(n) for n in s.strip().split('.')[:2])
    if version(platform.mac_ver()[0]) < (26, 6):
        errors.append('CEF 156 source builds require macOS 26.6 or newer.')
    try:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True)
        if version(sdk) < (27, 0):
            errors.append(f'Xcode 27 / macOS SDK 27.0 is required; selected SDK is {sdk.strip()}.')
    except (OSError, subprocess.CalledProcessError):
        errors.append('Install full Xcode 27 and select it with xcode-select.')
path = Path(sys.argv[1])
while not path.exists():
    path = path.parent
free = shutil.disk_usage(path).free / 1024**3
if free < 150:
    errors.append(f'Budget at least 150 GiB free on the build volume; {free:.1f} GiB available at {path}.')
if errors:
    sys.exit('\n'.join(errors))
print(f'CEF build prerequisites passed ({free:.1f} GiB free).')
PY
if [[ "$MODE" == check ]]; then exit 0; fi
mkdir -p "$WORK"
curl --fail --location --silent --show-error --retry 3 --connect-timeout 30 \
  "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py" \
  --output "$BUILDER.part"
"$PYTHON" - "$BUILDER.part" "$BUILDER_SHA256" <<'PY'
import hashlib, sys
from pathlib import Path
path = Path(sys.argv[1])
if hashlib.sha256(path.read_bytes()).hexdigest() != sys.argv[2]:
    path.unlink()
    sys.exit('Upstream CEF builder SHA-256 mismatch.')
PY
mv "$BUILDER.part" "$BUILDER"
"$PYTHON" "$BUILDER" "${ARGS[@]}"
printf '\nCEF distributions: %s\n' "$WORK/chromium/chromium/src/cef/binary_distrib"
echo 'Build Rail with -DCEF_ROOT pointing to the generated minimal distribution, then run scripts/media-smoke.mjs.'
