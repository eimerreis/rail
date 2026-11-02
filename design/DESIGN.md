---
name: Personal browser — Rail light
description: Selected light-mode Rail shell with retained Native and Focus comparison concepts.
colors:
  preview-ink: "#262b30"
  preview-muted: "#636c75"
  paper: "#fff"
  preview-hover: "#edf0f3"
  preview-border: "#d7dce1"
  focus-ring: "#3976be"
  native-shell: "#edf0f3"
  native-sidebar: "#e9edf1"
  native-ink: "#29333e"
  native-muted: "#5d6978"
  native-line: "#d2dae2"
  native-selected: "#d2e2f5"
  native-accent-ink: "#245eaa"
  native-hover: "#dfe5ec"
  rail-shell: "#f4f6f8"
  rail-sidebar: "#edf1f5"
  rail-ink: "#273445"
  rail-muted: "#596879"
  rail-line: "#d4dde5"
  rail-selected: "#d8e7f7"
  rail-accent-ink: "#245b96"
  rail-hover: "#e2e8ef"
  rail-track: "#e2e8ef"
  rail-pin: "#f8fafc"
  rail-pin-hover: "#e2ebf5"
  rail-pin-selected: "#d4e4f6"
  focus-shell: "#e1e9e2"
  focus-sidebar: "#f0f4ee"
  focus-ink: "#36483e"
  focus-muted: "#58675d"
  focus-line: "#c9d5cb"
  focus-selected: "#d7e5d8"
  focus-accent-ink: "#385f43"
  focus-hover: "#e2ebe1"
  work-marker: "#dce7f5"
  work-marker-ink: "#35618e"
  personal-marker: "#e0ebe2"
  personal-marker-ink: "#476e4f"
  isolated-marker: "#eee1d4"
  isolated-marker-ink: "#8b6035"
  rail-work-marker: "#dae6f4"
  rail-work-marker-ink: "#3c5f88"
  rail-personal-marker: "#deebdf"
  rail-personal-marker-ink: "#476d4e"
  rail-isolated-marker: "#eee2d5"
  rail-isolated-marker-ink: "#7a5838"
typography:
  ui-title:
    fontFamily: "-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif"
    fontSize: "14px"
    fontWeight: 650
  ui-body:
    fontFamily: "-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif"
    fontSize: "12px"
    fontWeight: 400
  ui-compact:
    fontFamily: "-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif"
    fontSize: "11px"
    fontWeight: 400
  ui-section:
    fontFamily: "-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif"
    fontSize: "10px"
    fontWeight: 600
  ui-meta:
    fontFamily: "-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif"
    fontSize: "10px"
    fontWeight: 400
  session-marker:
    fontFamily: "-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif"
    fontSize: "9px"
    fontWeight: 650
  sample-headline:
    fontFamily: "Georgia,\"Times New Roman\",serif"
    fontSize: "40px"
    fontWeight: 400
    lineHeight: 1.12
    letterSpacing: "-1.2px"
  sample-body:
    fontFamily: "Georgia,serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.85
rounded:
  marker: "4px"
  small-action: "5px"
  control: "6px"
  row: "7px"
  segment: "8px"
  popover: "10px"
  drawer: "12px"
  window: "13px"
spacing:
  4: "4px"
  6: "6px"
  7: "7px"
  8: "8px"
  9: "9px"
  10: "10px"
  12: "12px"
  15: "15px"
components:
  small-action-native:
    backgroundColor: "{colors.native-selected}"
    textColor: "{colors.native-accent-ink}"
    typography: "{typography.ui-meta}"
    rounded: "{rounded.small-action}"
    padding: "7px 9px"
  tab-selected-native:
    backgroundColor: "{colors.native-selected}"
    textColor: "{colors.native-accent-ink}"
    rounded: "{rounded.row}"
  pin-tile-rail:
    backgroundColor: "{colors.rail-pin}"
    textColor: "{colors.rail-ink}"
    typography: "{typography.ui-meta}"
    rounded: "{rounded.control}"
    padding: "0 8px"
    height: "36px"
  space-selected-focus:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.focus-accent-ink}"
    typography: "{typography.ui-compact}"
    rounded: "{rounded.control}"
    padding: "0 5px"
    height: "27px"
  session-marker-work:
    backgroundColor: "{colors.work-marker}"
    textColor: "{colors.work-marker-ink}"
    typography: "{typography.session-marker}"
    rounded: "{rounded.marker}"
    padding: "0 4px"
    height: "17px"
  popover-native:
    backgroundColor: "{colors.native-sidebar}"
    textColor: "{colors.native-ink}"
    typography: "{typography.ui-body}"
    rounded: "{rounded.popover}"
    padding: "7px"
    width: "263px"
  sample-tab-input:
    backgroundColor: "{colors.paper}"
    typography: "{typography.ui-body}"
    rounded: "{rounded.control}"
    padding: "9px"
    width: "100%"
---

# Design System: Rail light

## Current shell: rounded R, Manrope, three themes — implemented 2026-10-30

