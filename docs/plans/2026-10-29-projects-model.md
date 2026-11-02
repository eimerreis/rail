# Projects: data model and entry paths

Status: implemented 2026-10-29 (Parts A–C). GitHub needs the GitHub App client ID before its sign-in works. UI direction: `design/project-overview/a-space-home.png` (Variant A, Space home); surface brief in `design/.impeccable/surfaces/`.

## Goal

Each Space has a home page that shows its projects as cards. A card shows the project's environments (Local, INT, PROD, …) with live health, its repo and pipelines, and what needs attention. This document defines what a project is, where it is stored, where its status comes from, and how a project gets onto a Space home.

## Confirmed decisions

| Question | Decision |
| --- | --- |
| Space membership | A project belongs to exactly one Space and can be moved, like a tab. |
| Ways in (v1) | Add project button, add from the current tab, attach a tab to a project, import from a provider. |
| Live status (v1) | Health checks plus pipeline runs and open PRs from Azure DevOps and GitHub. App Insights alerts and Sentry issues come in v2. |
| Provider access | Logins come from the Space's sessions, not from pasted tokens. Azure DevOps calls run inside the project's session, using its existing login. GitHub uses a one-click device sign-in opened in that session. A pasted personal access token stays as a fallback for both. |
| Sessions | Each environment and link opens in a named session or its own persistent isolated profile. |
| Returning to a Space | A Space reopens on its last used tab, not on its home. The home is one click away in the sidebar. |
| Pipeline status on the card | Default branch only. |

## Model

The model is user-defined configuration. Nothing in it is copied from a provider except during import, which is a one-time prefill.

```cpp
struct Project {
    std::string id;                     // "project-<32 hex>", via uniqueID
    std::string name;                   // "Billing API"
    std::string spaceID;                // exactly one Space; its home shows this card
    int order = 0;                      // position on that Space home
    std::vector<Environment> environments;
    std::vector<Link> links;            // Repo, Pipelines, Board, Docs, …
    std::vector<SourceBinding> sources; // where pipeline/PR status comes from
};

struct Environment {
    std::string id;                     // "env-<32 hex>"
    std::string name;                   // "Local", "INT", "Staging", "PROD"; free text
    std::string url;                    // https://billing.contoso.com, http://localhost:5001
    std::string healthPath;             // optional, e.g. "/healthz"; empty = check url itself
    std::string sessionID;              // concrete: a named session ID, or an isolated profile ID
};

struct Link {
    std::string id;                     // "link-<32 hex>"
    std::string kind;                   // "repo" | "pipelines" | "custom"
    std::string label;                  // shown on the card: "Repo", "LaunchDarkly", "Grafana"
    std::string url;
    std::string sessionID;              // same rules as Environment
    std::string environmentID;          // optional: ties a custom link to one environment ("PROD flags")
};

struct SourceBinding {
    std::string connectionID;           // → Connection
    std::string resource;               // GitHub "owner/repo"; Azure DevOps "org/project/repo"
};

struct Connection {                     // one per provider account and session, shared by projects
    std::string id;                     // "connection-<32 hex>"; also the Keychain account name for tokens
    std::string provider;               // "github" | "azureDevOps"
    std::string account;                // Azure DevOps organization, or the GitHub login the token belongs to
    std::string auth;                   // "session" | "deviceToken" | "token"
    std::string sessionID;              // the session whose login this connection uses or was authorized in
};
```

Notes:

- **Local or remote is derived, not stored.** An environment is local when its host is `localhost`, `127.0.0.1`, `::1` or ends in `.localhost`. Local environments get a port check; remote ones get an HTTP check.
- **Environment order** is the vector order and matches the card's button order. Local first, then remotes, is the default when they are created.
- **Custom links** are any URL you want one click away from the card: LaunchDarkly, Grafana, Figma, a runbook. They have no status; they only open. See "Custom links".
- **`sources` is a list** because one project can have a GitHub repo plus an Azure DevOps pipeline. The card's Pipelines status comes from all bindings that support pipelines.
- **Tokens never appear in JSON.** For `deviceToken` and `token` connections the Keychain item has service `Rail Connections`, account = connection ID. A `session` connection has no secret at all.

