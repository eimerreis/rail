#!/usr/bin/env bash
# Build and tests must pass before calling this script. Never publish an unsigned app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Release/Rail.app"
OUTPUT="${1:?Usage: package-release.sh <output-directory>}"
: "${SPARKLE_PRIVATE_KEY_FILE:?Set the path to the exported Sparkle Ed25519 private key}"
: "${NOTARYTOOL_PROFILE:?Set the notarytool credential profile}"
: "${RAIL_RELEASE_TAG:?Set the immutable release tag}"
RAIL_RELEASE_REPOSITORY="${RAIL_RELEASE_REPOSITORY:-eimerreis/rail}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
SIGNATURE=$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)
[[ "$SIGNATURE" == *"Authority=Developer ID Application:"* ]] || { echo "Release requires Developer ID Application signing." >&2; exit 1; }
[[ "$SIGNATURE" == *"Timestamp="* ]] || { echo "Release requires timestamped signatures." >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"
ARCHIVE="$OUTPUT/Rail-$VERSION-macos-arm64.zip"
TEMPORARY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY"' EXIT
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMPORARY/notarize.zip"
NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE")
if [[ -n "${RELEASE_KEYCHAIN:-}" ]]; then NOTARY_ARGS+=(--keychain "$RELEASE_KEYCHAIN"); fi
/usr/bin/xcrun notarytool submit "$TEMPORARY/notarize.zip" "${NOTARY_ARGS[@]}" --wait
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose "$APP"
# Sign the final archive after stapling, since stapling changes the bundle.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
"$ROOT/vendor/sparkle/bin/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "https://github.com/$RAIL_RELEASE_REPOSITORY/releases/download/$RAIL_RELEASE_TAG/" \
  --link "https://github.com/$RAIL_RELEASE_REPOSITORY/releases" \
  --maximum-deltas 0 --maximum-versions 0 "$OUTPUT"
"$ROOT/vendor/sparkle/bin/sign_update" --verify --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$OUTPUT/appcast.xml"
cp "$ROOT/cef.lock.json" "$OUTPUT/cef.lock.json"
echo "Signed and notarized release: $ARCHIVE"
