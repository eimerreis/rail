# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

<!-- The shell is a native macOS AppKit app around Chromium (CEF). Browser-chrome design work targets macOS conventions; in-page surfaces such as the new-tab page or project overview render as web content inside it. -->

## Users

One developer, the author, using Eimerrail as their personal daily browser on an Apple Silicon Mac. They split their day across Spaces (Work, Personal) and named sessions (Work, Personal, Isolated), and they are often juggling several software projects at once, each with a local dev instance and remote environments such as INT and PROD.

## Product Purpose

Eimerrail is a personal macOS browser with a native AppKit shell and Chromium Embedded Framework: a Spaces rail, vertical tabs, pinned shortcuts, a compact toolbar, reusable named sessions, and idle-tab unloading to keep memory in check. Success is a browser that stays calm and fast while it organizes work by Space and session.

## Positioning

A browser shaped around one developer's own working day rather than a general audience: Spaces and sessions are independent, idle tabs unload on a configurable timer, and (under exploration) a project overview puts every project's environments and health one tab away.

## Operating Context

- Projects live in a mix of Azure DevOps and GitHub. Azure DevOps projects use pipelines and INT/PROD deployments with Azure Monitor / Application Insights alerts; GitHub projects use Actions and their own alerting.
- Each project typically has a repository, pipelines, a local instance (a `localhost` port) and one or more remote environments.
- Tabs from different Spaces and sessions coexist; a Space's default session applies to new tabs.

## Capabilities and Constraints

- Shipped: Spaces rail, vertical tabs, pinned shortcuts, named and isolated sessions, idle unloading (1–60 min), find, history, persistence in `~/Library/Application Support/Eimerrail/`.
- Exploring (not built): a developer project overview showing per-project environment links with health, pipeline status, alerts/telemetry needing attention, and whether local dev servers are running.
- Decided: the overview is a per-Space home with one card per project; each project belongs to exactly one Space. Data model, entry paths and status fetching: `docs/plans/2026-10-29-projects-model.md`.
- Remote pages have no application or filesystem bridge; any overview data source must respect that boundary.
- No extension compatibility is claimed.

## Brand Commitments

- The product name is Eimerrail.
- The Rail light direction is user-selected and binding for the shell (see `design/DESIGN.md`). Do not revert it to dark mode without user direction.

## Evidence on Hand

- `design/DESIGN.md`, `design/rail-reference.html`, `design/native-window.png`: the selected Rail light shell.
- No real project list, endpoints, or telemetry exists yet; any project data in mockups is synthetic and must be labeled as such.

## Product Principles

- Calm by default: show what needs attention, keep everything else quiet.
- One person's workflow over general-audience features.
- Honest state: never imply data, sessions, or savings the app does not actually measure.
- Native first: macOS conventions in the chrome, with keyboard access everywhere.