### Which login a project uses

The project's Repo link decides. Its `sessionID` is the session a project is accessed as. A source binding always points at the connection whose `provider`, `account` and `sessionID` match the repo and that session. This gives the "Work account for Work projects, Personal account for personal projects" behavior without extra settings.

- Azure DevOps: the connection is `auth: "session"`. Requests run in that session and carry its existing dev.azure.com login. The app never reads, copies or stores cookie values; they stay inside CEF.
- GitHub: `api.github.com` does not accept github.com cookies, so the connection is `auth: "deviceToken"`. Signing in uses GitHub's device flow, with the authorization page opened in the project's session (see "Signing in to GitHub").
- Fallback, either provider: `auth: "token"`, a pasted personal access token.
- When the Repo link's session changes, every binding of that project moves to the connection matching the new session. That connection is created if it does not exist; a GitHub one then needs a sign-in.

Connection status is runtime only: `signedIn` (with the account name the provider reports), `signedOut`, or `rejected` (a token that returned 401). A signed-out or rejected connection becomes one attention item on each card that uses it, with a sign-in action.

### Sessions for environments and links

`sessionID` always holds a concrete profile ID, so opening never has to resolve anything:

- A named session (`work`, `personal`, `session-…`).
- `isolated-env-<envID>` (or `isolated-link-<linkID>`): a new persistent profile owned by that environment. This is what PROD uses so its login persists across opens and restarts. The profile directory is `Chromium/isolated-env-<envID>`, like other sessions.
- An adopted `isolated-<tabID>` profile, when a tab with a per-tab isolated session is attached (see "Attach a tab"). The login that tab already has is kept.

Required changes to `BrowserModel`:

- `setSession` and `sanitize` currently accept an isolated session only when it equals `isolated-<tabID>` (`BrowserModel.cpp:232`, `:327`). They must also accept any isolated profile ID that a project environment or link owns. `BrowserModel` gets a set of "owned isolated profiles" from the projects model at load.
- The tab's session marker shows `I` for these profiles too (prefix `isolated-`, already how `isIsolatedSession` works).
- Deleting a project or environment does not delete its profile directory. This is the same rule as closing a tab.

### Live status (memory only, never saved)

```cpp
enum class Health { unknown, up, slow, down, notRunning, loginRequired };

struct EnvironmentStatus { Health health; int latencyMs; std::string version; double checkedAt; std::string error; };
struct PipelineRun { std::string name, number, branch, result /* succeeded|failed|running|canceled */, url; double finishedAt; };
struct SourceStatus { std::vector<PipelineRun> runs; int openPullRequests; double checkedAt; std::string error; };
```

"Needs attention" is computed from these on each refresh, not stored: an environment that is `down`, a failed latest run on the default branch, an environment that is `slow` for two checks in a row, or a source whose token was rejected.

## Storage

A new file next to `state.json` and `history.json`: `<dataDir>/projects.json`.

```json
{
  "version": 1,
  "connections": [
    { "id": "connection-…", "provider": "azureDevOps", "account": "contoso", "auth": "session", "sessionID": "work" },
    { "id": "connection-…", "provider": "github", "account": "octocat-work", "auth": "deviceToken", "sessionID": "work" }
  ],
  "projects": [{
    "id": "project-…", "name": "Billing API", "spaceID": "work", "order": 0,
    "environments": [
      { "id": "env-…", "name": "Local", "url": "http://localhost:5001", "healthPath": "", "sessionID": "work" },
      { "id": "env-…", "name": "PROD", "url": "https://billing.contoso.com", "healthPath": "/healthz", "sessionID": "isolated-env-…" }
    ],
    "links": [{ "id": "link-…", "kind": "repo", "label": "Repo", "url": "https://dev.azure.com/contoso/Billing/_git/billing-api", "sessionID": "work" }],
    "sources": [{ "connectionID": "connection-…", "resource": "contoso/Billing/billing-api" }]
  }]
}
```

