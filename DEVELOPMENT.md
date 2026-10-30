# Developing MLXBits Image Studio

How to build the app from source, cut a release, and find your way around the
code. To install the app, see the [README](README.md).

## Building from source

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [SwiftLint](https://github.com/realm/SwiftLint), [SwiftFormat](https://github.com/nicklockwood/SwiftFormat), [uv](https://github.com/astral-sh/uv).

```bash
brew install xcodegen swiftlint swiftformat uv

git clone https://github.com/MLXBits/image-studio
cd image-studio

# Generate the Xcode project
xcodegen generate

# Open and build in Xcode
open "MLXBits Image Studio.xcodeproj"
```

> **Signing:** Set `DEVELOPMENT_TEAM` in `project.yml` to your 10-character Apple Developer Team ID before building a signed Release. Debug builds are unsigned and work without a Team ID.

### Python runtime and the App Store flavor

Both flavors bundle their own Python with mflux and every dependency, pinned
in `Runtime/`. `scripts/build-python-runtime.sh` builds it into
`build/python-runtime/` (it needs `uv`: `brew install uv`), and the
"Embed Python runtime" build phase runs it automatically when needed. The first
build takes several minutes; later builds reuse it.

**Developing against an mflux checkout:** set **Settings → Advanced → Python →
Custom Python** (DMG build only) to the checkout's `.venv/bin/python`. mflux and
the warm driver then run on it; everything else stays on the bundled runtime.
To check a built app's runtime:
`"<app>/Contents/MacOS/MLXBits Image Studio" --runtime-self-test`.

To build the App Store flavor locally, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and set your Team ID, then build the
**MLXBits Image Studio (App Store)** scheme. It runs sandboxed in its own
container (`~/Library/Containers/com.mlxbits.image-studio.appstore`), so it
never touches the DMG app's data.

On first run the App Store flavor asks for a library folder (Skip for Now uses Pictures ▸ MLXBits Image Studio) and a models folder, offering `~/.cache/huggingface` when it exists. It keeps access to every folder and LoRA you choose. Images you bring in from outside the library are copied into the profile, so re-runs work after a relaunch.

Image Studio is free in both flavors. **Support MLXBits Image Studio…** in the app menu (also in Settings ▸ Advanced) offers optional tips through the App Store in the App Store flavor, and a Ko-fi link in the DMG. Tips unlock nothing. After 50 images the app asks once, and never again.

The app collects no data: see the [privacy policy](PRIVACY.md).

To change a Python package version, edit `Runtime/requirements.in` and run
`scripts/lock-python-runtime.sh`. The runtime build refuses GPL-family
packages; a package without license metadata must be checked by hand and
recorded in `Runtime/license-overrides.json`.

---

## Cutting a release

Releases are built, signed, notarized, and published automatically by GitHub Actions
([`.github/workflows/release.yml`](.github/workflows/release.yml)) whenever a `vX.Y.Z` tag is
pushed. The tag name is the source of truth for the release version.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z    # → triggers the release workflow
```

The workflow derives the version from the tag, builds the Release archive with Developer ID
signing, creates a notarized + stapled DMG, and publishes a GitHub release with generated notes.
(Optionally bump `MARKETING_VERSION` in `project.yml` too, so local Debug builds report the new
number — CI overrides it either way.)

**One-time setup** — add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | `base64 < DeveloperID.p12` — the "Developer ID Application" cert exported **with private key** |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password |
| `DEVELOPMENT_TEAM` | your 10-char Apple Team ID |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password from appleid.apple.com |

### App Store builds

App Store builds are uploaded by a hand-run GitHub Actions workflow
([`.github/workflows/appstore.yml`](.github/workflows/appstore.yml)): **Actions ▸ App Store ▸
Run workflow**, or `gh workflow run appstore.yml` (newest `vX.Y.Z` tag) /
`gh workflow run appstore.yml -f ref=main`. It builds the sandboxed App Store flavor with the
bundled Python runtime, signs it with the Apple Distribution certificate, and uploads it to
App Store Connect. The build shows up in TestFlight once Apple has processed it; submitting
it for review is done in App Store Connect.

Submitting a version: see [docs/appstore/submission.md](docs/appstore/submission.md).

| Secret | Value |
|---|---|
| `APPSTORE_DIST_CERT_P12_BASE64` / `_PASSWORD` | Apple Distribution certificate `.p12`, base64, and its export password |
| `APPSTORE_INSTALLER_CERT_P12_BASE64` / `_PASSWORD` | Mac Installer Distribution certificate `.p12`, base64, and its export password |
| `APPSTORE_PROFILE_BASE64` | Mac App Store provisioning profile for `com.mlxbits.image-studio.appstore`, base64 |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | App Store Connect API key (App Manager role): key ID, issuer ID, `.p8` base64 |

---

## Project layout

```
App/           App entry point and root layout
Models/        Job models, model catalog, LoRA entries, prompt history/templates
Runner/        Generic JobRunner<Spec> engine, per-family runner specs, warm-driver controller
Stores/        @Observable state — AppSettings, per-family job stores, GalleryStore, TimingStore
Views/         SwiftUI views, one subdirectory per surface (ParamsPanel, PreviewPane, Gallery, Queue, Settings, …)
Utilities/     KeychainHelper, MetadataSidecar, progress parser, caption/scenario LLMs, the Python toolchain
Tests/         Swift Testing unit tests
Resources/     Info.plist, entitlements, bundled Python drivers
project.yml    XcodeGen source of truth (never edit .xcodeproj directly)
```

For naming conventions, the per-family file layout, and a step-by-step recipe
for adding a model family, see [AGENTS.md](AGENTS.md).

### Working with an AI coding agent

[AGENTS.md](AGENTS.md) is the canonical orientation file, read by Cursor,
Codex, and others. Claude Code looks for `CLAUDE.md`, so after cloning, create
a local symlink:

```bash
ln -s AGENTS.md CLAUDE.md
```

The symlink is gitignored on purpose — one tracked file, no duplicated
guidance to keep in sync, and no tool-specific artifact in the repo.
