# App Store build — design

**Date:** 2026-10-03
**Status:** Approved 2026-10-04.

## Goal

Ship MLXBits Image Studio on the Mac App Store as a free app with an optional tip jar, alongside the existing GitHub DMG. The immediate aim is to recoup the $99/year developer membership without requiring anyone to pay.

Both flavors have the same features. The App Store build is the same code with a sandbox, a different bundle ID, and a few flavor-specific screens. GitHub DMG releases stay the beta channel. An App Store release is a deliberate, manual step taken when a build is polished enough.

## Decisions

| Topic | Decision |
|---|---|
| Features | Full parity with the DMG, including the Scenario Generator (local Gemma via mlx-lm/mlx-vlm). |
| Python | Both flavors bundle a pinned, standalone Python 3.14 runtime with mflux and all dependencies. The uv/mflux installer is deleted. |
| Dev workflow | The DMG gets a "Custom Python (advanced)" override, so `~/Git/mflux/.venv` keeps working. The App Store build has no override. |
| App identity | Separate bundle ID (`com.mlxbits.image-studio.appstore`) and a fresh start: no data import from the DMG version. The two flavors are meant to install side by side; the open item in §1 confirms this. |
| Build structure | One target with two extra configurations (`Debug-AppStore`, `Release-AppStore`) and a dedicated scheme. |
| Releases | DMG is unchanged: a tag triggers `release.yml`. App Store releases use a manually triggered `appstore.yml` that uploads to TestFlight; submitting for review is a manual click in App Store Connect. |
| Models folder | The App Store build asks for it once. It pre-selects `~/.cache/huggingface` when that exists, and models stay shared with other tools. |
| Onboarding | Minimal for the first release: a library-folder step and a models-folder step. A polished onboarding flow is a later follow-on, not a release gate. |
| Tips (App Store) | Three consumable in-app purchases ($2.99 / $4.99 / $9.99). They unlock nothing. |
| Support (DMG) | Ko-fi (`ko-fi.com/mlxbits`) now. A GitHub Sponsors button stays hidden until GitHub approves the MLXBits profile. |
| Placement | App menu item, Settings section, and one nudge after 50 images that is shown once and never again. |
| Version | Not a 1.0. The first release carrying this work (the DMG on the bundled runtime, milestone 4) is **v0.16.0**. Later milestones ship as normal minor or patch releases. |
| License | MIT (done in #11). |
| Age rating | Expect the highest tier (18+). Draw Things, a comparable app, is rated 18+. |

## Evidence: the sandbox spike (2026-10-03)

A throwaway app signed with the Apple Development identity and given sandbox entitlements ran `Resources/mflux_driver.py` on a uv standalone CPython 3.14.7 with mflux 0.21.0 installed into `Contents/Resources/python`.

- **The sandbox was really enforced.** Writes to `~/Desktop` and listing `~/Documents` were denied.
- **The runtime worked.** MLX ran on the Metal GPU, and `flux2-klein-9b-8bit` produced a correct 512×512 image (3.3 s model load, 17 s for two images, 20.8 GB peak).
- **Folder grants reach Python.** Folders granted through an open panel were readable and writable by the Python child process. That includes the HF hub cache, and a grant made *after* the child started.
- **Grants survive relaunch.** After a relaunch, resolved security-scoped bookmarks gave the same access.
- **Detection without a grant.** The sandboxed app can `stat` `~/.cache/huggingface` without a grant, so it can tell the folder exists, but it can't list its contents.
- **Bundle size.** 1.4 GB. torch, sympy and networkx account for about 690 MB.

## Non-goals and follow-ons

- **Polished onboarding:** model picking, a guided first generation.
- **Importing from the DMG version:** profiles, notepad and history.
- **Trimming the bundle:** torch and matplotlib.
- **Automation of App Store releases:** submitting for review and metadata uploads.
- **Monthly App Store tips:** an auto-renewing subscription. Guideline 3.1.2 makes a pure tip subscription a rejection risk.

---

## 1. Build structure

**Configurations.** `project.yml` keeps one app target and adds two configurations:

| | `Debug` / `Release` (DMG) | `Debug-AppStore` / `Release-AppStore` |
|---|---|---|
| Bundle ID | `com.mlxbits.image-studio` | `com.mlxbits.image-studio.appstore` |
| Entitlements | `Resources/MLXBits_Image_Studio.entitlements` (no sandbox, unchanged) | `Resources/MLXBits_Image_Studio_AppStore.entitlements` |
| Swift flag | — | `APP_STORE` |
| Signing (Debug) | ad-hoc, as today | Apple Development, team from an untracked `Local.xcconfig` |
| Signing (Release) | Developer ID (CI) | Apple Distribution (CI) |

`Debug-AppStore` needs a stable signing identity. An ad-hoc identity changes on every build, and that breaks security-scoped bookmarks. The team ID comes from a gitignored `Local.xcconfig`, mirroring how CI injects `DEVELOPMENT_TEAM` for Release.

**App Store entitlements:**
- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`
- `com.apple.security.assets.pictures.read-write`, for the default library in `~/Pictures`
- `com.apple.security.network.client`, for Hugging Face, and for LM Studio and ComfyUI on the LAN

**Schemes:**
- **"MLXBits Image Studio"** is unchanged: Run, Test and Archive work as today.
- **"MLXBits Image Studio (App Store)"** is new. Run uses `Debug-AppStore`, Archive uses `Release-AppStore`, and it has no test action. Choosing the scheme is how you choose the flavor.

**Runtime build step.** It runs in every configuration and is controlled by a `BUNDLE_PYTHON_RUNTIME` setting, default `YES`. CI's test job and the App Store compile-only job set it to `NO` to stay fast. An app without a runtime shows a clear "Python runtime missing from this build" state instead of failing jobs obscurely. Both flavors are arm64 only.

**CI** (`ci.yml`):
- **Existing jobs unchanged:** format/lint, duplication, tests.
- **New compile-only job:** builds `Debug-AppStore` with the runtime skipped, so broken `#if APP_STORE` code fails on the PR.
- **New runtime job:** runs only when `Runtime/` or the build script changes (see §2 and §7).

**Versioning.** Both flavors take `MARKETING_VERSION` from the tag (`v0.16.0` gives `0.16.0`).
- **DMG build number:** the commit count, as `release.yml` already does.
- **App Store build number:** `<commit count>.<workflow run number>`. App Store Connect requires every upload's build number to be higher than all earlier uploads, and this stays unique when the same tag is re-uploaded.

**App name collision, resolved by the first TestFlight install (2026-10-04).** The App Store installer renames rather than refusing or replacing: next to a DMG copy, the TestFlight build installed as `MLXBits Image Studio 2.app`, and the DMG copy kept its name, so dragging a new DMG over it still replaces only the DMG copy. No rename needed.

## 2. Python runtime

**Pins, checked in under `Runtime/`:**
- **`python.lock`:** the URL and SHA-256 of the python-build-standalone `install_only_stripped` CPython build for `aarch64-apple-darwin`. The initial pin is CPython 3.14.7, the version the spike used and the dev virtualenv runs.
- **`requirements.in`:**
  - `mflux`: the newest PyPI release when the lock is generated, never below 0.18.1 (the first with Krea 2)
  - `mlx-lm>=0.31.3`
  - `mlx-vlm==0.6.3`
  - `transformers>=5.5,<5.13`: one pin that satisfies both mflux (5.5 or later) and the Scenario Generator (below 5.13)
- **`overrides.txt`:** removes `opencv-python` (`opencv-python ; sys_platform == "never"`).
  - **Why it's safe:** mflux imports `cv2` lazily, and only in ControlNet, OpenPose and HED code. Image Studio uses none of them.
  - **Why it's needed:** the opencv wheel ships FFmpeg built with libx264, which is GPL.
- **`requirements.lock`:** generated by `uv pip compile --python-platform aarch64-apple-darwin --python-version 3.14 --generate-hashes`. It is the only input the build installs from.

**Build script** (`scripts/build-python-runtime.sh`):
1. Download and verify the Python, then install the lock with `uv pip install --require-hashes --no-deps --break-system-packages`.
2. **Trim:**
   - tkinter, Tcl/Tk, idlelib, ensurepip, `test/` directories and C headers
   - every `bin/` launcher script (their shebangs hold absolute paths)
   - torch's `protoc` binaries
3. Precompile bytecode with `--invalidation-mode unchecked-hash`, so Python never tries to rewrite `.pyc` files inside the signed bundle.
4. **License guard.** Fail if any package declares GPL, AGPL or LGPL, or if any FFmpeg or x264 library (`libav*`, `libsw*`, `libx264*`) appears anywhere in the tree.
   - **MPL-2.0 is allowed** (certifi, tqdm): file-level copyleft, satisfied by shipping the files unmodified with their notice.
5. **Acknowledgements.** Generate `Acknowledgements.txt` from every package's license files plus CPython's license. Both flavors show it under Help ▸ Acknowledgements.
6. **Manifest.** Write `runtime-manifest.json` with the Python version, a hash of the lock, and each package's version and license.
7. **Smoke test.** Run `run_tool.py <name> --help` (see §3) for every tool name the app uses, and import `mflux`, `mlx_lm`, `mlx_vlm` and `torch`.

The output goes to `build/python-runtime/` (gitignored). It is cached locally and in CI, keyed by a hash of `python.lock`, `requirements.lock`, `overrides.txt` and the script.

**Into the bundle.** A run-script phase copies the runtime to `Contents/Resources/python` and signs every Mach-O file before Xcode signs the outer bundle:

| | Libraries (`.so`, `.dylib`) | `python3.14`, `torch_shm_manager` |
|---|---|---|
| DMG Debug | ad-hoc, no hardened runtime | ad-hoc, no hardened runtime, no entitlements |
| DMG Release | Developer ID, hardened runtime, timestamp | same, no entitlements |
| App Store (both) | build identity, hardened runtime | same, plus `app-sandbox` + `inherit` only |

Child executables must carry the sandbox-inherit pair only in the App Store flavor. In an unsandboxed parent, that pair would crash the child.

Signing is cached per identity with a stamp file, so routine Debug builds don't re-sign about 190 files.

**Release workflows:**
- **Both** restore or build the cached runtime.
- **`release.yml`** signs with Developer ID before notarizing.
- **Both re-run the smoke test** against the *signed* runtime, so hardened-runtime or library-validation failures appear before notarization or upload.
- **The post-signing smoke test runs through the app.** The app's executable takes a hidden `--runtime-self-test` flag (added with the toolchain in milestone 4). It runs the tool and import checks as children of the real app process, prints the results, and exits non-zero on failure. The reason: in the App Store flavor, `python3.14` carries the sandbox-inherit entitlements, and a sandbox-inherit binary launched outside a sandboxed parent crashes. The DMG flavor uses the same flag for consistency.
- **`appstore.yml` can't run `--runtime-self-test`:** an app signed for App Store distribution won't launch outside the store. It keeps its static checks (signature, python entitlements, arm64); the sandboxed runtime is exercised by the `Debug-AppStore` self-test and TestFlight.

## 3. Toolchain

**Today:**
- Tool paths are resolved in several places: `AppSettings.mfluxBinaryPath()` and siblings, `BinaryDetector`, `UvInstaller.resolvedPath`, `GemmaChatRunner.uvPath`, `MfluxDriverController.venvPython(fromShim:)`.
- Runners launch `mflux-generate-*` launcher scripts by path.

**`Toolchain`, one type for both flavors.** It answers:
- **How do I run tool *X*?**
  - *X* is one of the names `mflux-generate-flux2`, `mflux-save`, the SeedVR2 upscaler, `hf`, `mlx_lm.generate`, `mlx_vlm.generate`, …
  - The answer is: the interpreter, plus `Resources/run_tool.py`, plus *X*, plus the arguments.
- **Which interpreter runs `mflux_driver.py` and `scenario_llm_driver.py`?**
- **Which environment do children get?**
  - `PYTHONNOUSERSITE=1` and `PYTHONDONTWRITEBYTECODE=1`
  - `MPLCONFIGDIR` in Caches
  - `HF_HOME`: the models folder in the App Store build, or the existing setting in the DMG
  - plus whatever `AppSettings.buildEnvironment()` sets today (HF token, cache limits)

**`run_tool.py`** looks up *X* with `importlib.metadata.entry_points(group="console_scripts", name=X)`, sets `sys.argv`, and calls it. Tool names stay identical to today's command names, so runner code and the one-shot fallback path don't change shape. Tool names are the `PythonTool` enum, kept equal to `Runtime/tools.txt` by a test.

**Interpreter:**
- **Default:** the bundled `python3.14`.
- **DMG only, "Custom Python (advanced)" setting:** any interpreter with mflux installed, such as `~/Git/mflux/.venv/bin/python`. It applies to mflux tools and the mflux driver.
- **Scenario Generator and caption tools** always use the bundled interpreter.
- **Capability probes** (`supports`, `supportsBaseModel`, version) run through the selected interpreter. Results are cached per interpreter path for the launch; choosing another Custom Python asks again.

**One-time migration** (DMG, first launch of the new version), applied to the old `mfluxBinaryDir`:
- **A uv-managed mflux** (the venv Python lives under uv's tools folder) is dropped in favor of the bundled runtime.
- **Any other folder,** such as a dev checkout, becomes the Custom Python override, using the interpreter from the launcher script's shebang (existing `venvPython(fromShim:)` logic).

**Deleted:**
- `UvInstaller`
- `MfluxInstaller` and its tests
- the mflux install/upgrade banner and version-floor checks in `ContentView`
- `BinaryDetector`'s path search
- `uv run --with …` in `GemmaChatRunner`
- the mflux folder and uv rows in Settings

**App Store build only (`#if APP_STORE`):**
- `UpdateChecker` is off; App Store apps update through the store.
- The free-text HF home field is replaced by the models-folder row (§4).
- The Custom Python setting is absent.

**Call sites that switch to the toolchain:**
- the five `<Family>JobRunner` specs (`binaryPath`, `saveBinaryPath`)
- `JobRunner`
- `MfluxDriverController`
- `GemmaChatRunner` and `ScenarioGenerator`
- `IdeogramCaptionGenerator`
- `ModelDefaultsView` (`hf`, `mflux-save`)
- `FluxModelCatalog`

**Release note for existing DMG users:** the uv-installed mflux under `~/.local/share/uv/tools/mflux` is no longer used. `uv tool uninstall mflux` frees its space.

## 4. Sandbox file access (App Store build)

All of this lives behind one `FileAccess` service. The DMG implementation passes paths through untouched. Both implementations compile in every build, and `#if APP_STORE` only selects which is used.

**Persistent folder grants** (app-scoped security bookmarks):

| Folder | Grant kept in | Granted via |
|---|---|---|
| Each profile's library | `grants.json`, by path | first-run prompt, New Profile, Change Folder, missing-library banner |
| Models folder (`HF_HOME`) | `grants.json`, by path | first run, Settings ▸ Advanced |
| Custom model directories, Gemma model path, mflux cache dir | `grants.json`, by path | when picked; while unset, each uses its default inside the container |

**How grants are kept (decided in milestone 5).** One store, `grants.json` in App Support, holds every bookmark, keyed by the path it was made for. Bookmarks aren't fields on profiles, LoRAs or settings.
- **Coverage:** a path is reachable through the deepest grant at or above it. A LoRA downloaded into the models folder, or a source image in the library, needs nothing of its own.
- **Why one store:** jobs, drafts, saved stacks and settings all keep carrying plain paths.
- **A folder renamed or moved in Finder isn't followed:** it shows as missing, as in the DMG, until it's chosen again.

- **Picker only.** In the App Store build, folder fields are read-only with Browse…, because a typed path carries no grant. This includes the New Profile sheet's library field. Fields that also take a Hugging Face repo ID (model sources, the Gemma model, the custom model) stay typeable: Browse… grants access, and a typed folder the app can't open shows a hint.
- **Profile switching.** A profile's library grant starts when the profile activates and stops when it deactivates.
- **Stale bookmarks** are re-created quietly from the resolved URL.
- **An unresolvable bookmark** shows the existing missing-library banner, where "Change Folder…" re-grants.
- **The models grant covers `HF_HOME` itself,** not just `hub/`, so the token file and Hugging Face's other caches are included.

**LoRA files.**
- **Picked from anywhere:** each picked file gets a grant, started for the duration of a job.
- **Downloaded from Hugging Face:** they live under the models folder and need nothing extra.
- **File gone:** a LoRA whose bookmark no longer resolves shows a warning with "Locate…". A job using it fails with "Access to <name> was lost — locate the file again."

**Source images** (img2img, edit images, SeedVR2 sources, template images):
- **Inside the active library:** used in place.
- **From elsewhere** (open panel, drag and drop, or paste): copied into `Profiles/<id>/Inputs/<content-hash>.<ext>` inside the container, and the job references the copy.
- **Effect:** re-runs and templates keep working after a relaunch. Removing a profile deletes its `Inputs/` with the rest of its data.

**First run (minimal):**
1. **Library folder** (existing prompt).
   - **Choose…:** pick a folder.
   - **Skip for Now:** creates `~/Pictures/MLXBits Image Studio`, using the Pictures entitlement, so the default library is visible in Finder.
2. **Models folder.**
   - **If `~/.cache/huggingface` exists:** the app says "We found your Hugging Face model cache — use it?" and opens the picker on that folder; one click confirms.
   - **Otherwise:** models live in the app's container, and Settings ▸ Advanced can move them later.

**Already in the container, no work needed:** profiles, settings, job history, notepad, thumbnails, timing data, stepwise previews, and the system-prompt files.

## 5. Support: tip jar and donation links

**Shared Support sheet.** It opens from:
- the app menu: "Support MLXBits Image Studio…", right after About
- a Support section in Settings
- the nudge below

It opens with:

> Every feature is free. Tips don't unlock anything; they just help keep the project going.

**The nudge.**
- **When:** after the 50th successfully generated image, counted across all profiles. The counter and the flags below are app-global, not per profile.
- **What:** a dismissable card under the top bar, styled like the existing banners:
  > Image Studio is free and built in spare time. If it's useful to you, a tip helps cover the costs to build and maintain it. We appreciate anything you can provide.
- **Buttons:** **Leave a Tip…** and **No Thanks**. Either one retires the nudge for good.
- **Never shown** if the Support sheet was already opened or a tip was made.
- A debug-only override lowers the threshold for testing.

**App Store build: StoreKit 2.**
- **Products:** three consumables:
  - `com.mlxbits.image-studio.appstore.tip.small` ($2.99)
  - `…tip.medium` ($4.99)
  - `…tip.large` ($9.99)
- **Prices:** names and local-currency prices are loaded from the store, never hard-coded.
- **Purchase flow:** purchase, verify, finish, thank-you. Cancelled and pending (Ask to Buy) outcomes are handled quietly.
- **Interrupted purchases:** a `Transaction.updates` listener started at launch finishes them.
- **No Restore button:** consumables need none.
- **Stored state:** only a local "has tipped" flag, which suppresses the nudge.
- **Local testing:** a `.storekit` configuration file in the project.
- **No external links:** the App Store build never shows Ko-fi or GitHub links. Outside the US storefront that breaks Apple's rule against steering users to other payment methods.

**DMG build:**
- **Support on Ko-fi:** links to `https://ko-fi.com/mlxbits`. Live now.
- **Sponsor on GitHub:** links to `https://github.com/sponsors/MLXBits`. Present in code but hidden until GitHub approves the Sponsors profile.

**Repo:** `.github/FUNDING.yml` gets `ko_fi: mlxbits` now and `github: [MLXBits]` after approval. It's a separate small change, not part of this build.

## 6. App Store Connect, release workflow, review

**One-time setup (owner):**
1. Accept the **Paid Applications agreement** and add bank and tax details. In-app purchases need it even in a free app. Then enroll in the **App Store Small Business Program**, which brings the commission to 15%.
2. Create **Apple Distribution** and **Mac Installer Distribution** certificates. Use a CSR generated in the portal, not from Xcode.
3. Register the App ID `com.mlxbits.image-studio.appstore` (In-App Purchase capability), then create a **Mac App Store distribution provisioning profile** for it.
4. Create the **App Store Connect record**:
   - macOS app, name "MLXBits Image Studio". Do this early: it reserves the name.
   - Category Graphics & Design, price Free.
   - Available everywhere except China mainland, where generative-AI apps need a government license.
5. Create the three consumable **in-app purchases**, each with a description and a review screenshot of the Support sheet. The first in-app purchases must be submitted together with an app version.
6. Create an **App Store Connect API key** (App Manager role).
7. Add **repo secrets**:
   - `APPSTORE_DIST_CERT_P12_BASE64` / `_PASSWORD`
   - `APPSTORE_INSTALLER_CERT_P12_BASE64` / `_PASSWORD`
   - `APPSTORE_PROFILE_BASE64`
   - `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`

**`appstore.yml`** (`workflow_dispatch`):
- **Input:** `ref`, any tag, branch or commit, defaulting to the newest `vX.Y.Z` tag. The first upload built `main`, because the App Store configurations postdate `v0.15.0`.
- **Steps:**
  1. Check out the ref with full history, then derive the version and build number (§1). The version comes from the nearest `vX.Y.Z` tag at or behind the ref.
  2. Import both certificates into a temporary keychain (same pattern as `release.yml`) and install the profile.
  3. Restore or build the runtime, which includes the license guard.
  4. Archive `Release-AppStore` with manual signing.
  5. Smoke-test the signed runtime. Until `--runtime-self-test` exists (milestone 4), the workflow checks the archived app's signatures, entitlements (no `get-task-allow`; `python3.14` has exactly app-sandbox + inherit) and arm64-only slice instead.
  6. Export with `method: app-store-connect` and `destination: upload`, authenticating with the API key.
- **Result:** the build appears in TestFlight.

**Info.plist additions:**
- **Both flavors:**
  - `NSHumanReadableCopyright` = "© 2026 MLXBits"
  - `NSLocalNetworkUsageDescription`, explaining the LM Studio and ComfyUI connections
  - `LSApplicationCategoryType` = `public.app-category.graphics-design`, which Mac App Store uploads require
  - `ITSAppUsesNonExemptEncryption = NO`. The app only uses standard HTTPS. The key does nothing outside the store, so one shared `Info.plist` carries it.
- **App Store flavor:** `ARCHS = arm64`, matching the arm64-only runtime.

**Review prep:**
- **App privacy:** "Data Not Collected." Nothing is sent to the developer. Hugging Face, LM Studio and ComfyUI traffic is the user's own.
- **Privacy policy URL:** a short `PRIVACY.md` in the repo.
- **Support URL:** the GitHub issues page.
- **Age rating:** answer the generative-AI and user-generated-content questions honestly; expect 18+.
- **Reviewer notes:**
  - The app bundles Python and mflux (open source) for on-device inference.
  - It downloads model weights (data, not code) from Hugging Face, and no code is downloaded or run from outside the bundle.
  - Tips unlock no features.
  - Which small model to try first, and roughly how long its download takes.
- **Hardware:** arm64 only. The description states the realistic RAM requirement.
- **Listing:** at least one screenshot (1280×800 to 2880×1800), subtitle, keywords, description, promotional text.

## 7. Testing

**Principle:** every new type compiles in both flavors, and `#if APP_STORE` only selects. The existing test suite runs in the DMG configuration under the TestHost isolation added in v0.15.0, and covers almost everything.

**Unit tests (Swift Testing):**
- **`Toolchain`:**
  - tool-name resolution, driver interpreter and environment, against a fake bundle in a temp folder
  - the Custom Python override
  - the `mfluxBinaryDir` migration for both cases (uv-managed is dropped; dev checkout becomes the override)
- **`FileAccess`:**
  - the DMG implementation passes paths through
  - a bookmark round trip
  - the in-library / outside-library decision and the copy into `Inputs/`
  - removing a profile removes its `Inputs/`
- **Grant store:** the deepest covering grant wins; a sibling folder sharing a prefix isn't covered; a moved folder isn't followed; a stale bookmark is re-created.
- **Tip jar:** StoreKitTest with the `.storekit` file: success, cancelled, pending, and finishing an interrupted transaction at launch.
- **Nudge rule** (a pure function): threshold reached, dismissed, tipped, sheet opened.

**CI:**
- **Runtime job:** builds the runtime (cached), runs the license guard, and smoke-tests every tool name through `run_tool.py`.
- **Release workflows:** both repeat the smoke test, plus `import torch`, against the signed runtime, by running the built app with `--runtime-self-test`.

**Manual checklist.** Sandboxed checks use the App Store scheme, then TestFlight.
1. **First run:**
   - Choose… and Skip for Now (library appears in `~/Pictures`)
   - HF cache detected and confirmed in one click
   - no-cache path keeps models in the container
2. **Each family** (Flux2, Krea 2, Ideogram 4, Z-Image, SeedVR2), through the warm driver and through the one-shot fallback.
3. **LoRAs:**
   - one from an arbitrary folder, then again after relaunch
   - a LoRA whose grant starts while the warm driver is already running
4. **Source images:** img2img from outside the library, then a re-run after relaunch.
5. **Profiles:**
   - create (picker only), switch, change folder, remove
   - unplug a library drive, then re-grant from the banner
6. **Scenario Generator** with local Gemma, and with LM Studio over the LAN. Also a ComfyUI backend on the LAN.
7. **Model files:** a download into the models folder, and `mflux-save` quantizing into a custom directory.
8. **Tip jar:** against the `.storekit` file in Xcode, then a sandbox purchase via TestFlight. Check the nudge with the debug threshold.
9. **Notarized DMG:**
   - a generation on the bundled runtime
   - the Custom Python override pointing at `~/Git/mflux/.venv`, including the automatic migration
   - Ko-fi visible, GitHub hidden
10. **Side by side:** install the TestFlight build next to the DMG (name-collision check, §1). Done 2026-10-04: installs side by side (see §1).

**Data safety:**
- App Store-scheme runs use their own container and can't touch real data.
- Before the first DMG run with the toolchain migration, back up `~/Library/Application Support/MLXBits Image Studio` and `defaults export com.mlxbits.image-studio`.

## Risks and fallbacks

| Risk | Detection | Fallback |
|---|---|---|
| Upload validation rejects native code under `Contents/Resources` | first TestFlight upload (milestone 3) | Move `python3.14` to `Contents/MacOS/`, add an rpath to `Resources/python/lib`, set `PYTHONHOME` |
| mlx-vlm imports `cv2` at startup | runtime smoke test / Scenario Generator check | Build an opencv-python-headless wheel from source with `WITH_FFMPEG=OFF`, cached like the runtime |
| mflux misbehaves on transformers 5.12 | per-family manual checks | A second site-packages for the Scenario stack, on `PYTHONPATH` only for its tools |
| A bookmark grant started after the warm driver launched doesn't reach it | manual check 3 | Start LoRA grants before spawning the driver, or restart the driver when a new grant starts |
| torch fails under hardened runtime in the signed DMG | post-signing smoke test | Add the narrowest hardened-runtime exception the failure names, to `python3.14` only |
| App name already taken | creating the record (setup step 4) | Choose a store name; the bundle name can stay |
| App Review rejects | review | Reviewer notes, the guideline 2.5.2 explanation, Draw Things precedent (18+); answer questions and resubmit |

## Milestones (input to the implementation plan)

1. **Runtime:**
   - `Runtime/` pins and lock, build script, license guard, acknowledgements, smoke test
   - CI runtime job
2. **Build structure:**
   - configurations, scheme, App Store entitlements, `APP_STORE` flag, `Local.xcconfig`
   - runtime copy-and-sign step for each flavor
   - CI compile-only job
3. **Skeleton TestFlight upload:**
   - requires setup steps 1–7
   - proves upload validation and reserves the name before deeper work
4. **Toolchain:**
   - `Toolchain`, the Custom Python override, migration, and the `--runtime-self-test` flag (`run_tool.py` itself lands in milestone 1)
   - delete the installers
   - release a DMG on the bundled runtime, so beta testers exercise it
5. **App Store file access:** `FileAccess`, bookmarks, `Inputs/` import, picker-only fields, the first-run models step, the `~/Pictures` default.
6. **Support:** Support sheet, nudge, StoreKit tip jar, Ko-fi button (DMG), hidden GitHub button.
7. **Store release:**
   - `appstore.yml`, Info.plist keys, `PRIVACY.md`
   - reviewer notes and listing assets
   - TestFlight pass, then submission
