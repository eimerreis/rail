# 1Password SDK command palette

Approved direction: concept C, browser-owned command palette. User also requested password generation and saving during account creation. This supersedes the mockup brief's first-version exclusion of creation.

The palette has Fill login and New login views. Fill lists matching login titles, usernames and vaults. New login offers title, username, a concealed editable password, Generate again, length and symbol controls, and a vault picker. Save & fill creates the Login item before filling the signup form, including its confirmation password field. Save only also supports retaining a draft without changing the page. Filling never submits the website form or claims the site created the account.

## Components and boundaries

- A bundled Go helper pins the official 1Password SDK v0.4.1 and uses desktop-app authorization. It accepts bounded JSON messages over private stdin/stdout pipes. No TCP listener, CLI subprocess, service-account token, secret command arguments, or credential files. Errors returned to the UI are curated, never raw SDK messages.
- A native service owns helper lifetime and asynchronous requests. Settings remembers only account name/ID. User connects through the palette or Settings → Connections. The 1Password app owns account authorization, Touch ID, expiry and locking.
- The AppKit palette owns the selected tab/document and the in-memory creation draft. It uses current theme roles and Manrope, a toolbar key button and a dedicated keyboard shortcut. Browser navigation or switching tabs invalidates filling. Failed saves retain the draft; uncertain saves do not automatically retry.
- A CEF renderer handler receives narrowly scoped native requests and replies with context/fill results. It validates the current document token and URL before changing eligible visible fields. No API to invoke the helper is exposed to JavaScript. Initial support is main-document forms; embedded cross-origin forms fail explicitly.
- The helper matches saved website metadata before reading credentials, respects Never and ExactDomain, and limits broad matching to the saved host or its child hosts under a registrable domain. It revalidates a selected item's websites when fetching it. Only HTTPS or exact loopback HTTP origins are eligible.
- Generated passwords use the SDK generator. Saving creates a new Login with an exact-domain website and typed username/password fields. It never updates or overwrites an existing item. Generation and save are explicit user actions.

## Verification

1. Test website policy against suffix attacks, port changes, Never, public suffixes and HTTP downgrade.
2. Test SDK adapter behavior using an in-memory backend: list metadata without passwords, refuse changed destinations, typed item creation, save failures, password recipe bounds and generation.
3. Test form detection/filling with disposable browser profiles and local fixtures: normal login, signup confirmation, React-style input events, username-first, hidden fields and stale document rejection.
4. Build native app and bundled signed helper, run existing relevant integration checks, inspect native palette captures, review the security boundary.
5. Real desktop-app authorization and vault writes require the user's interactive 1Password approval. Mock backend smoke tests cannot establish live-vault compatibility; report that distinction.

Out of scope: 1Password-held passkeys, automatic form submission, automatic capture on submit, editing existing items, cross-origin iframe filling and unrestricted vault browsing.

## Implemented and verified

- Native `PasswordPalette` and `PasswordService`, toolbar key, View menu / ⇧⌘P, and Settings connection entry.
- Bundled official Go SDK 0.4.1; bootstrap pins Go 1.27.3 and verifies its archive. Dependency licenses ship in `OnePassword-Notices.txt`.
- Renderer-only IPC handler with document nonce and URL revalidation. No page-callable vault bridge. Eligible main-document forms only.
- Five CTest suites passed, including the helper’s policy, adapter, save-failure and actual SDK generator tests.
- `scripts/passwords-smoke.mjs` passed against the normal `build/Release/Rail.app` with a disposable local fixture backend. It covers existing filling, generated password save-before-fill with confirmation, save-only, uncertain commits without automatic retry, same-URL navigation invalidation, hidden fields, ambiguous forms, cross-origin form actions, username-first and iframe isolation. Native Return-to-fill and ⌘ Return save-and-fill, draft preservation and noncontradictory outcome messages are exercised.
- Final run: `.runtime-test/passwords-hDH1uZ`. Stable screenshots and provenance: `design/1password/native/`. The Impeccable reviewer resolved the final findings and returned **SHIP at the reviewed native UI scope**. Actual VoiceOver behavior remains unverified.
- Live desktop authorization, real vault writes, and authorization expiry / locking are not verified. No real account was accessed.

Desktop authorization semantics: [official local integration security](https://www.1password.dev/sdks/desktop-app-integrations). Typed Login field IDs and autofill behavior: [official SDK concepts](https://www.1password.dev/sdks/concepts).
