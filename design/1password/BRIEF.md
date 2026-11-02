# 1Password in Rail — interaction mockups

Status: C selected by the user. Native SDK implementation adds filling, password generation, and saving during signup. The three original screenshots below remain historical comparison artifacts.

Later user decision: search now covers all active item types across the connected account, independently of the current site. Site matches rank first; cross-site login filling requires a destination confirmation. Other items open in 1Password after one-time private-link routing setup. Batched username reads and a two-minute memory index replace per-item lookups on every open. The original alternative/shared-state descriptions below are historical; [the current handoff](../../docs/handoff/2026-10-30-1password-command-palette.md) and [search captures](search/PROVENANCE.md) supersede their site-only search scope.

## Job and scope

Help Rail's user select the right saved login and fill the current website without leaving their browsing flow. Use the official 1Password SDK with desktop-app authorization, a bundled helper, and native Rail UI. Keep CEF Alloy and the current AppKit shell.

These are desktop screenshot mockups, not functional browser controls. All Forge websites, credentials and vault assignments are synthetic. The three mockups show the same authorized, two-matching-logins state. Authorization remains in the real 1Password app; these concepts do not imitate its security prompt.

## Visual authority

Operate mode. Inherit the current Porcelain theme, rounded R and Manrope from `design/DESIGN.md`'s current-shell section and `src/Theme.mm`. The earlier cool-blue HTML examples and older DESIGN frontmatter are historical, not the current color authority. The native screenshot in `.runtime-test/themes-2026-10-30T10-50-57-539Z/porcelain-projects-views.png` supplies shell proportions, and `design/themes/rail-r/rail-01-porcelain.png` confirms the approved identity. Black capture artifacts in the former are not design intent.

## Alternatives

### A — Toolbar popover

A persistent key button opens a compact native picker anchored to the toolbar. The current destination stays visible above two matching logins. Select an item, then Fill login; double-click or Return can provide the expert path. Search filters only matching items in the first version. The host remains visible even when searching.

Best first implementation: a stable native anchor, clear separation from website content, no dependency on field-relative positioning. It requires a deliberate trip to the toolbar.

### B — Inline suggestion

An explicit key affordance at the focused username field opens a compact picker adjacent to that field. Selecting a row fills the login. Keep the toolbar button as a reliable fallback. Reposition for scrolling, zoom and narrow pages; dismiss immediately on frame navigation or focus leaving the eligible form.

Fastest during a login task, but carries the greatest positioning and field-detection cost. Native overlays must track CEF coordinates; no general credential or SDK bridge is exposed to web content.

### C — Keyboard picker

A browser-owned command picker opens over the content with a dedicated shortcut and a toolbar entry. Search has focus. The current website is fixed context; the two matches are navigable with arrow keys and Return. Escape closes the picker and returns focus to the page. The shortcut is provisional and must be checked against Rail and 1Password shortcuts before implementation.

Best for keyboard use and longer lists. It takes more space and interrupts the page more than A. The screenshot's keyboard glyphs describe navigation inside the picker, not a proposed global shortcut.

## Shared states and behavior

- Disconnected: Settings → Connections → 1Password → Connect. Explain the required SDK integration setting in the desktop app. Choose an account there or in Rail's connection setup; never ask for a master password in Rail.
- Authorizing: keep the destination visible, show “Approve access in 1Password,” allow cancellation, and read results only after success. Do not promise Touch ID on every fill; the desktop app controls authorization sessions.
- Loading: keep the popover/picker stable with simple placeholder rows. Never display stale credentials while loading a different destination.
- Ready: title, username and vault name disambiguate matching items; secrets stay concealed. First version fills username and password without submitting the form. OTP filling is a follow-up action when the page asks for it.
- No match: “No matching logins” with New login, Open 1Password and Refresh actions. Search stays restricted to this website.
- Failure or cancellation: explain what happened and offer Retry or Connect as appropriate; never include raw SDK output or secret fields.
- Navigated, tab switched or profile changed: invalidate the pending fill and require another explicit action. Revalidate the destination and document immediately before filling.
- Keyboard and accessibility: descriptive accessible names, visible focus, arrow navigation, Return to fill, Escape to dismiss, and a clear announcement after filling.
- Confirmation: briefly show “Login filled” in the browser-owned picker/status area, then return focus to the page. Do not claim sign-in succeeded.
- Themes: screenshots use Porcelain for a controlled comparison. The selected implementation must also use the existing Nightline and Daylight semantic roles.

## SDK implementation and live validation

The implementation and test evidence are recorded in [the SDK plan](../../docs/plans/2026-10-30-1password-sdk.md) and [handoff](../../docs/handoff/2026-10-30-1password-command-palette.md). Native filling, generation, save-before-fill and save-only run through the bundled official SDK helper. The current destination and renderer document are checked before filling; no credential bridge is exposed to JavaScript.

An uncertain write freezes the original draft and keeps its warning. Retry save requires an explicit confirmation that the user checked 1Password and the item is missing. Clicking the active New login view preserves typed edits. Results expose title, username, vault and selection accessibly; status changes are announced. Successful filling dismisses the palette and restores page focus. No action submits the website form.

Five CTest suites and the native disposable-vault smoke passed. The SDK generator is exercised directly. Live desktop authorization, actual vault writes, lock/expiry behavior and real VoiceOver sessions remain unverified; no real account was accessed. The final reviewer returned SHIP at the reviewed native UI scope.

SDK desktop authorization can grant temporary account-wide access. Selecting one item in Rail constrains what Rail requests, not the scope of 1Password's authorization grant.

Technical references: [official SDK overview](https://www.1password.dev/sdks), [desktop authorization and autofill metadata](https://www.1password.dev/sdks/concepts), [supported functionality](https://www.1password.dev/sdks/functionality).

## Decision

Selected: C, browser command palette. Open with ⇧ ⌘ P, View → 1Password, or the toolbar key. Search items covers the connected account, ranks site matches first, and offers filling for logins and opening in 1Password for other categories. New login provides title, username, a concealed editable password, SDK generation (8–100 characters and symbols), and a vault picker. Save & fill creates the item first; Save only leaves the page untouched. A failed or uncertain save retains the draft and does not automatically retry. Navigation invalidates filling.


## Direction contract

THESIS: The browser owns a focused, keyboard-accessible credential palette. Existing login and account creation are two views of the same task.

OWN-WORLD: Extend the current native Rail shell, Manrope, semantic theme roles and native form controls; preserve Porcelain, Nightline and Daylight.

STORY: Recognize the destination, choose a matching login or create one, save a generated password before filling, then finish on the website.

FIRST VIEWPORT: A 560 × 590 point child panel has 1Password and destination above Fill login / New login. The fill view focuses search and shows title, username and vault. Creation places named fields, concealed password and generator controls above the vault picker and Save & fill. Footer explains the result and provides Disconnect.

FORM: The user selected C from the three supplied interaction alternatives; no new visual-world roll. The original C screenshot is a critique reference for interaction hierarchy.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
