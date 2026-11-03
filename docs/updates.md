# Rail updates

Rail ships Sparkle 2, pinned in `sparkle.lock.json`. Bootstrap verifies the official archive's SHA-256 before extracting the framework and release tools. CMake embeds the framework, preserves its symlinks, and signs the nested XPC services, updater app, and executables before signing the containing app.

Release builds use an HTTPS appcast, Ed25519 archive signatures, signed appcasts, and verification before extraction. Automatic checking and downloading are enabled by default, with a six-hour check interval. Users can change both preferences in the Rail menu; Sparkle persists them. Automation runs never start Sparkle. Development builds with no public key do not contact the update feed and retain **Reinstall Latest main**. Configured releases use **Check for Updates…** instead.

Sparkle sends the application a normal quit request for an immediate install and watches process termination before replacing it. Rail already routes that request through its Chromium shutdown path, including unsaved-page confirmation, state persistence, closing browsers, and `CefShutdown`. A downloaded background update installs on a later normal quit.

## Chromium updates

`scripts/update-cef.py` reads the official CEF build index and selects the highest Chromium version, then the highest CEF revision, for the **stable macosarm64 minimal** distribution. It ignores beta builds and incomplete builds and never downgrades an existing pin. CEF availability may lag a Chromium announcement. The selected archive's name, size, and checksum are written to `cef.lock.json`; bootstrap independently verifies them before extraction.

```sh
./.tools/bin/python scripts/update-cef.py        # Print the latest lock
./.tools/bin/python scripts/update-cef.py --write
./scripts/build.sh
```

Chromium updates travel in a complete Rail update. The CEF headers, C++ wrapper, helper executables, and framework are built together and signed as one app; replacing the framework inside a running signed bundle is unsupported.

`.github/workflows/release.yml` runs every six hours when `RAIL_AUTOMATIC_RELEASES=true`. It compares the selected engine with the latest published release and does no build when nothing changed. It also supports **Run workflow** for an app release without an engine change. The workflow:

1. Checks out `main` and selects the newest stable engine, using the last released lock as a minimum so an app release cannot roll Chromium back.
2. Builds on an Apple Silicon macOS runner and runs CTest and the browser, projects, DevTools, theme, find, 1Password, and reading integration suites with disposable profiles.
3. Notarizes the Developer ID signed app, staples its ticket, and creates the final ZIP. Sparkle signs that archive and the appcast.
4. Checks the build number and archive metadata before publishing an immutable release tag, ZIP, appcast, and `cef.lock.json` on GitHub Releases. Previous appcast entries keep their original download URLs, including compatible releases for older macOS versions.

The tag points to the tested source, including its engine lock. Automated releases do not write to `main`; that branch retains its development pin. A local `--write` updates the development pin. Release builds record their engine lock in `Contents/Resources/cef.lock.json` as well.

App and helper minimum macOS versions follow the CEF distribution's deployment target. Sparkle carries that requirement into the appcast, so a future engine that requires a newer macOS is offered only on supported systems. Compatibility failures stop publication until Rail is adapted and the tests pass.

Releases use `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT.0` as the increasing `CFBundleVersion`, independently of Rail's marketing version in `CMakeLists.txt`. Old workflow re-runs cannot publish a lower build number. Publication is serialized. Build, test, notarization, or signing failures leave the existing published release and feed in place; uploaded diagnostics contain app test logs. Re-running a failed pre-publication run gets a new attempt number.

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
| `RAIL_AUTOMATIC_RELEASES` | `true` to enable scheduled engine releases after the first successful release |
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

The workflow requires Actions write access to repository contents for tags and release assets. Run **Release Rail → Run workflow** on `main` to publish the initial release, install that packaged app, then enable `RAIL_AUTOMATIC_RELEASES`. Existing development builds without a public key need this one-time install before they can receive Sparkle updates. A private GitHub repository needs a separately hosted publicly readable feed and archives; the supplied release workflow targets public GitHub Releases.

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

`tests/UpdateTests.py` covers channel filtering, numeric version ordering, missing builds, downgrade prevention, malformed archive metadata, real Sparkle archive and feed signing, preserving previous appcast entries, tamper rejection, and rejecting stale release runs. Its signing fixture uses a public RFC test vector and never reads or writes the login Keychain. The Sparkle integration test is skipped when the macOS tools are unavailable.

Before shipping the first release, verify a complete update between two packaged, notarized builds on a test installation, including declining an update and cancelling quit on a page with unsaved changes. Live notarization and installation require the release credentials and hosted feed.

References: [Sparkle setup](https://sparkle-project.org/documentation/), [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [update settings](https://sparkle-project.org/documentation/customization/), [manual framework signing](https://sparkle-project.org/documentation/sandboxing/#code-signing), [CEF automated builds](https://github.com/chromiumembedded/cef/blob/master/docs/automated_build_setup.md).
