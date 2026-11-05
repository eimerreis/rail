# Rail updates

Rail ships Sparkle 2, pinned in `sparkle.lock.json`. Bootstrap verifies the official archive's SHA-256 before extracting the framework and release tools. CMake embeds the framework, preserves its symlinks, and signs the nested XPC services, updater app, and executables before signing the containing app.

Release builds use an HTTPS appcast, Ed25519 archive signatures, signed appcasts, and verification before extraction. Automatic checking and downloading are enabled by default, with a six-hour check interval. Users can change both preferences in the Rail menu; Sparkle persists them. Automation runs never start Sparkle. Development builds with no public key do not contact the update feed and retain **Reinstall Latest main**. Configured releases use **Check for Updates…** instead.

Sparkle sends the application a normal quit request for an immediate install and watches process termination before replacing it. Rail already routes that request through its Chromium shutdown path, including unsaved-page confirmation, state persistence, closing browsers, and `CefShutdown`. A downloaded background update installs on a later normal quit.

## Changeset releases

Rail uses the Changesets CLI for release intent, semantic versions, and changelogs. The private `rail` package in `package.json` is release tooling only; nothing is published to npm. CMake reads its version directly, so native builds and the source reinstall command do not require Node or npm.

Contributors need Node 22.11+ (22, 24, or 26+) and npm 10.9+. Run `npm ci` once to install the pinned CLI and the local pre-commit hook.

Every change commit needs a **new** `.changeset/*.md` file with a Rail patch, minor, or major bump and a nonempty summary. Generate it with the CLI and commit it alongside the change:

```sh
npm run changeset
# Choose rail, the bump type, and a short release note.
git add <changed-files> .changeset
git commit -m "Describe the change"
```

Merge the change and its changeset into `main`. That push starts the release pipeline; a separate version PR is not needed. Multiple changesets in the checkout are consumed together, and the largest requested bump wins: patch plus minor produces one minor release.

The serialized release pipeline:

1. Checks the latest `main` after acquiring the release lock, validates all unreleased change commits, and runs `changeset status`.
2. If pending Rail changesets exist, runs `npm run changeset:version`, which calls the real CLI and synchronizes the root lockfile version.
3. Commits `package.json`, `package-lock.json`, `CHANGELOG.md`, and the consumed changesets as `github-actions[bot]`, then pushes that version commit to `main` with an ordinary fast-forward push.
4. Builds that exact version commit, tests it, and publishes the signed Sparkle release in the **same workflow run**.

Queued pushes batch the pending changesets on the latest `main`. If another push advances `main` during versioning, the version push fails instead of overwriting it; a queued push or a manual retry processes the updated branch. The bot's `GITHUB_TOKEN` push does not start a recursive workflow.

The pre-commit hook validates the staged index. The **Changesets** GitHub Actions check validates every new commit on pull requests and pushes to `main`, so an earlier changeset cannot cover a later change. Make **Changesets** a required branch check to enforce this before merging. Local hook setup does not alter remote branch protection. The workflow needs permission to push generated release metadata to `main`; branch rules must permit that bot update.

Commits with a `chore(deps):` subject, and merges of branches made up only of those commits, don't need a changeset in the **Changesets** check, so Dependabot updates pass without one and ship with the next release. The pre-commit hook still requires one, because it runs before the commit message exists.

Generated version commits are the exception to the new-changeset requirement. They contain only the generated package version, lockfile version, changelog, and changeset deletions, and the version must match the consumed changesets. Contributors normally only run `npm run changeset`; versioning happens in CI. `npm run changeset:version` remains available for local inspection and tests.

With no pending changesets, an already-published version is skipped. An unpublished version from a failed run is retried without another version bump. **Release Rail → Run workflow** performs the same status/version/retry flow on `main`. The job tags the tested version as `v<version>`, uses the generated changelog entry for GitHub release notes, and publishes through the existing signed Sparkle feed. Failed uploads can reuse the same tag only when it still points to the same source, and only draft assets may be replaced.

