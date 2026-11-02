# 1Password command palette

The user selected **C — Command palette**, then added password generation and saving during signup. The native implementation is complete and built at `build/Release/Rail.app`. Open it with ⇧⌘P or the toolbar key.

The latest update searches all active item types across the account with batched username reads and a two-minute memory index. Current-site logins rank first; other-site filling requires confirmation, and non-login items open in 1Password. [Search captures and provenance](search/PROVENANCE.md) show the updated UI; [implementation notes](../../docs/plans/2026-10-30-1password-search.md) record performance evidence and the one-time private-link setup.

The [native screenshots](native/PROVENANCE.md) cover connection, filling, creation, save-only, uncertain writes and all three themes. Start with [New login](native/new-login.png) and [Fill login](native/fill.png). The [handoff](../../docs/handoff/2026-10-30-1password-command-palette.md) records behavior, verification and remaining live checks.

The original A/B/C artifacts below remain historical static alternatives. All displayed website, login and vault data is synthetic.

| Alternative | Screenshot | Static HTML |
| --- | --- | --- |
| A — Toolbar popover | [PNG](a-toolbar-popover.png) | [HTML](a-toolbar-popover.html) |
| B — Inline suggestion | [PNG](b-inline-suggestion.png) | [HTML](b-inline-suggestion.html) |
| C — Command palette | [PNG](c-keyboard-picker.png) | [HTML](c-keyboard-picker.html) |

Open the [comparison viewer](comparison.html) to compare full windows or inspect each picker. The [brief](BRIEF.md) records the proposed behavior, tradeoffs, shared states and later SDK boundary. The viewer’s original recommendation of A is superseded by the user’s selection of C.

The mockups inherit Rail's current Porcelain palette, rounded R and Manrope from the **Current shell** section of [DESIGN.md](../DESIGN.md) and [Theme.mm](../../src/Theme.mm). The earlier DESIGN frontmatter and cool-blue comparison concepts are historical. Existing compact native shell proportions are retained; this handoff does not revise global design tokens.

Regenerate the HTML from the repository root:

```sh
python3 design/1password/make_mockups.py
```

[make_mockups.py](make_mockups.py) embeds [manrope-ui.woff2](manrope-ui.woff2) and references the local Rail mark. The font subset comes from the bundled [Manrope variable font](../../resources/fonts/Manrope-Variable.ttf), credited to the Manrope Project Authors and distributed under the [SIL Open Font License 1.1](../../resources/fonts/Manrope-OFL.txt). Recreate the subset with:

```sh
uv run --with fonttools --with brotli pyftsubset resources/fonts/Manrope-Variable.ttf --unicodes=U+0020-007E,U+00A0-00FF,U+2013-2014,U+2026 --flavor=woff2 --output-file=design/1password/manrope-ui.woff2
```

PNG capture is separate from HTML generation: each complete HTML document was rendered through HTML preview in light appearance at 1440px width and saved as a **1440 × 900** screenshot. The comparison viewer was checked at **728px** and **390px**, including expanded picker details. Its image paths, and the generated HTML's mark path, refer to this local checkout.

The original HTML/PNG alternatives are static snapshots. The native implementation uses the official SDK in a bundled helper and has passed five CTest suites and the disposable-vault native smoke. The original Impeccable disposition was **SHIP at the reviewed native UI scope**, preceding the all-items search update. Live 1Password approval, real item opening and vault writes, authorization locking/expiry and actual VoiceOver sessions remain unverified.

The original mockup detector findings concerned historical DESIGN frontmatter drift and inherited shell metrics. The native implementation inherits the current system; global PRODUCT/DESIGN/`.impeccable` tokens were not revised for this feature. Native UI was reviewed from composited screenshots, not the HTML detector.
