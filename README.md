# Rail

A personal macOS browser with a native AppKit shell and Chromium Embedded Framework: a narrow Spaces rail, vertical tabs, pinned shortcuts, and a compact toolbar. Its mark is the rounded cream R on a near-black tile, its typeface Manrope, and it comes in three themes: **Porcelain** (warm, the default), **Nightline** (dark petrol) and **Daylight** (airy blue).

## Run

The built app is at `build/Release/Rail.app`.

```sh
cd ~/Github/rail
./scripts/run.sh --no-build
```

Rebuild and launch with `./scripts/run.sh`, or build separately with `./scripts/build.sh`. You can also open the `.app` directly or copy it to Applications. Quit a running copy before rebuilding it.

Packaged releases use **Sparkle 2** for automatic updates. Rail checks every six hours, downloads signed updates in the background, and installs them when the browser quits. **Rail → Check for Updates…** checks immediately; the same menu lets you disable automatic checks or installation. The Chromium engine updates with the complete app. Merging changes and their changesets into `main` automatically versions, builds, and tests Rail, then signs, notarizes, and publishes an update. Scheduled Chromium checks propose engine updates with a changeset for the next release. See [release setup](docs/updates.md) for the signing configuration and first release. Development builds without a Sparkle public key retain the source reinstall command below.

To reinstall the latest source version in one step, choose **Rail → Reinstall Latest main**. Rail fetches `main` from `eimerreis/rail`, builds and tests it in a separate cache, then quits, replaces the running app in its current location, and reopens it. Tabs, profiles, launch arguments, the local signing identity, and the GitHub Client ID are preserved. Unsaved pages can prevent the restart; save them and retry. Your development checkout is untouched. The app folder must be writable, and the build requirements below still apply. The first run downloads the build tools and CEF; later runs reuse them. Logs and the updater checkout live in `~/Library/Caches/de.eimerreis.rail/updater/`. Build failures leave the current app running and offer **Show Log**; installation failures restore the previous app and open the log.