## Chromium updates

`scripts/update-cef.py` reads the official CEF build index and selects the highest Chromium version, then the highest CEF revision, for the **stable macosarm64 minimal** distribution. It ignores beta builds and incomplete builds and never downgrades an existing pin. CEF availability may lag a Chromium announcement. The selected archive's name, size, and checksum are written to `cef.lock.json`; bootstrap independently verifies them before extraction.

```sh
./.tools/bin/python scripts/update-cef.py        # Print the latest lock
./.tools/bin/python scripts/update-cef.py --write
./scripts/build.sh
```

Chromium updates travel in a complete Rail update. The CEF headers, C++ wrapper, helper executables, and framework are built together and signed as one app; replacing the framework inside a running signed bundle is unsupported.

`.github/workflows/update-engine.yml` checks every six hours when `RAIL_AUTOMATIC_RELEASES=true`, and also supports **Propose Chromium update → Run workflow**. It selects the latest stable engine using the last published lock as a minimum, then opens or updates an `automation/chromium-update` PR containing the new lock and a patch changeset. Merging that PR into `main` triggers automatic versioning and a signed Sparkle release. The existing variable name is retained, but now enables update proposals.

The engine proposal needs **Allow GitHub Actions to create and approve pull requests** in repository Actions settings. PRs created with the default `GITHUB_TOKEN` may require approval before their workflows run; the updater checks its staged changeset before opening the PR, and a human merge triggers the release pipeline on `main`. See [GitHub’s workflow-trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).

Every pull request also builds on an Apple Silicon macOS runner and runs the integration suites from `scripts/release-smoke.sh` as the **Smoke tests** check. It uses no signing identity or secrets, and a new push cancels the PR's earlier run.

`.github/workflows/release.yml` publishes only after versioning:

1. Validates change commits and runs the Changesets integration tests on Linux, then runs status/version and pushes the generated version commit to `main`. No pending changesets and no unpublished version means no release.
2. Checks out that exact source, preserves the latest appcast history, and rejects a committed engine older than the latest published engine. The release build never changes `cef.lock.json`.
3. Builds on an Apple Silicon macOS runner and runs CTest and the browser, projects, DevTools, context-menu, theme, find, 1Password, and reading integration suites with disposable profiles.
4. Notarizes the Developer ID signed app, staples its ticket, and creates the final ZIP. Sparkle signs that archive and the appcast.
5. Checks the build number and archive metadata before publishing the immutable version tag, ZIP, appcast, and `cef.lock.json` on GitHub Releases. Previous appcast entries keep their original download URLs, including compatible releases for older macOS versions.

Both the version and engine lock in the tag are the tested source files. The pipeline writes only the generated version metadata to `main`; it does not modify the engine lock during release. The app records its engine lock in `Contents/Resources/cef.lock.json` as well.

App and helper minimum macOS versions follow the CEF distribution's deployment target. Sparkle carries that requirement into the appcast, so a future engine that requires a newer macOS is offered only on supported systems. Compatibility failures stop publication until Rail is adapted and the tests pass.

The Go helper receives the same deployment target through its C compiler and linker flags. A bundle compatibility test verifies the actual Mach-O targets of the app, 1Password helper, CEF helpers, and frameworks against the minimum macOS version in the update feed.

Releases use `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT.0` as the increasing `CFBundleVersion`, independently of Rail's marketing version in `package.json`. Old workflow re-runs cannot publish a lower build number or an older app version. Publication is serialized. Build, test, notarization, or signing failures leave the existing published release and feed in place; uploaded diagnostics contain app test logs. Re-running a failed pre-publication run gets a new attempt number.

## First release setup

Create a Sparkle signing key using the official bundled tool on a trusted Mac:

```sh
./scripts/bootstrap.sh
./vendor/sparkle/bin/generate_keys --account rail
# Export to a private location outside the repository for the CI secret.
./vendor/sparkle/bin/generate_keys --account rail -x /private/path/rail-sparkle-key
```

