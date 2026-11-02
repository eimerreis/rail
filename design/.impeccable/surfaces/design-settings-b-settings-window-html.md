---
version: 1
slug: "design-settings-b-settings-window-html"
primary_target: "design/settings/b-settings-window.html"
related_targets: ["design/settings/a-sidebar-settings.html","design/settings/c-command-sheet.html"]
---

# Settings

Mode: Operate. One developer changes a preference or manages Spaces, sessions, link rules and project connections, then gets back to work.

## Scope (confirmed 2026-10-30)
- Owns app preferences and management: Appearance (interface size, sidebar animation), Tabs (idle unloading), Developer (DevTools docked or window), Default browser, Spaces (name, icon, default session, link rules), Sessions, Link rules, Projects, Connections.
- Sidebar animation offers Off / Subtle / Full. macOS Reduce motion still forces Off and the window says so.
- Changes apply immediately; there is no Save button.

## Decisions
- Chosen 2026-10-30: Variant B, a separate macOS Settings window (`design/settings/b-settings-window.html`). Not chosen: A (settings in the sidebar) and C (search-first sheet); C's per-setting search can return as the window's search field.

## Direction contract
THESIS: Settings is an ordinary macOS Settings window, opened with ⌘ , or the rail's settings button. It refuses the browser-tab settings page and the popover: everything, including managing Spaces and sessions, lives in one window you can leave open beside the browser.
OWN-WORLD: Rail light. Sidebar #edf1f5 with tinted 20px category tiles in the shell's slate, blue, ink, teal, green, brown and violet; selected category #4173aa with white text. Pane ground #f7f9fb, white inset groups with a 1px #d4dde5 border and 10px radius. W/P/I session markers wherever a session is named. Native AppKit controls only.
STORY: Press ⌘ , , pick a category, change it, and see the browser change behind the window at once.
FIRST VIEWPORT: Traffic lights over the category sidebar with a search field; the pane title beside back/forward arrows; an intro line; an inset list. Spaces shows each Space as a rail-style icon tile with its session marker, rule and tab counts, and expands in place to edit name, icon, session and link rules.
FORM: macOS Settings window, two-pane source list, seed: none (variant chosen from the dealt surface round).
FINISH: native build, smoke-tested through automation; DESIGN.md unchanged (extension of the Rail light world).

## Open
- Reordering and deleting Spaces and sessions are not in the model yet; the window does not offer them.