Why a separate file: putting projects into `state.json` would mean raising its version. The current build rejects any version other than 1, then copies the file aside and saves defaults over it. Older builds would also drop an unknown `projects` array on their next save. A separate file keeps both versions of the app working.

Load and repair (`sanitize`), following the existing rules:

- Missing file: no projects, no connections. A corrupt file is copied to `projects-recovery-<unixtime>.json` before anything is saved. Unlike `history.json`, a corrupt file is not silently ignored, because this data was entered by hand.
- Unsafe or duplicate IDs are regenerated, with the first record winning.
- A `spaceID` that no longer exists moves the project to the first Space.
- A `sessionID` that does not exist and is not an isolated profile falls back to the project's Space default session.
- A URL that is not http/https is dropped (same rule as `NormalizedAddress`). An environment with no URL is dropped.
- A `connectionID` without a connection drops that binding. A connection with an unknown `auth`, or a `session` connection whose session no longer exists, is dropped together with its bindings.
- Blank names get fallbacks: "Project", the environment's host, or the link kind.
- An unknown link kind becomes `custom`. A link `environmentID` that no longer exists is cleared, so the link becomes project-wide.
- Saving is debounced the same way as `state.json`, and atomic.

## How a project gets onto a Space home

All four paths end in the same place: a `Project` with `spaceID` = the Space being added to, appended at the end of that Space's order.

### 1. Add project button (Space home)

A form with a name and an optional repo URL. When a URL is pasted, it is recognized (see "URL recognition") and fills in the name, a Repo link, a Pipelines link, and a source binding if a matching connection exists. Environments are added in the same form or later from the card.

### 2. Add from the current tab

When the selected tab is on a recognized repo page, a toolbar or menu item "Add as project to <Space>" opens the same form, already filled in. If a project with the same repo already exists in any Space, it offers "Show <project>" instead of creating a duplicate.

### 3. Attach a tab to a project

Right-click a tab → "Add to project ▸ <project> ▸ as Local / as INT / as PROD / as new environment… / as link". The project list shows the current Space's projects first. The new environment or link copies:

- the tab's URL, reduced to its origin for environments (`http://localhost:3000/account` → `http://localhost:3000`) and kept in full for links;
- the tab's session. A per-tab isolated session is adopted as-is (`isolated-<tabID>`), so the login it holds is kept.

The suggested name comes from the role picked. For a new environment it is the hostname's first label.

### Custom links

Added from the card's "…" menu ("Add link…": label, URL, session, optional environment), or with "Attach a tab … as link". On the card, `repo` and `pipelines` links sit in the button stack with the environments. Custom links form a compact row of chips under the status area, each showing an icon and the label, plus a small environment tag when `environmentID` is set (e.g. "LaunchDarkly · PROD"). The first four are shown; the rest go into an overflow menu. Order is the vector order and can be changed by dragging.

The icon is the tab's favicon when the link was attached from a tab, cached next to `projects.json`. Otherwise it is a generic link icon. Rail fetches no favicons for this in v1.

### 4. Import from a provider

Pick repositories from a list, in the current Space's default session:

- Azure DevOps: no setup. Enter an organization, or pick one from history (`dev.azure.com/{org}` pages you have visited). The list loads in the session; if it is signed out, the sheet shows "Sign in to Azure DevOps in <session>" instead.
- GitHub: the first import runs the device sign-in for that session, then lists the repos that token can see.
- Suggested at the top: repo pages from history that match "URL recognition". History stores no session and skips isolated tabs, so these are shown as "recently visited" without claiming which account opened them.

Each picked repo becomes a project in the current Space with a Repo link, a Pipelines link and a source binding. Environments are left empty, and the card shows "Add an environment" until there is one. Repos already linked to a project are shown as already added.

### URL recognition

