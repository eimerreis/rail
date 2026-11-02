#!/bin/bash
# Launched from a private copy outside the app bundle, so it survives replacement.
set -euo pipefail
umask 077
export PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"
export GIT_TERMINAL_PROMPT=0

CACHE="$1"
RUN="$2"
APP="$3"
PARENT_PID="$4"
SIGN_IDENTITY="$5"
GITHUB_CLIENT_ID="$6"
shift 6

fail() { echo "$*" >&2; exit 1; }
[[ "$PARENT_PID" =~ ^[0-9]+$ ]] || fail "Invalid application process."
[[ -d "$APP" && "$APP" == /*.app ]] || fail "Application bundle is missing: $APP"
[[ -w "$(dirname "$APP")" && -w "$APP" ]] || fail "Move Eimerrail to a writable Applications folder, then try again."
mkdir -p "$CACHE"
mkdir "$CACHE/lock" 2>/dev/null || fail "Another reinstall is running. If it was interrupted, remove $CACHE/lock and retry."
STAGING=""
BACKUP=""
cleanup() {
  result=$?
  trap - EXIT
  rm -f "$RUN/ready"
  # Roll back if replacement or launch failed after moving the original aside.
  if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
    can_restore=true
    if [[ -e "$APP" ]] && ! mv "$APP" "$STAGING/Failed.app"; then can_restore=false; fi
    if [[ "$can_restore" != true ]] || ! mv "$BACKUP" "$APP"; then
      echo "Could not restore the previous app. Recovery copy: $BACKUP" >&2
      STAGING="" # Keep the recovery copy if the destination became unwritable.
    fi
  fi
  if [[ -n "$STAGING" ]]; then rm -rf "$STAGING"; fi
  rmdir "$CACHE/lock"
  if [[ "$result" != 0 ]]; then
    echo "Reinstall failed (exit $result). The previous app has been kept."
    # The native app shows errors while alive. After shutdown, reveal the log
    # and reopen the original so installation failures are still visible.
    if ! kill -0 "$PARENT_PID" 2>/dev/null; then
      open -t "$RUN/update.log" || true
      open -n "$APP" --args "$@" || true
    fi
  fi
  exit "$result"
}
trap 'cleanup "$@"' EXIT

echo "Fetching latest main…"
# This checkout belongs only to the updater; never touch a developer's checkout.
SOURCE="$CACHE/source"
[[ "$APP" != "$SOURCE"/build/* ]] || fail "Move the cached build to Applications before reinstalling."
if [[ ! -d "$SOURCE/.git" ]]; then
  mkdir -p "$SOURCE"
  git -C "$SOURCE" init
fi
git -C "$SOURCE" fetch --depth 1 https://github.com/eimerreis/rail.git refs/heads/main
git -C "$SOURCE" checkout --detach FETCH_HEAD
echo "Building $(git -C "$SOURCE" rev-parse HEAD)…"
BUILD_TYPE=Release /bin/bash "$SOURCE/scripts/build.sh" \
  "-DEIMERRAIL_SIGN_IDENTITY=$SIGN_IDENTITY" \
  "-DEIMERRAIL_GITHUB_CLIENT_ID=$GITHUB_CLIENT_ID"
BUILT="$SOURCE/build/Release/Eimerrail.app"
codesign --verify --deep --strict "$BUILT"

# Copy and verify on the destination volume before asking the browser to quit.
STAGING="$(mktemp -d "$(dirname "$APP")/.eimerrail-update.XXXXXX")"
ditto "$BUILT" "$STAGING/Eimerrail.app"
codesign --verify --deep --strict "$STAGING/Eimerrail.app"
echo "Build ready. Waiting for Eimerrail to quit…"
touch "$RUN/ready"
for ((attempt=0; attempt<120; attempt++)); do
  if ! kill -0 "$PARENT_PID" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$PARENT_PID" 2>/dev/null; then
  fail "Eimerrail stayed open. Save any unsaved pages and try again."
fi

BACKUP="$STAGING/Previous.app"
mv "$APP" "$BACKUP"
mv "$STAGING/Eimerrail.app" "$APP"
open -n "$APP" --args "$@"
# Once launch succeeds, cleanup errors must never roll back a working install.
BACKUP=""
echo "Installed latest main and reopened $APP."