Keep a backup of the private key. Set the following repository **Actions variables**:

| Variable | Value |
| --- | --- |
| `SPARKLE_PUBLIC_KEY` | Base64 public key printed by `generate_keys` |
| `RAIL_AUTOMATIC_RELEASES` | `true` to enable scheduled engine-update PRs |
| `RAIL_GITHUB_CLIENT_ID` | Optional existing GitHub App client ID for Rail |

Set these repository **Actions secrets** through GitHub's secret interface:

| Secret | Value |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | Contents of the exported Sparkle key file |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 export of the Developer ID Application certificate **and private key** |
| `APPLE_DEVELOPER_ID_PASSWORD` | Password protecting the P12 export |
| `RELEASE_KEYCHAIN_PASSWORD` | Password for the temporary CI keychain |
| `APPLE_NOTARY_KEY_P8` | Contents of the App Store Connect API private key authorized for notarization |
| `APPLE_NOTARY_KEY_ID` | Notarization API key ID |
| `APPLE_NOTARY_ISSUER_ID` | Notarization API issuer ID |

The workflow requires Actions write access to repository contents for the version commit, tags, and release assets. Merge or push the initial changes and their changesets into `main` to start automatic versioning and publication. Install that packaged app, then enable `RAIL_AUTOMATIC_RELEASES` for scheduled engine-update proposals. Existing development builds without a public key need this one-time install before they can receive Sparkle updates. A private GitHub repository needs a separately hosted publicly readable feed and archives; the supplied release workflow targets public GitHub Releases.

No release keys, certificates, repository settings, or releases are created by the source changes alone.

## Local release build

```sh
./scripts/build.sh \
  '-DRAIL_SIGN_IDENTITY=Developer ID Application: Your Name (TEAMID)' \
  -DRAIL_DISTRIBUTION=ON \
  -DRAIL_BUILD_VERSION=1.1.0 \
  '-DRAIL_UPDATE_PUBLIC_KEY=YOUR_BASE64_PUBLIC_KEY'
```

`RAIL_UPDATE_FEED_URL` defaults to `https://github.com/eimerreis/rail/releases/latest/download/appcast.xml`. Distribution mode requires a public key and uses timestamped signatures. Normal development builds keep local signing with no timestamp service.

After tests pass, `scripts/package-release.sh <output-directory>` notarizes, staples, packages, and signs a local build. It requires `SPARKLE_PRIVATE_KEY_FILE`, `NOTARYTOOL_PROFILE`, and `RAIL_RELEASE_TAG`; optionally set `RELEASE_KEYCHAIN` and `RAIL_RELEASE_REPOSITORY`. It does not publish. Copy the preceding published appcast into the output directory first to preserve update history. Keep build numbers increasing relative to all published builds.

## Verification

`npm test` exercises the actual Changesets CLI, Git hook, commit validation, version batching, CMake version propagation, automatic pipeline versioning, release snapshot selection, concurrent-push rejection, and retry behavior in disposable repositories. It never pushes or publishes.

`tests/UpdateTests.py` covers channel filtering, numeric version ordering, missing builds, downgrade prevention, malformed archive metadata, real Sparkle archive and feed signing, preserving previous appcast entries, tamper rejection, and rejecting stale release runs. Its signing fixture uses a public RFC test vector and never reads or writes the login Keychain. The Sparkle integration test is skipped when the macOS tools are unavailable.

Before shipping the first release, verify a complete update between two packaged, notarized builds on a test installation, including declining an update and cancelling quit on a page with unsaved changes. Live notarization and installation require the release credentials and hosted feed.

References: [Sparkle setup](https://sparkle-project.org/documentation/), [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [update settings](https://sparkle-project.org/documentation/customization/), [manual framework signing](https://sparkle-project.org/documentation/sandboxing/#code-signing), [CEF automated builds](https://github.com/chromiumembedded/cef/blob/master/docs/automated_build_setup.md).