| Pattern | Name | Links | Source resource |
| --- | --- | --- | --- |
| `https://github.com/{owner}/{repo}[/…]` | repo | Repo → `github.com/{owner}/{repo}`, Pipelines → `…/actions` | `{owner}/{repo}` |
| `https://dev.azure.com/{org}/{project}/_git/{repo}[…]` | repo | Repo → `…/_git/{repo}`, Pipelines → `dev.azure.com/{org}/{project}/_build` | `{org}/{project}/{repo}` |
| `https://{org}.visualstudio.com/{project}/_git/{repo}[…]` | repo | same, normalized to `dev.azure.com` | `{org}/{project}/{repo}` |

Recognition is a pure function in `BrowserModel` (testable without CEF). A URL that matches none of these patterns adds a plain link and nothing else.

## Fetching status

All fetching is native code started by the app; remote pages still have no bridge into the app.

- Health checks: `NSURLSession` and `Network.framework`, without cookies.
- `session` connections: `CefURLRequest::Create(request, client, requestContext)` with the session's `CefRequestContext`, `UR_FLAG_ALLOW_STORED_CREDENTIALS`, and `SetFirstPartyForCookies` set to the request URL (`vendor/cef/include/cef_urlrequest.h`, `cef_request.h`).
- `deviceToken` and `token` connections: `NSURLSession` with the token from the Keychain.

Requests that carry a session's login are restricted: GET only, only to `dev.azure.com` and `*.visualstudio.com`, and only to the `_apis` paths listed below. A user-entered URL never causes a request that carries a login.

**When:** only for the Space whose home is visible. Checks run on open, then every 60 s for health and every 2 min for providers, and immediately on "Check now". Failures back off to 5 min. Nothing is fetched for Spaces not on screen.

**Local environments:** a TCP connect to host:port with a 1 s timeout gives `up` or `notRunning`. If `healthPath` is set, an HTTP GET follows.

**Remote environments:** a GET to `url + healthPath` with a 5 s timeout, no cookies and no credentials.

- 2xx: `up`, or `slow` above 1000 ms.
- 3xx to a different host, or 401/403: `loginRequired`. The server is reachable but sits behind a login; this does not count as an attention item.
- 5xx, a timeout, or a DNS or TLS error: `down`.
- A version is shown only when the health response provides one, as a JSON `version` field or an `X-Version` header.

**Providers (read-only):**

| | Latest runs | Open PRs | Repo list (import) | Token check |
| --- | --- | --- | --- | --- |
| GitHub | `GET /repos/{o}/{r}/actions/runs?per_page=10` | `GET /repos/{o}/{r}/pulls?state=open` | `GET /user/repos` | `GET /user` |
| Azure DevOps | `GET /{org}/{proj}/_apis/build/builds?repositoryId={r}&repositoryType=TfsGit&$top=10` | `GET /{org}/{proj}/_apis/git/repositories/{r}/pullrequests?searchCriteria.status=active` | `GET /{org}/_apis/git/repositories` | `GET /{org}/_apis/connectionData` (`api-version=7.1-preview`) |

Azure DevOps calls use `api-version=7.1`; `connectionData` only accepts `7.1-preview` (a 400 otherwise, seen in the spike). In a session they carry the session's login; with a pasted token they use basic auth with an empty user name. Endpoints, scopes and response shapes must be verified against current provider docs during implementation.

Signed-out detection for Azure DevOps in a session (all observed in the spike): requests are sent with `UR_FLAG_STOP_ON_REDIRECT`, and any of these means `signedOut`:

- `connectionData` returns 200 with `authenticatedUser.providerDisplayName` = `Anonymous` (a session with no Microsoft login at all);
- a 302 to `*.vssps.visualstudio.com/_signin` (a session logged in to Microsoft, but not with access to this organization);
- a 203 with an HTML sign-in page, a 401, or any non-JSON response (in case redirects are followed).

`signedIn` reads the account from `authenticatedUser.properties.Account.$value`. The sign-in action opens `https://dev.azure.com/{org}` in that session; the next check picks up the new login.

A rejected token (401) marks the connection `rejected`, and it is not retried until the user signs in again or replaces the token. Minimum scopes for a pasted token: GitHub fine-grained token with Metadata, Actions and Pull requests set to read; Azure DevOps Build (read) and Code (read).

