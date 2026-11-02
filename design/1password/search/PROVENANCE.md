# Account-wide search captures

Native Rail captures from `.runtime-test/passwords-uB7fHE`, produced by `node scripts/passwords-smoke.mjs` on 2026-10-30 after the final search build. Both images contain only disposable synthetic vault metadata.

- `fill.png`: all-item search with current-site login ranked first, unrelated login and secure note, paging controls and context-dependent actions.
- `cross-site.png`: native confirmation shows the actual destination and the login’s saved site.

The smoke uses a disposable browser profile, in-memory SDK backend, native AppKit controls and real Chromium forms. It does not access a real account. The updated five-suite CTest run and codesign verification passed. Real desktop authorization, real-item app routing and VoiceOver remain interactive checks.
