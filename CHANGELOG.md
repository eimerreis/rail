# rail

## 0.5.3

### Patch Changes

- 2b1ee54: Choose Google, Bing or DuckDuckGo in Settings → Search for address-bar and new-tab searches. Rail remembers the choice across restarts and keeps the existing DuckDuckGo default until you change it.
- b587b82: Closing a tab now returns to the tab that opened it when it is still available in the same Space, with a reliable recently-used fallback. Background tabs keep their source without interrupting the current page; pinned tabs, undo, and closing multiple tabs keep their existing behavior.
- 40afe08: Reorder pinned tabs by dragging them within Pinned. An insertion line shows the new position, and each Space remembers its pinned order across restarts.
- f404789: Keep newly opened background tabs from starting media before they are first shown, including links opened with middle-click, Command-click or the context menu. Existing playback can continue when switching tabs or Spaces.

## 0.5.2

### Patch Changes

- 067db7a: Keep Rail's build dependencies and release tooling up to date with Dependabot.

## 0.5.1

### Patch Changes

- a048945: Fix the Checks list sitting off-centre in its popover, which left a bare strip along the top and right and cut off its left and bottom edges.

## 0.5.0

### Minor Changes

- 2cfb7ce: Open local files from the address bar with a `file://` address or a path such as `~/Source/test.png`, including ones with spaces.

## 0.4.2

### Patch Changes

- 186d885: Keep unread counts and Retry buttons in the Reading feeds list visible when classic scrollbars are shown.
- 175214c: Run the real-engine smoke tests on every pull request, so failures show up before merging instead of during a release.

## 0.4.1

### Patch Changes

- 86bc503: Keep J and K working in Reading while pages load in the background, including articles being fetched and tabs still starting up.

## 0.4.0

### Minor Changes

- 278bbfa: Activity and Projects now refresh on their own, and a toolbar capsule follows your open pull requests and the pipelines you started, announcing when they pass or fail. Failures stay until you acknowledge them.

## 0.3.0

### Minor Changes

- e932d70: Select several tabs with ⌘ or ⇧ click to close, move or snooze them together, and snooze any unpinned tab until later.

## 0.2.1

### Patch Changes

- 9787d29: Keep J and K working when a tab finishes loading behind Reading, and keep reading list rows clear of classic, always-visible scrollbars.

## 0.2.0

### Minor Changes

- 1632cd9: Add Copy Image, Open Link in New Tab, and Open Image in New Tab to the page context menu. New tabs open in the background and follow Space and session rules.

### Patch Changes

- 1632cd9: Manage Rail releases with Changesets, require a changeset for each change commit, and automatically run status/version and publish signed Sparkle updates when changes reach main.