Requirements: Apple Silicon, macOS 13+, Xcode or Command Line Tools, and [uv](https://docs.astral.sh/uv/). Bootstrap installs pinned CMake/Ninja and Go 1.27.3 into `.tools` and downloads the official, checksum-verified CEF distribution into `vendor`. CEF/Chromium versions are pinned in `cef.lock.json`.

Builds default to `RAIL_SIGN_IDENTITY=AUTO`. If exactly one valid code-signing identity is installed, CMake selects it and saves its fingerprint in the local build cache. This gives macOS a stable app identity, so Keychain's **Always Allow** survives rebuilds. With no identity or several identities, the build warns and falls back to ad-hoc signing. Select an identity explicitly when needed:

```sh
security find-identity -v -p codesigning
./scripts/build.sh '-DRAIL_SIGN_IDENTITY=Your signing identity'
```

For an existing build previously configured with ad-hoc signing, run `./scripts/build.sh -DRAIL_SIGN_IDENTITY=AUTO` once to select the installed certificate. `-DRAIL_SIGN_IDENTITY=-` explicitly opts into ad-hoc signing, which can require new Keychain approvals after each rebuild. Signing happens locally without notarization or publishing. When switching from ad-hoc signing to a certificate, the normal browser may need one final **Always Allow** for its existing **Rail Safe Storage** entry.

The build normalizes app and helper `Info.plist` templates before signing, so Chromium can validate the running processes as well as their bundles on disk.

Rail uses its own **Rail Safe Storage** Keychain entry for Chromium's cookie encryption; it does not use a mock encryption key.

## Use

| Action | Control |
| --- | --- |
| Hide/show sidebar and Spaces rail | **⌘ S**; choose Off, Subtle or Full animation in Settings → Appearance |
| Change the theme | Settings → Appearance → Theme: Porcelain, Nightline or Daylight. Applies to every Rail window at once and is remembered; web pages keep their own colours |
| Address or search | **⌘ L** |
| New / close tab | **⌘ T** / **⌘ W** |
| Open a link in a background tab | **Middle-click** or **⌘ click**; hold **Shift** to select the new tab |
| Reopen closed tab | **⌘ Z** right after closing, or **⇧ ⌘ T** any time |
| Select several tabs | **⌘ click** adds or removes a tab, **⇧ click** selects a range, **Esc** clears. Pinned tabs aren't part of a selection |
| Act on selected tabs | Right-click a selected tab to close, snooze or move them; **⌘ W** closes them, and dragging one onto a Space moves them all |
| Snooze tabs | Right-click → **Snooze Tab**. They unload and return to their place at the chosen time; **Snoozed** below the tab list shows them until then |
| Reload | **⌘ R** |
| Back / forward | **⌘ [** / **⌘ ]** |
| Find in page | **⌘ F** opens the live find bar with highlighted matches and a match count; press again to select the query |
| Next / previous match | **Enter** / **⇧ Enter** in the find bar, or **⌘ G** / **⇧ ⌘ G**; wraps at either end |
| Close find and return to the page | **Esc**; reopening the bar keeps the tab's query |
| Fill or create a 1Password login | **⇧ ⌘ P**, the toolbar key, or View → 1Password |
| Open or close Chromium DevTools for the current page | **⌥ ⌘ I** or View → Developer Tools |
| Dock DevTools beside the page or pop them out | **⌥ ⇧ ⌘ D** or View → Dock Developer Tools; drag the divider to resize |
| Inspect a page element | Right-click the page → Inspect Element |
| Select a tab in the current Space | **⌘ 1–9** |
| Switch to recently used tabs | Hold **⌃** and press **Tab** (**⇧** to go back); release **⌃** to switch |
| Pin or unpin a tab | Drag it into or out of **Pinned**, or right-click it |
| Rename a pinned tab | Double-click it, or right-click → Rename Tab… (empty name restores the page title) |
| Zoom the window | Double-click the top bar (follows the title bar setting in Desktop & Dock) |
| See recent downloads | Downloads button beside the session picker; click a file to open it, the magnifier to show it in Finder |
| Move a tab to another Space | Drag it onto that Space's icon in the left rail, or right-click it → Move to Space |
| Unload a tab | Right-click the tab |
| Change the current tab's session | Toolbar session picker or tab badge |
| Create a reusable session | Session picker → New session |
| Switch / add Spaces | Icons / plus in the left rail |
| Rename Space, change its icon or default session | Settings → Spaces, or the ellipsis beside the Space name |
| Send matching links to a Space | Settings → Spaces → Links that open here (also Space ellipsis → Open Links in This Space); test an address under Test a link |
| Open Settings (appearance, tabs, DevTools, Spaces, sessions, projects, connections) | Settings button in the rail or **⌘ ,** |
| Show the Space's projects | **Projects** at the top of the sidebar, or **⌘ ⇧ H** |
| Show your own pull requests and their checks | **Activity** in the sidebar, or **⌘ ⇧ A** |
| Follow your own pull requests and the pipelines you started | The Checks capsule in the toolbar, or **⌘ ⇧ K** for its list |
| Add a project | Projects → Add project, or File → Add Current Page as Project on a repo page |
| Add a tab to a project as Local / INT / PROD / link | Right-click the tab → Add to Project |
| Add environments and links, rename, move, remove | **…** on a project card |

Projects and Activity refresh on their own. Rail follows every Space in the background, checking about every 20 seconds while something of yours is running and about every 2 minutes otherwise, and slowing down if a provider asks it to. The toolbar's **capsule** counts your Tracked Runs: your own open pull requests, and pipelines you started by hand on any branch. It widens to announce a pass or an approval a run is waiting on, and a failure stays announced until you dismiss it, open the run or show it in Activity. Anything that failed while Rail was closed appears without an announcement. An amber triangle means the picture may be out of date, for example after signing out. Rail only tells you what happens in-app; macOS notifications aren't used. See [GLOSSARY.md](GLOSSARY.md) for the terms.

Work and Personal are reusable named sessions. Tabs in the same named session share cookies and site storage, even across Spaces. **Isolated** gives that tab a separate, persistent profile. It keeps its login after unloading and restarting; it is not an incognito mode. Changing sessions reloads the current URL in the chosen profile.

Downloads save straight to your Downloads folder without asking; a taken name gets a number such as `report (1).pdf`. The last 20 stay listed across restarts.

Desktop sign-in callbacks and app links (such as CleanShot's) show a native **Open [application]?** confirmation naming the requesting site. **Open** sends the full callback to the installed macOS application; **Cancel** keeps the page open. Confirmation is required each time. If no application handles the link, the status bar explains why it could not be opened.

Pinned tabs remember the page they were pinned on and keep a name you give them until they are unpinned. Closing a pinned tab (**⌘ W**) keeps it pinned, unloads it and returns it to that page, as in Arc.

Links opened from other apps reuse a pinned tab for that page or a path below it, switching to its Space and keeping its session. For example, a pin for `https://github.com/acme/repo` also opens links to that repository's issues. The most specific pinned path wins; equivalent pins prefer the current Space, then the most recently used tab. Space rules take precedence. If no pin matches, the link opens in a new tab or the selected blank tab.

Right-click a link for **Open Link in New Tab**, or an image for **Copy Image** and **Open Image in New Tab**. New tabs open in the background and follow the same Space and session rules as other new-tab links. Copy Image puts the image itself on the macOS clipboard; unavailable images cannot be copied.

The reading list (**⌘ ⇧ L**, or the tray in the rail) belongs to no Space. Press **⌘ V** there to save the link on your clipboard, or save the current page with **⌘ ⇧ D**. Saved pages load in the background, using the session of the Space that a rule assigns them to, or otherwise the current Space, and appear as plain articles you can read offline. Long reads resume where you stopped. Opening an item never marks it read: press **E** or use **Mark read**, and press it again to undo. **J** and **K** move through the list. Pages behind a login, or with too little text, open as a tab instead. **Open original** and links in an article follow your pinned tabs and Space rules.

Feeds live in the same list. Use **Manage › Add Feed…** with a feed or site address. Feeds are checked every 30 minutes while the app is open, and a new feed brings only its five newest posts. The list is stored in `reading.json`, with saved articles in `Reading/`.

Spaces organize tabs independently of sessions. A Space's default session applies to new tabs. Its existing tabs keep their current sessions.

A Space can claim links by address pattern, one per line, for example `dev.azure.com/contoso/**` for a Contoso Space and `dev.azure.com/fabrikam/**` for a Fabrikam Space. Patterns match host (with port) and path, ignoring scheme, `www.`, query, fragment and case. `*` matches within one path segment, `**` matches anything; a trailing `/**` also matches the prefix itself. When several patterns match, the most specific wins. Rules apply to links from other apps, links that open a new tab (which then use the target Space's session and lose `window.opener`), and addresses typed into a new blank tab. Navigation inside an existing tab stays where it is.

After **10 minutes** out of selection, a tab's actual CEF browser is closed. The timeout is configurable to 1, 5, 10, 15, 30, or 60 minutes and checked every five seconds. Pinned tabs follow the same rule. The selected tab stays awake. Reopening an unloaded tab creates a new Chromium page at its saved URL.

This releases the page; it does **not** make the entire browser or shared Chromium/profile resources consume zero memory. Only title, URL, pin/session/Space identity are restored. Page JavaScript state, scroll position and unsaved input are not serialized. A page with an unload confirmation can ask to stay open.

## Projects

Each Space has a **home** with one card per project. A project groups a repository, its pipelines, the places it runs (Local, INT, PROD…) and any links you want one click away, such as feature flags or dashboards. Every button opens in its own session; an environment can have **its own isolated profile**, which keeps, for example, a separate PROD login. Opening an environment reuses a tab in this Space that already shows it. A Space still reopens on its last used tab; the home is one click away.

While Projects or Activity is open, Rail checks the Space's projects: local addresses by connecting to their port, remote ones with a request that carries no cookies (every 60 seconds), pipelines and open pull requests every two minutes, and everything on **Check now**. Projects are grouped into Needs attention (an environment that is down or slow, a failed pipeline on the default branch, or a missing sign-in), In progress and All clear; each reads left to right as Local, then Repo → Pipelines → each environment. Activity lists the pull requests you opened in those repositories, grouped into Needs you (failed checks, merge conflicts, a reviewer waiting or rejecting, open threads), Waiting on others and Ready to merge, with each one's checks, Azure DevOps policies and reviewers. Nothing is checked for Spaces you aren't looking at.

**Azure DevOps** needs no setup. Requests run in the session of the project's Repo link and use the login you already have there; the app never reads or stores the cookies. They are limited to read-only Azure DevOps API requests. If that session isn't signed in, the card offers to open Azure DevOps there.

**GitHub** uses a personal GitHub App and its device sign-in. Set it up once:

1. GitHub → Settings → Developer settings → GitHub Apps → New GitHub App. Disable the webhook, select **Enable Device Flow**, and give it read-only repository permissions for **Metadata**, **Actions** and **Pull requests**.
2. Install it on your account and on each organization with **All repositories**, so new repositories are covered without granting access again.
3. Copy its **Client ID** and either build with `./scripts/build.sh -DRAIL_GITHUB_CLIENT_ID=<id>` or run `defaults write de.eimerreis.rail GitHubClientID <id>`.

The first time a card or import needs GitHub, Rail copies a code to the clipboard and opens GitHub's authorization page in that project's session. Tokens are stored in the Keychain (`Rail Connections`) and refreshed automatically; you sign in again only after about six months without use or if you revoke the app.

## Saved data

`~/Library/Application Support/Rail/` contains:

- `state.json`: tabs, Spaces, sessions and preferences; saved atomically.
- `projects.json`: projects, environments, links and provider connections, without any tokens. An unreadable file gets a recovery copy before anything is saved over it.
- `Chromium/`: separate persistent profiles for named and isolated sessions.
- `cef.log`: Chromium warnings/errors.

Startup loads only the selected page. Other tabs remain unloaded until selected. An unreadable layout gets a recovery copy before a fresh layout is saved. Closing a tab removes its entry, not its profile files. Rail does not import or modify your Arc/Chrome profiles.

## Releases

Run `npm ci` to install the Changesets CLI and pre-commit hook. Every change commit needs a new changeset from `npm run changeset`. Merging or pushing the changes and changesets into `main` runs status/version in CI, commits the generated version metadata, and publishes a signed Sparkle update automatically. See [the release workflow](docs/updates.md) for the full sequence and engine-update proposals.

## Verify

```sh
./scripts/build.sh             # Release build, bundle signatures, model + persistence tests
npm test                       # Changesets, commit hooks, versioning, native version propagation and release gating
node scripts/smoke-test.mjs     # Node 22+: actual native app + Chromium integration checks
node scripts/devtools-smoke.mjs # DevTools docking, close button, shortcut/menu toggles and lifecycle
node scripts/context-menu-smoke.mjs # Right-click links/images, background tabs, image clipboard formats
node scripts/find-smoke.mjs     # Live find bar, counts, navigation, wraparound, keyboard, focus and tab isolation
node scripts/projects-smoke.mjs # Projects and Activity, health checks, sign-in states, opening environments
node scripts/external-app-smoke.mjs # Desktop callbacks, confirmation, redirects and actual macOS handoff
node scripts/theme-smoke.mjs    # All three themes: live switching, no stale surfaces, relaunch, fallback; saves screenshots
```

`theme-smoke.mjs` samples pixels with python3 and Pillow. Its full-window screenshots, web content included, need Screen Recording permission for the terminal; without it, it still saves captures of Rail's own views.

`context-menu-smoke.mjs` preserves and restores the clipboard while checking image copying. Set `RAIL_TEST_MOCK_KEYCHAIN=1` to run this check with Chromium's mock Keychain when local Keychain access is unavailable; that mode does not verify real Keychain encryption.

The integration test uses disposable profiles under `.runtime-test`, a localhost fixture, and a development-only control channel. It verifies shared and isolated cookies, popup separation, native CMD+S, pinned-tab destruction/recreation, session switching, clean quit, and persistence across restart. Automation requires an explicit data directory and refuses the normal browser profile. Tests use a separate **Rail Test Safe Storage** Keychain entry, shared across test runs, with real Chromium cookie encryption. The normal browser keeps using **Rail Safe Storage**. Keep the same signing certificate to retain Keychain approvals; a locked login Keychain can still require unlocking. The control channel and remote debugging are enabled only by explicit test arguments.

### H.264 / AAC and YouTube live playback

The official CEF distribution pinned in `cef.lock.json` does not include H.264 or AAC decoding. YouTube live streams that offer only AAC audio cannot play, even when VP9 video is available. Supporting them requires rebuilding the engine with `proprietary_codecs=true ffmpeg_branding=Chrome`; this is a CEF build setting, not a Rail launch flag. See [Google's CEF build instructions](https://support.google.com/webdesigner/answer/10043691?hl=en).

`scripts/build-cef-codecs.sh` prepares a Release engine from the same CEF commit and Chromium tag as Rail's current pin. It verifies the upstream builder's SHA-256, enables the codecs, and builds the matching sandbox library. The source build needs an Apple Silicon Mac with macOS 26.6+, Xcode 27 / macOS SDK 27.0, and a build volume with a budget of at least 150 GiB free. Run the prerequisite check before downloading sources:

```sh
./scripts/build-cef-codecs.sh --check /Volumes/Build/rail-cef
./scripts/build-cef-codecs.sh --plan /Volumes/Build/rail-cef # prints the command; no downloads
./scripts/build-cef-codecs.sh /Volumes/Build/rail-cef
```

The generated minimal distribution is under `/Volumes/Build/rail-cef/chromium/chromium/src/cef/binary_distrib/`. Pass that distribution directory to `./scripts/build.sh -DCEF_ROOT=/absolute/path/to/distribution`. CMake remembers the selection; `./scripts/build.sh -DCEF_ROOT="$PWD/vendor/cef"` switches back to the official engine. The engine builder does not replace `vendor/cef` or the installed app.

After building Rail, `node scripts/media-smoke.mjs` generates an H.264/AAC clip with `ffmpeg` and verifies that both tracks actually decode and play in a disposable profile. It is expected to fail against the default official engine. Set `RAIL_TEST_APP=/absolute/path/to/Rail.app` to test a separate bundle, and optionally `RAIL_TEST_YOUTUBE_URL='https://www.youtube.com/watch?v=YeWPWLqNpqM'` to verify live playback too. A successful full source build and playback run are still required before treating this recipe as verified.

A third-party CEF 154 codec build was checked on 2026-11-01. Rail's current source does not compile against it because it lacks `CefSettings.keychain_service_name` and `keychain_account_name`, which Rail uses for its own cookie-encryption Keychain entry. Keep the current engine until a matching codec-enabled build is available. Codec-enabled builds do not themselves grant a patent licence; the upstream codec licensing terms still apply to distribution.

The C++ model can also be tested without CEF:

```sh
.tools/bin/cmake -S . -B build-model -DRAIL_BUILD_APP=OFF
.tools/bin/cmake --build build-model
.tools/bin/ctest --test-dir build-model --output-on-failure
```

## 1Password

The native command palette uses the official 1Password Go SDK, bundled in a signed helper; no browser extension, `op` CLI, or service-account token is required. In 1Password → Settings → Developer, enable **Integrate with other apps**, then open Rail’s key button and enter your account name or ID. Approve Rail’s helper in the 1Password app. Authorization covers that account and expires when it is locked or after ten minutes of inactivity; see [1Password’s local integration model](https://www.1password.dev/sdks/desktop-app-integrations).

**Search items** searches all active item types across the connected account, independently of the current website. Search names, login usernames, saved websites, vaults, categories or tags. Current-site logins rank first; use ↑/↓ and Return to fill a login or open another item in 1Password. Filling a login on a different site requires confirming the destination. Results are paged in groups of 40; every page participates in search. A two-minute memory index and batched username reads avoid repeated SDK calls; Refresh fetches external changes immediately. No passwords are cached for search.

**Open in 1Password** uses a private item link. The SDK does not expose the account UUID/region needed for that route, so the first use asks you to paste **Copy Private Link** from the selected item in 1Password. Rail remembers only the account routing identifiers. This is separate from sharing an item and does not create a share link.

**New login** generates a password with length and symbol controls, accepts a username and login name, and lets you choose a vault. **Save & fill** saves the item before inserting the username, password, and signup confirmation; **Save only** leaves the page alone. Neither action submits the website’s form. An uncertain save retains the draft and blocks automatic retries to avoid duplicates.

Rail checks the selected tab, URL and document again before filling. The first implementation supports main-document forms on HTTPS and loopback HTTP. It refuses ambiguous forms and forms submitting to another origin. It does not fill iframes, passkeys or OTPs, capture submitted credentials, or update existing items. Rail remembers the account name and optional item-link routing identifiers; credential drafts and the search index live in memory. Disconnect ends the helper process and clears the palette. Search metadata can remain visible while cached; filling always makes a fresh SDK request so locking 1Password still prevents password access.

Run `node scripts/passwords-smoke.mjs` after building. `RAIL_TEST_APP` can point to a separate `.app`. The smoke uses an explicit loopback-only in-memory vault and disposable browser profile, plus the real SDK password generator. It verifies global search, pagination, typing during refresh, private-link routing, cross-site confirmation, filling, signup confirmation, saving, uncertain writes, same-URL reload invalidation, and form isolation. It does **not** establish compatibility with live desktop authorization, opening real items, or real vault writes; those require interactive verification in 1Password.

## First-version limits

- No extension manager, sync, full vault manager, history UI, default-browser registration, or automatic Chromium updater.
- Named-session popups preserve `window.opener` for login flows. Popups from isolated tabs open with a fresh isolated profile; use a named session for login flows requiring a shared opener session.
- Camera/microphone and common website permissions have native prompts. Screen sharing is not implemented. File downloads use a native save panel.
- Chromium's sandbox and web security remain enabled. Invalid certificates and unsupported URL schemes are not bypassed. Desktop app links require confirmation. `file://` addresses and paths such as `~/Source/test.png` open from the address bar or from another local file, never from a web page. DRM compatibility is not implemented.
- Updating Chromium is manual: update the matching version/archive/size/checksum fields in `cef.lock.json` from the [official CEF builds index](https://cef-builds.spotifycdn.com/index.json), then run the build and integration checks again. Old engine versions eventually become unsuitable for daily browsing.

## Source map

- `src/BrowserModel.*` — tab, Space and session state; idle policy.
- `src/Projects.*` — projects, environments, links, connections, repository recognition, attention rules.
- `src/ProjectStatus.mm` — health checks, Azure DevOps through a session, GitHub device sign-in and API.
- `src/ProjectsView.mm` — the Projects page and its project lanes.
- `src/ActivityView.mm` — the Activity page: your pull requests and their checks.
- `src/BrowserController.mm` — native shell and browser lifecycle.
- `src/CEFBridge.mm` — Chromium callbacks, navigation, permissions and downloads.
- `src/PasswordPalette.*`, `src/PasswordService.*` — native 1Password UI and private helper transport.
- `src/CredentialRenderer.*`, `src/CredentialForm.js` — document-bound, main-frame filling.
- `helpers/onepassword/` — pinned official SDK adapter, matching policy and disposable test backend.
- `src/StateStore.mm` — layout persistence and recovery.
- `src/NativeViews.*` — native Rail controls.
- `src/Theme.*` — the three themes as semantic colours, Manrope, and the R mark.
- `scripts/make-rail-icon.swift` — draws the R as vectors and writes `resources/AppIcon.icns` and `resources/RailMark.pdf`.
- `design/rail-reference.html` — the selected interactive design reference.
- `docs/plans/2026-10-29-native-browser.md` — implementation decisions.

CEF's license and third-party credits are included in the app's Resources directory. Manrope is bundled under the SIL Open Font License (`Resources/Fonts/Manrope-OFL.txt`) and registered for Rail only at launch; nothing is installed. Without it, Rail falls back to the system font.

## License

MIT. See [LICENSE](LICENSE). Bootstrap downloads CEF and Chromium separately; they keep their own licenses.
