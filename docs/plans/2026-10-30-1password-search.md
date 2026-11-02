# Faster account-wide 1Password search

User requested faster searching independently of the current website, then selected all item types with non-login items opening in 1Password.

## Diagnosis and change

The old list path scanned each vault and separately resolved every matched login's username, on every palette opening. Typing filtered locally, but could only reach the first 80 site-matching records. In the controlled 24-login fixture, a 5 ms delay per SDK operation produced 26 calls and roughly 150–180 ms on both cold and repeated opens.

The new helper builds an account-wide index from active item overviews and batches username references in groups of at most 100, without fetching passwords. That same fixture now uses 3 calls / roughly 17–18 ms cold and 0 calls / under 1 ms warm. These are simulated round-trip measurements, not live-account performance claims. First connection still needs SDK initialization, authorization and an initial account scan; large accounts and expired indexes still incur that scan.

The index is reused for two minutes and invalidated by explicit Refresh, account switching, access errors and writes, including uncertain writes. Queries match names, login usernames, saved URLs, vaults, categories and tags. Current-site matches rank first. Filtering happens before the 40-item response limit; previous/next controls expose all results. Native query changes are coalesced for 75 ms, remain editable during loading, and discard outdated responses.

## Filling and opening

Login selection makes a fresh SDK read and revalidates the saved site. A non-matching selection shows saved websites and the exact destination origin, with Cancel as the default. Its explicit override bypasses only site matching. HTTPS/loopback, navigation/document identity, main-frame isolation and form-action checks are unchanged.

Other categories are searched using overview metadata only; notes, card numbers, keys and other secret contents are not fetched. Return opens the selected item in 1Password. Because SDK 0.4.1 does not expose account UUID/region, the first open asks for Copy Private Link on the selected item. The helper validates the link's host, account routing and exact item/vault identifiers and returns an app URL. Only account UUID and region hostname are persisted for reuse; no share is created. The private-link route follows [1Password's staff guidance](https://www.1password.community/1password-at-home-31/programmatically-open-desktop-app-to-specific-item-using-uuid-8104). Real-item routing remains an interactive verification step.

Metadata and login usernames remain in process memory and can be visible while cached even if 1Password locks. Secrets are never cached for search, and fresh SDK reads enforce authorization at fill time. Disconnect destroys the helper and clears the palette's data and drafts. No new network listener, clipboard access, CLI dependency or credential file was introduced.

## Verification

Go regression tests cover SDK call counts, search beyond old limits, all active categories, metadata terms, site ranking, pagination, TTL/refresh/account invalidation, uncertain writes, non-login field isolation, explicit cross-site scope and private-link validation. Native smoke coverage includes pagination, rapid edits during delayed refresh, non-login link setup/routing without launching real 1Password, cross-site cancellation and fill, plus the existing signup/save/navigation/form suite.

Live-account timing, live app-item routing and VoiceOver remain unverified; the automated fixtures access no real vault.

Final verification: `./scripts/build.sh` passed all five CTest suites; `codesign --verify --deep --strict build/Release/Rail.app` passed. `node scripts/passwords-smoke.mjs` passed in `.runtime-test/passwords-uB7fHE`, including search from the home page and clearing metadata on disconnect. [Native search captures](../../design/1password/search/PROVENANCE.md) record the final UI. An earlier retry was needed for a Chromium fixture startup timeout before any password scenario; no password-test failure was ignored.
