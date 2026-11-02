# Eimerrail

A personal macOS browser with a native AppKit shell and Chromium Embedded Framework. This is the **Rail light** design: a narrow Spaces rail, vertical tabs, pinned shortcuts, and a compact toolbar.

## Run

The built app is at `build/Release/Eimerrail.app`.

```sh
cd ~/Github/eimerrail
./scripts/run.sh --no-build
```

Rebuild and launch with `./scripts/run.sh`, or build separately with `./scripts/build.sh`. You can also open the `.app` directly or copy it to Applications. Quit a running copy before rebuilding it.

To reinstall the latest source version in one step, choose **Eimerrail → Reinstall Latest main**. Rail fetches `main` from `eimerreis/rail`, builds and tests it in a separate cache, then quits, replaces the running app in its current location, and reopens it. Tabs, profiles, launch arguments, the local signing identity, and the GitHub Client ID are preserved. Unsaved pages can prevent the restart; save them and retry. Your development checkout is untouched. The app folder must be writable, and the build requirements below still apply. The first run downloads the build tools and CEF; later runs reuse them. Logs and the updater checkout live in `~/Library/Caches/de.eimerreis.eimerrail/updater/`. Build failures leave the current app running and offer **Show Log**; installation failures restore the previous app and open the log.

Requirements: Apple Silicon, macOS 13+, Xcode or Command Line Tools, and [uv](https://docs.astral.sh/uv/). Bootstrap installs pinned CMake/Ninja into `.tools` and downloads the official, checksum-verified CEF distribution into `vendor`. CEF/Chromium versions are pinned in `cef.lock.json`.

Builds default to `EIMERRAIL_SIGN_IDENTITY=AUTO`. If exactly one valid code-signing identity is installed, CMake selects it and saves its fingerprint in the local build cache. This gives macOS a stable app identity, so Keychain's **Always Allow** survives rebuilds. With no identity or several identities, the build warns and falls back to ad-hoc signing. Select an identity explicitly when needed:

```sh
security find-identity -v -p codesigning
./scripts/build.sh '-DEIMERRAIL_SIGN_IDENTITY=Your signing identity'
```

For an existing build previously configured with ad-hoc signing, run `./scripts/build.sh -DEIMERRAIL_SIGN_IDENTITY=AUTO` once to select the installed certificate. `-DEIMERRAIL_SIGN_IDENTITY=-` explicitly opts into ad-hoc signing, which can require new Keychain approvals after each rebuild. Signing happens locally without notarization or publishing. When switching from ad-hoc signing to a certificate, the normal browser may need one final **Always Allow** for its existing **Eimerrail Safe Storage** entry.

The build normalizes app and helper `Info.plist` templates before signing, so Chromium can validate the running processes as well as their bundles on disk.

## Use

| Action | Control |
| --- | --- |
| Hide/show sidebar and Spaces rail | **⌘ S** |
| Address or search | **⌘ L** |
| New / close tab | **⌘ T** / **⌘ W** |
| Reopen closed tab | **⌘ Z** right after closing, or **⇧ ⌘ T** any time |
| Reload | **⌘ R** |
| Back / forward | **⌘ [** / **⌘ ]** |
| Find in page | **⌘ F** |
| Open / close Chromium DevTools for the current page | **⌥ ⌘ I** or View → Developer Tools; **⌘ W** closes the focused inspector |
| Inspect a page element | Right-click the page → Inspect Element |
| Select a tab in the current Space | **⌘ 1–9** |
| Switch to recently used tabs | Hold **⌃** and press **Tab** (**⇧** to go back); release **⌃** to switch |
| Pin or unpin a tab | Drag it into or out of **Pinned**, or right-click it |
| Rename a pinned tab | Double-click it, or right-click → Rename Tab… (empty name restores the page title) |
| Zoom the window | Double-click the top bar (follows the title bar setting in Desktop & Dock) |
| See recent downloads | Downloads button beside the session picker; click a file to open it, the magnifier to show it in Finder |
| Unload or move a tab | Right-click the tab |
| Change the current tab's session | Toolbar session picker or tab badge |
| Create a reusable session | Session picker → New session |
| Switch / add Spaces | Icons / plus in the left rail |
| Rename Space / set its default session | Ellipsis beside the Space name |
| Send matching links to a Space | Ellipsis beside the Space name → Open Links in This Space |
| Change idle timeout | Settings button or **⌘ ,** |
| Show the Space's projects | **<Space> home** at the top of the sidebar, or **⌘ ⇧ H** |
| Add a project | Space home → Add project, or File → Add Current Page as Project on a repo page |
| Add a tab to a project as Local / INT / PROD / link | Right-click the tab → Add to Project |
| Add environments and links, rename, move, remove | **…** on a project card |

Work and Personal are reusable named sessions. Tabs in the same named session share cookies and site storage, even across Spaces. **Isolated** gives that tab a separate, persistent profile. It keeps its login after unloading and restarting; it is not an incognito mode. Changing sessions reloads the current URL in the chosen profile.

Downloads save straight to your Downloads folder without asking; a taken name gets a number such as `report (1).pdf`. The last 20 stay listed across restarts.

Pinned tabs remember the page they were pinned on and keep a name you give them until they are unpinned. Closing a pinned tab (**⌘ W**) keeps it pinned, unloads it and returns it to that page, as in Arc.

Links opened from other apps reuse a pinned tab for that page or a path below it, switching to its Space and keeping its session. For example, a pin for `https://github.com/acme/repo` also opens links to that repository's issues. The most specific pinned path wins; equivalent pins prefer the current Space, then the most recently used tab. Space rules take precedence. If no pin matches, the link opens in a new tab or the selected blank tab.

The reading list (**⌘ ⇧ L**, or the tray in the rail) belongs to no Space. Press **⌘ V** there to save the link on your clipboard, or save the current page with **⌘ ⇧ D**. Saved pages load in the background, using the session of the Space that a rule assigns them to, or otherwise the current Space, and appear as plain articles you can read offline. Long reads resume where you stopped. Opening an item never marks it read: press **E** or use **Mark read**, and press it again to undo. **J** and **K** move through the list. Pages behind a login, or with too little text, open as a tab instead. **Open original** and links in an article follow your pinned tabs and Space rules.

Feeds live in the same list. Use **Manage › Add Feed…** with a feed or site address. Feeds are checked every 30 minutes while the app is open, and a new feed brings only its five newest posts. The list is stored in `reading.json`, with saved articles in `Reading/`.

Spaces organize tabs independently of sessions. A Space's default session applies to new tabs. Its existing tabs keep their current sessions.

A Space can claim links by address pattern, one per line, for example `dev.azure.com/contoso/**` for a Contoso Space and `dev.azure.com/fabrikam/**` for a Fabrikam Space. Patterns match host (with port) and path, ignoring scheme, `www.`, query, fragment and case. `*` matches within one path segment, `**` matches anything; a trailing `/**` also matches the prefix itself. When several patterns match, the most specific wins. Rules apply to links from other apps, links that open a new tab (which then use the target Space's session and lose `window.opener`), and addresses typed into a new blank tab. Navigation inside an existing tab stays where it is.

After **10 minutes** out of selection, a tab's actual CEF browser is closed. The timeout is configurable to 1, 5, 10, 15, 30, or 60 minutes and checked every five seconds. Pinned tabs follow the same rule. The selected tab stays awake. Reopening an unloaded tab creates a new Chromium page at its saved URL.

This releases the page; it does **not** make the entire browser or shared Chromium/profile resources consume zero memory. Only title, URL, pin/session/Space identity are restored. Page JavaScript state, scroll position and unsaved input are not serialized. A page with an unload confirmation can ask to stay open.

## Projects

Each Space has a **home** with one card per project. A project groups a repository, its pipelines, the places it runs (Local, INT, PROD…) and any links you want one click away, such as feature flags or dashboards. Every button opens in its own session; an environment can have **its own isolated profile**, which keeps, for example, a separate PROD login. Opening an environment reuses a tab in this Space that already shows it. A Space still reopens on its last used tab; the home is one click away.

While a Space home is open, Eimerrail checks its projects: local addresses by connecting to their port, remote ones with a request that carries no cookies (every 60 seconds), pipelines and open pull requests every two minutes, and everything on **Check now**. Cards that need attention come first: an environment that is down or slow, a failed pipeline on the default branch, or a missing sign-in. Nothing is checked for Spaces you aren't looking at.

**Azure DevOps** needs no setup. Requests run in the session of the project's Repo link and use the login you already have there; the app never reads or stores the cookies. They are limited to read-only Azure DevOps API requests. If that session isn't signed in, the card offers to open Azure DevOps there.

**GitHub** uses a personal GitHub App and its device sign-in. Set it up once:

1. GitHub → Settings → Developer settings → GitHub Apps → New GitHub App. Disable the webhook, select **Enable Device Flow**, and give it read-only repository permissions for **Metadata**, **Actions** and **Pull requests**.
2. Install it on your account and on each organization with **All repositories**, so new repositories are covered without granting access again.
3. Copy its **Client ID** and either build with `./scripts/build.sh -DEIMERRAIL_GITHUB_CLIENT_ID=<id>` or run `defaults write de.eimerreis.eimerrail GitHubClientID <id>`.

The first time a card or import needs GitHub, Eimerrail copies a code to the clipboard and opens GitHub's authorization page in that project's session. Tokens are stored in the Keychain (`Eimerrail Connections`) and refreshed automatically; you sign in again only after about six months without use or if you revoke the app.

## Saved data

`~/Library/Application Support/Eimerrail/` contains:

- `state.json`: tabs, Spaces, sessions and preferences; saved atomically.
- `projects.json`: projects, environments, links and provider connections, without any tokens. An unreadable file gets a recovery copy before anything is saved over it.
- `Chromium/`: separate persistent profiles for named and isolated sessions.
- `cef.log`: Chromium warnings/errors.

Startup loads only the selected page. Other tabs remain unloaded until selected. An unreadable layout gets a recovery copy before a fresh layout is saved. Closing a tab removes its entry, not its profile files. Eimerrail does not import or modify your Arc/Chrome profiles.

## Verify

```sh
./scripts/build.sh             # Release build, bundle signatures, model + persistence tests
node scripts/smoke-test.mjs     # Node 22+: actual native app + Chromium integration checks
node scripts/devtools-smoke.mjs # DevTools close button, shortcut/menu toggles and lifecycle
node scripts/projects-smoke.mjs # Space home, health checks, sign-in states, opening environments
```

The integration test uses disposable profiles under `.runtime-test`, a localhost fixture, and a development-only control channel. It verifies shared and isolated cookies, popup separation, native CMD+S, pinned-tab destruction/recreation, session switching, clean quit, and persistence across restart. Automation requires an explicit data directory and refuses the normal browser profile. Tests use a separate **Eimerrail Test Safe Storage** Keychain entry, shared across test runs, with real Chromium cookie encryption. The normal browser keeps using **Eimerrail Safe Storage**. Keep the same signing certificate to retain Keychain approvals; a locked login Keychain can still require unlocking. The control channel and remote debugging are enabled only by explicit test arguments.

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
- `src/Projects.*` — projects, environments, links, connections, repository recognition, attention rules.
- `src/ProjectStatus.mm` — health checks, Azure DevOps through a session, GitHub device sign-in and API.
- `src/ProjectsView.mm` — the Space home and project cards.
- `src/BrowserController.mm` — native shell and browser lifecycle.
- `src/CEFBridge.mm` — Chromium callbacks, navigation, permissions and downloads.
- `src/StateStore.mm` — layout persistence and recovery.
- `src/NativeViews.*` — native Rail controls and colors.
- `design/rail-reference.html` — the selected interactive design reference.
- `docs/plans/2026-10-29-native-browser.md` — implementation decisions.

CEF's license and third-party credits are included in the app's Resources directory.

## License

MIT. See [LICENSE](LICENSE). Bootstrap downloads CEF and Chromium separately; they keep their own licenses.
