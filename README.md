# Eimerrail

A personal macOS browser with a native AppKit shell and Chromium Embedded Framework. This is the **Rail light** design: a narrow Spaces rail, vertical tabs, pinned shortcuts, and a compact toolbar.

## Run

The built app is at `build/Release/Eimerrail.app`.

```sh
cd ~/Github/eimerrail
./scripts/run.sh --no-build
```

Rebuild and launch with `./scripts/run.sh`, or build separately with `./scripts/build.sh`. You can also open the `.app` directly or copy it to Applications. Quit a running copy before rebuilding it.

Requirements: Apple Silicon, macOS 13+, Xcode or Command Line Tools, and [uv](https://docs.astral.sh/uv/). Bootstrap installs pinned CMake/Ninja into `.tools` and downloads the official, checksum-verified CEF distribution into `vendor`. CEF/Chromium versions are pinned in `cef.lock.json`.

For stable Keychain access across rebuilds, configure an existing personal signing identity once:

```sh
security find-identity -v -p codesigning
./scripts/build.sh '-DEIMERRAIL_SIGN_IDENTITY=Your signing identity'
```

The selection stays in the local CMake cache. This workspace is already configured with a personal Developer ID identity. Signing happens locally without notarization or publishing. A clean checkout defaults to ad-hoc signing (`-`); macOS may request Keychain access again after rebuilding an ad-hoc app. Eimerrail uses its own **Eimerrail Safe Storage** Keychain entry for Chromium's cookie encryption; it does not use a mock encryption key.

## Use

| Action | Control |
| --- | --- |
| Hide/show sidebar and Spaces rail | **⌘ S** |
| Address or search | **⌘ L** |
| New / close tab | **⌘ T** / **⌘ W** |
| Reload | **⌘ R** |
| Back / forward | **⌘ [** / **⌘ ]** |
| Find in page | **⌘ F** |
| Select a tab in the current Space | **⌘ 1–9** |
| Pin, unpin, unload, or move a tab | Right-click the tab |
| Change the current tab's session | Toolbar session picker or tab badge |
| Create a reusable session | Session picker → New session |
| Switch / add Spaces | Icons / plus in the left rail |
| Rename Space / set its default session | Ellipsis beside the Space name |
| Change idle timeout | Settings button or **⌘ ,** |

Work and Personal are reusable named sessions. Tabs in the same named session share cookies and site storage, even across Spaces. **Isolated** gives that tab a separate, persistent profile. It keeps its login after unloading and restarting; it is not an incognito mode. Changing sessions reloads the current URL in the chosen profile.

Spaces organize tabs independently of sessions. A Space's default session applies to new tabs. Its existing tabs keep their current sessions.

After **10 minutes** out of selection, a tab's actual CEF browser is closed. The timeout is configurable to 1, 5, 10, 15, 30, or 60 minutes and checked every five seconds. Pinned tabs follow the same rule. The selected tab stays awake. Reopening an unloaded tab creates a new Chromium page at its saved URL.

This releases the page; it does **not** make the entire browser or shared Chromium/profile resources consume zero memory. Only title, URL, pin/session/Space identity are restored. Page JavaScript state, scroll position and unsaved input are not serialized. A page with an unload confirmation can ask to stay open.

## Saved data

`~/Library/Application Support/Eimerrail/` contains:

- `state.json`: tabs, Spaces, sessions and preferences; saved atomically.
- `Chromium/`: separate persistent profiles for named and isolated sessions.
- `cef.log`: Chromium warnings/errors.

Startup loads only the selected page. Other tabs remain unloaded until selected. An unreadable layout gets a recovery copy before a fresh layout is saved. Closing a tab removes its entry, not its profile files. Eimerrail does not import or modify your Arc/Chrome profiles.

## Verify

```sh
./scripts/build.sh             # Release build, bundle signatures, model + persistence tests
node scripts/smoke-test.mjs     # Node 22+: actual native app + Chromium integration checks
```

The integration test uses disposable profiles under `.runtime-test`, a localhost fixture, and a development-only control channel. It verifies shared and isolated cookies, popup separation, native CMD+S, pinned-tab destruction/recreation, session switching, clean quit, and persistence across restart. It never opens your normal browser profile. The control channel and remote debugging are enabled only by explicit test arguments.

The C++ model can also be tested without CEF:

```sh
.tools/bin/cmake -S . -B build-model -DEIMERRAIL_BUILD_APP=OFF
.tools/bin/cmake --build build-model
.tools/bin/ctest --test-dir build-model --output-on-failure
```

## First-version limits

- No extension manager, sync, password manager, history UI, default-browser registration, or automatic Chromium updater.
- Named-session popups preserve `window.opener` for login flows. Popups from isolated tabs open with a fresh isolated profile; use a named session for login flows requiring a shared opener session.
- Camera/microphone and common website permissions have native prompts. Screen sharing is not implemented. File downloads use a native save panel.
- Chromium's sandbox and web security remain enabled. Invalid certificates and unsupported URL schemes are not bypassed. External-app links, local file browsing, and DRM compatibility are not implemented.
- Updating Chromium is manual: update the matching version/archive/size/checksum fields in `cef.lock.json` from the [official CEF builds index](https://cef-builds.spotifycdn.com/index.json), then run the build and integration checks again. Old engine versions eventually become unsuitable for daily browsing.

## Source map

- `src/BrowserModel.*` — tab, Space and session state; idle policy.
- `src/BrowserController.mm` — native shell and browser lifecycle.
- `src/CEFBridge.mm` — Chromium callbacks, navigation, permissions and downloads.
- `src/StateStore.mm` — layout persistence and recovery.
- `src/NativeViews.*` — native Rail controls and colors.
- `design/rail-reference.html` — the selected interactive design reference.
- `docs/plans/2026-10-29-native-browser.md` — implementation decisions.

CEF's license and third-party credits are included in the app's Resources directory.
