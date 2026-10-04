# App Store build, milestone 3: first TestFlight upload — implementation plan

**Goal:** Upload an App Store build of the current `main` to App Store Connect through a manually triggered workflow, and install it from TestFlight.

**Why now:** The upload's server-side validation is the only real test of the spec's riskiest choice, which is native code under `Contents/Resources`. We want that answer before milestones 4–7 build on the layout.

**Spec:** `docs/specs/2026-10-03-app-store-build-design.md`, §1 (versioning and the name-collision check) and §6 (`appstore.yml`, `Info.plist`). The Apple-side setup (spec §6 steps 1–7) is done, and the repo secrets exist.

## Gaps found before starting

- **`LSApplicationCategoryType` is missing.** Mac App Store uploads are rejected without it.
- **The App Store configurations build x86_64 too.** The bundled runtime is arm64 only, and the spec says arm64 only.
- **The latest tag, `v0.15.0`, predates the App Store configurations.** The workflow must accept any ref; the first upload builds `main`.

## Tasks

### 1. Info.plist keys and arm64-only App Store builds
- **`project.yml` `info.properties`:**
  - `LSApplicationCategoryType: public.app-category.graphics-design`
  - `NSHumanReadableCopyright: "© 2026 MLXBits"` (currently empty)
  - `NSLocalNetworkUsageDescription`, explaining the LM Studio and ComfyUI connections
  - `ITSAppUsesNonExemptEncryption: NO`
- **The DMG gets these keys too.** The spec scopes `ITSAppUsesNonExemptEncryption` to the App Store flavor, but outside the store it does nothing, and one shared `Info.plist` avoids per-flavor plist files.
- **`ARCHS: arm64`** in `Debug-AppStore` and `Release-AppStore`.
- **Verify:**
  - `-showBuildSettings` shows `ARCHS = arm64` for both App Store configurations and is unchanged for the DMG ones.
  - The generated `Info.plist` has the four keys.
  - A Debug-AppStore build is arm64 only (`lipo -archs`) and still passes `codesign --verify --deep --strict`.
  - The DMG flavor still builds.

### 2. `appstore.yml`
`workflow_dispatch` with an optional `ref` input, defaulting to the newest `vX.Y.Z` tag. Steps:
1. Check out with full history, resolve the ref, and check it out.
2. **Version** comes from the nearest `vX.Y.Z` tag at or behind the ref, without the `v`.
3. **Build number** is `<commit count>.<run number>`.
4. **Signing setup.**
   - Import the Apple Distribution and installer `.p12`s into a temporary keychain, as `release.yml` does.
   - Install the provisioning profile under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.provisionprofile`, and read its name.
   - Write the `.p8` to `$RUNNER_TEMP`.
5. **Runtime.** Run setup-uv, restore the runtime cache (same key as `runtime.yml`), and run `scripts/build-python-runtime.sh`.
6. **Archive** `Release-AppStore` for `generic/platform=macOS`:
   - `CODE_SIGN_STYLE=Manual`
   - `CODE_SIGN_IDENTITY="Apple Distribution"`
   - `PROVISIONING_PROFILE_SPECIFIER=<profile name>`
   - `OTHER_CODE_SIGN_FLAGS=--keychain <temp keychain>`
   - the version and build number
7. **Check the archived app.**
   - `codesign --verify --deep --strict` passes.
   - `python3.14` carries exactly app-sandbox + inherit.
   - The app has no `get-task-allow`.
   - Only arm64 slices are present.

   The spec's `--runtime-self-test` arrives in milestone 4; until then, these checks stand in.
8. **Export and upload:**
   - Export options: `method: app-store-connect`, `destination: upload`, manual signing, `signingCertificate: Apple Distribution`, `installerSigningCertificate: 3rd Party Mac Developer Installer`, the profile mapped to the bundle ID.
   - Authentication: `-authenticationKeyPath/ID/IssuerID`.
9. **Clean up:** always delete the keychain, the `.p8` and the profile copy.

**Verify:** YAML parses, and every secret name matches the eight set in App Store Connect setup step 7.

### 3. Docs
- **README:** "Cutting an App Store build" (run the workflow, then find the build in TestFlight).
- **Spec §6:** corrected to match what was built: the `ref` input, the version taken from the nearest tag, `LSApplicationCategoryType`, and `Info.plist` keys in both flavors.

### 4. Merge and upload
1. Open a PR. CI must be green.
2. Squash-merge. A `workflow_dispatch` workflow can only be run once it exists on the default branch.
3. Run `gh workflow run appstore.yml -f ref=main` and watch it.
4. **If it fails,** fix it on a branch and re-run with `--ref <branch>`; the workflow already exists on `main`, so that works.
5. **On a validation rejection** of the `Contents/Resources` layout, stop and apply the spec's fallback in its own change.

### 5. TestFlight (owner, in App Store Connect and the TestFlight app)
1. After processing (Apple emails when it's done), open **TestFlight**, add yourself as an internal tester, and install the build.
2. Check whether it installs next to the DMG copy in `/Applications`; this is the spec §1 name-collision question.
3. The build won't generate anything yet. The toolchain is milestone 4, so here it only proves install and launch.
