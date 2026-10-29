---
version: 1
slug: "design-project-overview-a-space-home-html"
primary_target: "design/project-overview/a-space-home.html"
related_targets: []
---

# Project overview (Space home)

Mode: Operate. One developer checks the health of their projects and jumps into the right environment.

## Decisions
- Chosen 2026-10-29: Variant A, Space home. Each Space has its own home page with one card per project. The Space's sidebar lists those projects with a health dot. User confirmed both the per-Space placement and the card content.
- Card content: name, repo, branch and provider (Azure DevOps or GitHub); what needs attention (alert with a chart marking when it started, failed tests, dead-letter queue, Sentry issues, release waiting for approval); and one button each for Repo, Pipelines, Local, INT/Staging and PROD, showing live state and the session it opens in.
- Not chosen: B (new-tab matrix with a promotion line) and C (rail entry with a 24 h timeline). Their ideas can come back as details, e.g. the version drift between environments.

## Direction contract
THESIS: A Space's home shows its projects as cards. Each card pairs what needs attention with the buttons that open every environment, so finding a problem and opening the right place happen on one card.
OWN-WORLD: Rail light from design/DESIGN.md. Paper page, pale blue selection fill, 1px #d4dde5 borders, 12px card radius, 7px button radius. Red, amber and green only for state. W/I/P session markers on every environment button.
STORY: Open the Space, see which projects are red, read why on the card, and open PROD or the pipeline in the right session with one click.
FIRST VIEWPORT: "Projects" title, a summary line (need attention, running locally, last checked), filter tabs and "Add project". Below, a two-column grid of cards with projects needing attention first. In each card, status on the left and five stacked environment buttons on the right.
FORM: Space home with a project card grid, roll position 6 on the grounded list, seed:c81208749e58aadc.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Open
- Step 2: a project detail page reached from a card.
- How projects, environments and data sources are configured, and how status is fetched across the no-bridge boundary.
- Whether to raise the page's own text to at least 11px.