This section supersedes the light-only tokens and rules further down, which remain as the record of the earlier Rail light shell and its comparison concepts. The contract was the [branding handover](../docs/handoff/rail-branding/HANDOVER.md).

- **Mark.** The approved rounded R (`icon/rail-r-variants/rail-r-02-rounded.png`), cream `#FEEFD7` on a near-black `#050505` tile, unchanged in every theme. `scripts/make-rail-icon.swift` redraws it as vectors (`icon/rail-r/` holds previews and a fidelity overlay) and writes `resources/AppIcon.icns` and `resources/RailMark.pdf`. The tile sits at the top of the Spaces rail, level with the **Rail** wordmark (Manrope 700) in the sidebar; the Space name follows below.
- **Type.** Manrope, bundled, for Rail-drawn UI: 450 body, 530 medium, 600 labels and selection, 700 page titles and the wordmark; tabular figures for counts, ages and sizes. Native menus and platform controls (segmented controls, pop-ups, text fields) keep the system font. Sizes are unchanged from the previous shell and scale with Small / Normal / Large.
- **Themes.** Settings → Appearance → Theme, saved as `theme` in `state.json` (`porcelain`, `nightline`, `daylight`; anything else reads as Porcelain). Every colour is a semantic role in `src/Theme.mm` (`RailRole`): surfaces (rail, shell, sidebar, content, raised, sunken), text, lines, hover/pressed/selected/focus, field, the current Space tile, pins, project states (ink, fill and dot per state) and session markers. Text pairs meet 4.5:1; state dots and focus rings 3:1.

| Role | Porcelain | Nightline | Daylight |
| --- | --- | --- | --- |
| Rail / shell / sidebar | `#E3DDD2` / `#EEEAE2` / `#E8E3D9` | `#0F2427` / `#122A2D` / `#173237` | `#D5E3EE` / `#E5EEF5` / `#DCE8F1` |
| Built-in page / raised | `#FAF8F2` / `#FFFDF9` | `#1D3A3D` / `#224344` | `#FCFDFE` / `#FFFFFF` |
| Ink / muted | `#292D29` / `#575B52` | `#F5EBD7` / `#A6BAB2` | `#243B50` / `#4A6172` |
| Accent and focus / selected fill | `#526A54` / `#DCE5D7` | `#A8CABB` / `#315950` | `#2C6184` / `#CADFED` |
| Current Space tile / its icon | `#526A54` / `#F7F1E3` | `#F5EBD7` / `#173237` | `#C2654A` / `#FFF6EC` |

Daylight's coral is darkened slightly from the mock-up's `#C76B50` so the tile reaches 3:1 against the rail. The coral appears only on the current Space and the short bar beside it at the rail's edge; all themes use that bar.

- **Native appearance.** Nightline gives Rail's windows, sheets and popovers the dark system appearance; the light themes use Aqua. Only Rail's windows are set, so web pages keep following macOS for `prefers-color-scheme`, as before.
- **Kept fixed.** Provider badges (GitHub, Azure DevOps), reviewer avatars and the Settings category tiles are identity colours and look the same in every theme. The page area behind a loading website stays white.

The rules below that say "light mode" or forbid dark mode applied to the earlier shell; Nightline is now a user-selected theme.

## Overview

**Creative North Star: "Rail in light mode"**

This file records the current `mockups.html` implementation. Rail in light mode is the user-selected direction. Native and Focus remain comparison references. No product name is approved. The deliverable is interactive HTML representing a native macOS application, not an implemented browser.

All three share system typography, thin dividers, rounded list controls, authored SVG icons, and macOS traffic-light affordances. Native integrates navigation into a cool silver shell; Rail separates compact navigation from a silver Spaces strip; Focus floats a light eucalyptus drawer above a stable page.

**Key Characteristics:**
- A selected Rail light baseline with shared sample content and two reference alternatives.
- Selection, sleeping state, and session identity remain distinguishable.
- Native window conventions with local, compact menus.

## Colors

The frontmatter records the exact source CSS values. Variant prefixes separate the selected Rail palette from the comparison references; `paper` is the shared page surface.

### Primary

Native pairs blue selection text with pale blue selection fill. Rail pairs dark blue text with pale blue selection. Focus pairs dark green text with pale eucalyptus selection. These are alternative treatments, not three accents to combine.

### Secondary

Work, Personal, and Isolated session markers use blue, green, and warm brown pairs. Rail uses dark session text on pale blue, green, and brown marker surfaces. Letters and menu labels identify each session alongside color.

### Neutral

Each variant has shell, sidebar, ink, muted text, divider, and hover tokens. The external comparison controls use the `preview-*` tokens. Focus's actual drawer overlays its sidebar tone at partial opacity; the exact material is recorded in the sidecar.

**The Explicit State Rule.** Use selected fill and accent text for the current tab, a moon for sleeping tabs, and a letter or labeled menu for session identity. Color alone does not carry these states.

## Typography

