# Initial background media

New background tabs may load documents, scripts, cookies and images normally. Their initial media loads wait until the page is shown. Switching away after starting playback does not impose a new Rail pause/mute policy. Background playlists and named/isolated session behavior are unchanged. Existing idle unloading still closes inactive pages after the configured timeout.

## Engine policy, checked against the current pin

`cef.lock.json` pins CEF **156.0.15 / cf671c0**, Chromium **156.0.8078.80**. Only upstream source/headers were inspected; no engine download was needed.

- [`CefBrowserHost::WasHidden`](https://github.com/chromiumembedded/cef/blob/cf671c0/include/cef_browser.h) is explicitly **windowless-only**. Rail embeds windowed Alloy views, so calling it is not supported. The pinned browser settings expose no per-browser autoplay/suspend control. Audio muting would hide sound without stopping the video clock.
- The [CEF Chrome renderer client](https://github.com/chromiumembedded/cef/blob/cf671c0/libcef/renderer/chrome/chrome_content_renderer_client_cef.cc) inherits Chromium's media-load policy, including for Alloy pages. [`DeferMediaLoad`](https://github.com/chromium/chromium/blob/156.0.8078.80/components/no_state_prefetch/renderer/no_state_prefetch_utils.cc) defers initial hidden-page media, then resumes when visible. It explicitly allows later background loads after media has played, for playlists. This is separate from the gesture/media-engagement autoplay rules.
- Chromium's [macOS native view](https://github.com/chromium/chromium/blob/156.0.8078.80/content/app_shim_remote_cocoa/web_contents_view_cocoa.mm) translates its own `viewDidHide`, `viewDidUnhide` and window attachment/occlusion changes into WebContents visibility. The [pinned CEF native delegate](https://github.com/chromiumembedded/cef/blob/cf671c0/libcef/browser/native/browser_platform_delegate_native_mac.mm) returns a plain wrapper from `GetWindowHandle`, with Chromium's native view as its child. Hiding only that wrapper/its ancestors failed the real-engine smoke: media advanced while Rail's initial gate was still held. Rail explicitly hides the wrapper's native children and unhides parents before those children, so Chromium receives the actual visibility transition. This uses public AppKit view properties, not private Chromium selectors, JavaScript injection or a DevTools lifecycle freeze.

The Mac CEF delegate creates WebContents with `initially_hidden=false`, even inside a hidden Rail container. Chromium's [`UpdateWebContentsVisibility`](https://github.com/chromium/chromium/blob/156.0.8078.80/content/browser/web_contents/web_contents_impl.cc) ignores hidden/occluded notifications until its first real visible transition. Native smoke confirmed that both ancestor hiding and explicit child hiding alone left `document.visibilityState` visible. In `OnAfterCreated`, Rail therefore primes a visible transition on the **empty host**, then immediately applies the real hidden/selected state before returning. CEF holds a navigation lock during this callback, before the initial URL or the popup's opener script; Rail never yields an event-loop or paint turn during priming.

That browser generation's one-shot view gate opens only for a ready, selected page in the active Rail Space, not behind Home/Reading or during initial close/quit. Empty-host priming does not grant presentation. Each Space's remembered selection alone does not count. After presentation, normal container visibility continues as before; Rail never sends media pause/mute commands. Background/stale/closing focus callbacks are rejected, including navigation-initiated focus.

Middle-click, Command-click, link/image context menus and background popups share this lifecycle. An initially empty background popup retains its background disposition and named-session opener instead of being selected accidentally. Session changes, unloading and restart create fresh browser-generation state; nothing is added to session persistence.

This uses Chromium's HTML audio/video load deferral. It is not a blanket suspension of Web Audio synthesis, WebRTC or other background work; those remain engine-controlled. No site-specific playback script is injected.

## Regression checks

Portable C++ model tests cover selection versus hidden Spaces, covered pages, creation races, one-shot release, close cancellation and fresh browser generations. On Linux, also run:

```sh
node --check scripts/background-media-smoke.mjs
node scripts/background-media-smoke.mjs --check-fixture
```

On an Apple Silicon Mac with a rebuilt Rail and `ffmpeg` (`libvpx` and `libopus`):

```sh
node scripts/background-media-smoke.mjs
# Optional: RAIL_TEST_APP=/path/to/Rail.app RAIL_TEST_MOCK_KEYCHAIN=1
```

The disposable-profile smoke serves `tests/fixtures/background-media.html`, generated PCM audio and VP8/Opus video locally. It first proves active autoplay works, then tests actual middle/Command/context/target/script-popup inputs, main-frame and iframe media, zero initial playback events and clock advancement, background JavaScript loading, activation, continued audible background audio/video and new playlist tracks. It also checks Space routing/session identity, Home/Reading, idle unload, session recreation and restart. The test-only `--autoplay-policy=no-user-gesture-required` prevents an unrelated autoplay rejection from producing a false pass; it does not override hidden-page load deferral. No focus/visibility emulation is used.

## Native verification still required

Linux cannot compile AppKit or execute the pinned macOS CEF engine. The smoke and native integration are **not runtime-verified here**. In particular, verify native visibility delivery before the first frame/media load, initially empty popup disposition under Command-click, rapid select/close during CEF creation, unload-confirmation Stay/Leave, and minimized/hidden windows or another macOS desktop Space. Window occlusion is Chromium/AppKit-owned, not inferred from Rail's active tab ID. Check YouTube manually with the appropriate codec support and an existing logged-in profile; site autoplay preferences and unsupported H.264/AAC live streams are separate from this policy.
