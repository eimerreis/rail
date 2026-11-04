# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

<!-- The shell is a native macOS AppKit app around Chromium (CEF). Browser-chrome design work targets macOS conventions; in-page surfaces such as the new-tab page or project overview render as web content inside it. -->

## Users

One developer, the author, using Rail as their personal daily browser on an Apple Silicon Mac. They split their day across Spaces (Work, Personal) and named sessions (Work, Personal, Isolated), and they are often juggling several software projects at once, each with a local dev instance and remote environments such as INT and PROD.

## Product Purpose

Rail is a personal macOS browser with a native AppKit shell and Chromium Embedded Framework: a Spaces rail, vertical tabs, pinned shortcuts, a compact toolbar, reusable named sessions, and idle-tab unloading to keep memory in check. Success is a browser that stays calm and fast while it organizes work by Space and session.

## Positioning

A browser shaped around one developer's own working day rather than a general audience: Spaces and sessions are independent, idle tabs unload on a configurable timer, and (under exploration) a project overview puts every project's environments and health one tab away.

## Operating Context

- Projects live in a mix of Azure DevOps and GitHub. Azure DevOps projects use pipelines and INT/PROD deployments with Azure Monitor / Application Insights alerts; GitHub projects use Actions and their own alerting.
- Each project typically has a repository, pipelines, a local instance (a `localhost` port) and one or more remote environments.
- Tabs from different Spaces and sessions coexist; a Space's default session applies to new tabs.

## Capabilities and Constraints

- Shipped: Spaces rail, vertical tabs with multi-select and snoozing, pinned shortcuts, named and isolated sessions, idle unloading (1–60 min), find, history, a global reading list with a plain reader view and feeds, persistence in `~/Library/Application Support/Rail/`.
- Exploring (not built): a developer project overview showing per-project environment links with health, pipeline status, alerts/telemetry needing attention, and whether local dev servers are running.
- Decided: the overview is a per-Space home with one card per project; each project belongs to exactly one Space. Data model, entry paths and status fetching: `docs/plans/2026-10-29-projects-model.md`.
- Remote pages have no application or filesystem bridge; any overview data source must respect that boundary.
- No extension compatibility is claimed.

## Brand Commitments

- The product name is Rail.
- The mark is the rounded cream R on a near-black tile, in every theme (selected 2026-10-30).
- The shell offers three user-selected themes: Porcelain (default), Nightline (dark) and Daylight (see `design/DESIGN.md`). Rail-owned UI uses Manrope; web pages keep their own fonts and colours.

## Evidence on Hand

- `design/DESIGN.md`, `design/themes/rail-r/`: the three themes; `design/icon/rail-r-variants/rail-r-02-rounded.png`: the approved R.
- `design/rail-reference.html`, `design/native-window.png`: the earlier Rail light shell, kept for structure.
- No real project list, endpoints, or telemetry exists yet; any project data in mockups is synthetic and must be labeled as such.

## Product Principles

- Calm by default: show what needs attention, keep everything else quiet.
- One person's workflow over general-audience features.
- Honest state: never imply data, sessions, or savings the app does not actually measure.
- Native first: macOS conventions in the chrome, with keyboard access everywhere.