### Signing in to GitHub

1. The app requests a device code from `https://github.com/login/device/code` with Rail's client ID.
2. It opens `https://github.com/login/device` as a tab in the project's session, shows the code on the card and copies it to the clipboard. The user is usually already logged in there, so they paste the code and click Authorize.
3. The app polls `https://github.com/login/oauth/access_token` at the interval GitHub returns, stores the token in the Keychain, and reads the login from `GET /user` into `Connection.account`.

Rail is registered once as a **GitHub App** (decided 2026-10-29), with device flow enabled. The device flow needs only the client ID, no secret. Permissions are read-only: Metadata, Actions, Pull requests.

- **Installation:** install the app on the personal account and on each org with **All repositories**. New repos are then covered automatically; "Only select repositories" would need every new repo added by hand.
- **What a token can see:** the intersection of the app's permissions, the repos the installation covers, and what the signed-in user can access.
- **New permissions later** (e.g. Deployments or Checks for v2) need a one-time approval on each installation; GitHub asks the account or org owner.
- **Token lifetime:** user tokens expire after 8 hours and come with a refresh token valid for 6 months. The app refreshes silently and stores the new pair in the Keychain. Only a refresh token unused for 6 months, or a revoked app, leads back to the sign-in on the card.
- If a repo is not covered by any installation, its card shows "Rail can't see this repo" with a link to the installation settings, not a generic sign-in.

## Opening an environment or link

Clicking a card button opens the URL in the current Space, in the environment's session. If a tab in that Space already shows the same origin in the same session, that tab is selected instead of opening a duplicate.

## Tests

- `BrowserModel` tests: URL recognition, attach-tab origin reduction, sanitize rules (dangling Space, bad session, non-http URL, duplicate IDs), and accepting environment-owned isolated profiles in `setSession` and `sanitize`.
- `StateStore` tests: `projects.json` round-trip, corrupt file creates a recovery copy, and a future version is rejected without overwriting.
- Status mapping as a pure function: HTTP status, latency and error → `Health`; provider JSON → `PipelineRun`; Azure DevOps responses → `signedIn` / `signedOut`.
- Connection resolution as a pure function: Repo link session + recognized repo → existing or new connection; rebinding when the Repo link's session changes.

## Session request spike (done 2026-10-29)

Code on branch `spike/session-request` (worktree `../eimerrail-spike`): a test-only `sessionRequest` automation action and `scripts/spike-session-request.mjs`. Not for merging.

| Check | Result |
| --- | --- |
| Session cookies are sent by a browser-process `CefURLRequest` (localhost fixture) | Yes. `plain`, `SameSite=Lax` and `SameSite=Strict` cookies all arrive, with or without `SetFirstPartyForCookies`. |
| Other sessions stay separate | Yes. Personal and an isolated profile send no Work cookies. |
| Real Azure DevOps, signed in (copy of the real Work and Personal profiles, deleted afterwards) | Yes. `connectionData` and `/_apis/projects` return JSON as the logged-in account. Each session only sees the organization it is logged in to. |
| Real Azure DevOps, signed out | Recognizable: anonymous 200 from `connectionData` in an empty session, 302 to `vssps…/_signin` in a session logged in elsewhere. |
| Keychain | The spike build, signed with the same identity, read the existing cookie encryption key without a prompt. |

Conclusion: Azure DevOps through the session works as specified. The "Repo link session decides" rule matters in practice: one person already has different organizations in different sessions.

## Open

- The Space home is a "<Space> home" row above the tabs. It is not a tab and is not saved: selecting a tab or another Space leaves it, so a Space reopens on its last used tab.
- History stays as it is for v1: import suggestions say "recently visited" without naming an account. Recording the Space and session per visit can be added later if the suggestions turn out to be confusing.
- v2: App Insights alerts and Sentry issues as additional providers (App Insights could use the same session approach for the Azure portal login, to be checked), deployed versions per environment (Azure DevOps environments API), and suggestions for unattached `localhost` tabs.
- Step 2: the project detail page.