The shell uses the macOS system stack in the frontmatter. Body controls use `ui-body`; compact Rail tab text uses `ui-compact`; space titles use `ui-title` (Rail reduces these to 13px). Section labels use `ui-section` (Rail reduces to 9px). Session badges use `session-marker`. Selected tab titles increase to weight 550. Wide Native and Focus tab labels increase to 13px.

The sample webpage uses Georgia: its headline scales from 34px at narrow widths through the recorded default to 47px at wide widths. Article body copy grows from the recorded default to 15px. These webpage values support comparison only.

**The Shell and Content Rule.** Keep system typography in browser controls. The serif article is fictional webpage content, not browser branding.

## Layout

The comparison canvas is at most 1400px wide. The window has a 640px minimum width, 690px default height, 770px height from a 1100px viewport, and 650px height at or below 640px. Below its minimum width, the stage scrolls horizontally rather than inventing a mobile browser shell. At 740px and below, toolbar spacing tightens and secondary page navigation is reduced.

| Proposal | Navigation structure | Hide behavior |
| --- | --- | --- |
| Native | 224px integrated sidebar; pinned rows above tabs; Spaces at the bottom | Sidebar collapses and page expands |
| Rail | 45px Spaces strip plus 210px compact sidebar; two-column pinned shelf | Both navigation regions disappear and page expands |
| Rail, Reading open | 45px Spaces strip plus a sidebar of at least 292px; article column 636px | As Rail |
| Focus | 236px floating sidebar, 11px from the left, 60px from the top, 35px from the bottom; Spaces above tabs | Drawer translates left by 265px; page position stays fixed |

The toolbar is 51px tall and status bar 25px. Default tab rows have a 35px minimum height; Rail uses 32px. Small controls use the local spacing steps recorded above; there is no uniform global spacing multiple. The sample article has a bounded reading column independent of navigation.

## Elevation & Depth

Borders and tonal layers establish the normal shell hierarchy. Soft shadows lift the entire preview window, popovers, and Focus's floating drawer. Focus alone adds a 16px backdrop blur to the drawer. Shadows, blur, focus outlines, and motion values live in `.impeccable/design.json` because they are outside the frontmatter schema.

Sidebar width and translation animate over 220ms with `cubic-bezier(.16,1,.3,1)`; opacity uses 160ms. The simulated loading bar uses 650ms. The reduced-motion media query disables all animation and transitions.

## Shapes

Rounded rectangles scale with purpose: tiny session markers, compact controls, rows, popovers, drawer, and outer window use the named radius tokens. Traffic lights and session dots are circular. Shell edges and dividers use one-pixel borders. SVG icons use round line caps and joins with a 1.65 stroke width; typical toolbar icons are 17px.

## Components

- **Tab rows:** bounded, single-line titles with ellipsis; a tinted selected row; sleeping tabs retain titles and a moon indicator. Pin controls appear on hover or keyboard focus. Native and Focus use rows for pinned tabs; Rail uses a compact two-column shelf.
- **Spaces navigation:** Native uses compact bottom buttons, Rail a dedicated icon strip, Focus a top segmented control. Selected states use each variant's palette; Focus selects with a white segment and light shadow.
- **Session markers and menu:** W, P, and I badges connect to a labeled menu with Work, Personal, and Isolated choices. Reusable sessions are separate from Spaces; the isolated option belongs to one tab. The current menu item has a checkmark.
- **Actions and fields:** compact tinted actions and rounded inputs. App buttons use a two-pixel focus outline in their variant accent, inset by a negative two-pixel offset; inputs retain the shared ring and three-pixel offset. Hover uses the variant hover tone; pressed app buttons darken with `brightness(.94)`.
- **Popovers:** compact sidebar-colored containers with a border and soft shadow. The session menu is 263px wide; idle settings are 277px; the new-tab form is 310px. The idle selector offers 1, 5, 10, 15, 30, and 60 minutes, with 10 selected initially. Unloading is a manual demonstration in this artifact.
- **Reading:** a rail entry below the Spaces with a blue unread badge, because unread is not an alert. Its sidebar holds a white paste field with a 1px `rail-line` border, Inbox and Read segments, item rows with a letter tile or favicon, and feeds at the bottom. The reader sets article text in Georgia (36px title, 17px body at 27.5px line height) in a 636px column, under a 48px action bar. Pages it cannot read say why in the row and open as a tab.
- **Sidebar controls:** visible buttons and Command-S toggle navigation in all proposals. Hidden sidebars become inert. Escape closes menus. Traffic lights are visual affordances only.

## Do's and Don'ts

### Do:
- Do preserve the selected Rail light palette, separate Spaces strip, and compact navigation structure.
- Do keep keyboard focus visible, session choices labeled, and sleeping tabs selectable.
- Do preserve the reduced-motion override for sidebar and loading animation.

### Don't:
- Don't add themes or change the default without user direction; the three themes above were selected by the user.
- Don't promote the sample article’s typography or fictional brand into the browser shell.
- Don't imply that this HTML simulates real websites, persistent browser sessions, or measured memory savings.
