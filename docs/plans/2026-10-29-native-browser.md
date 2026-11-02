# Rail native browser

The approved direction is Rail in light mode: a 45-point Spaces rail, a compact 210-point tab sidebar, pinned shortcuts, and a native toolbar. The user authorized implementation in this repository.

## Design

Use AppKit in Objective-C++ with the current stable CEF binary distribution for Apple Silicon. This keeps the entire shell native and allows direct, typed integration with CEF without a second language bridge. The deployment target is macOS 13 or newer. CEF's Chromium subprocess sandbox stays enabled.

- `BrowserModel`: platform-independent C++ state and transitions for tabs, Spaces, named sessions, and per-tab isolated sessions. Pure state is unit-tested.
- `BrowserController`: native window, menus, rail/sidebar, toolbar, settings, persistence, and idle timer. UI callbacks only operate on the main thread.
- `CEFBridge`: CEF client and application callbacks, per-tab instances, shared request contexts for named sessions, unique persistent request contexts for isolated tabs, popups, permissions, downloads, and lifecycle.
- Data lives in `~/Library/Application Support/Rail`. App metadata is saved atomically; Chromium owns its profile storage. Only the selected tab is restored eagerly.

An unused tab closes its CEF browser instance after the configured interval (ten minutes by default); the tab entry persists and reopens at its saved URL. The selected tab is never unloaded. Pinned tabs follow the same timeout. Browser resources close asynchronously; stale callbacks must not attach content to a newer incarnation of the tab. Shared Chromium processes, profile caches, and tab metadata still use memory.

Changing a tab's session closes its old browser and recreates it at the same URL in the selected context. Spaces and sessions are independent. Named sessions share cookies. Each isolated tab uses its own stable profile directory. All tabs initially use the selected Space's default named session. Tabs can be pinned, closed, moved between Spaces, or reopened from the persisted layout. New tabs open a native empty state until a URL is entered.

Navigation uses Chromium's renderer sandbox and web security defaults. Remote pages have no application or filesystem bridge. Permission requests are presented with the requesting origin and default to denial; invalid certificates are not bypassed. Unsupported external protocols are denied. No extension compatibility is claimed.

## Implementation plan

1. Bootstrap a pinned, checksum-verified CEF binary and local build tools. Build and bundle the framework, sandbox helpers, and app using CMake.
2. Write failing focused model tests, then implement tab/session/Space transitions, inactive-time boundaries, and state validation.
3. Implement the native Rail light shell, persistence, URL/search handling, keyboard shortcuts, and browser integration.
4. Verify unit tests, a release app build, real CEF navigation/session isolation and unload/reopen behavior, and a native UI capture where available.
5. Document build/run/update commands and the practical limitations of the first version.

## Scope rulings

- Proceed from the approved mockup and implementation request; no additional design approval is needed.
- Use direct CMake/CTest commands because the optional Superlite writing-plans and runner scripts referenced by local skills are not installed.
- Core domain work can run in a parallel agent as directed by the architectural brainstorming skill; runtime and UI integration remain in the main task.
- No cloud sync, extension system, account service, installer, or distribution pipeline is needed for personal use.

## Verified implementation

- AppKit/Objective-C++ shell and sandboxed CEF 156 release app build on Apple Silicon.
- 16 model cases plus the Foundation persistence suite pass through CTest; model cases also passed address/undefined-behavior sanitizers.
- 14 real Chromium integration checks cover session cookies, per-tab isolation, popup isolation, native CMD+S routing, pinned idle page destruction, wake/reload, session replacement, background close, clean shutdown, and login/layout persistence after restart.
- Native view capture was inspected. Panel painting is bounded to prevent a status bar from covering sibling views on modern AppKit.
- CEF's framework packaging now replaces its generated copy before relinking, avoiding broken directory symlinks on repeated builds.
- Persistent cookie loading initially blocked on Keychain access after ad-hoc signatures changed. The app now has an Rail-specific Keychain service and this workspace uses an existing personal signing identity. A subsequent rebuild and integration run passed with real Keychain encryption.
- Profile paths use the filesystem's canonical casing: Chromium compares the parent path literally on macOS.
- Named-session popups retain opener behavior; isolated popups receive a fresh profile. App-held request contexts are released after their final live tab closes.
