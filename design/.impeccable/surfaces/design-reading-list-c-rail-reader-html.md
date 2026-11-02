---
version: 1
slug: "design-reading-list-c-rail-reader-html"
primary_target: "design/reading-list/c-rail-reader.html"
related_targets: ["src/ReadingView.mm"]
---

# Reading list (Rail reader)

Mode: Operate, with the article itself in Read mode. One developer saves links and reads them later, independent of Spaces.

## Decisions
- Chosen 2026-11-02: Variant C, Rail reader. One global list; a Space would mean maintaining N lists.
- Reading happens in a plain reader view. Links open in a tab through the Space rules and pinned tabs.
- Opening an item never marks it read. Marking read is explicit.
- Not chosen: A (toolbar tray) and B (Space digest).

## Direction contract
THESIS: Reading is a place in the browser, not a Space and not a tab. It refuses the bookmarks folder and the feed reader wall of unread items.
OWN-WORLD: Rail light from design/DESIGN.md. Sidebar #edf1f5, selection #d8e7f7 with ink #245b96, 1px #d4dde5 dividers, letter tiles from the session marker tints. Georgia for article text only; system type for chrome.
STORY: Paste a link, see it fill in, read it plain, mark it read when done. Long reads resume where they stopped. Pages that cannot be read plainly say so and open as a tab.
FIRST VIEWPORT: Rail entry with an unread badge. A 292pt sidebar with Reading title, paste field, Inbox and Read segments, the item list, then a Feeds section at the bottom. Page area: action bar with source, Open original and Mark read, then a 636pt article column.
FORM: Rail destination with a reader, position 2 on the grounded list, seed:4ad8aa62.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Open
- Feeds are polled only while the app runs.
