# Agent notes — MLXBits Image Studio

Orientation for coding agents. This is the canonical file; `CLAUDE.md` is a
symlink to it (see "Using this file with your agent" at the bottom).

SwiftUI macOS app that drives [mflux](https://github.com/filipstrand/mflux)
subprocesses to generate images. Xcode 26+, macOS 26 deployment target.

## Build and verify

`project.yml` is the source of truth. **Never edit `.xcodeproj` directly** — it
is generated and your changes will be overwritten.

```bash
xcodegen generate                       # after any project.yml change
swiftlint lint --config .swiftlint.yml  # run before building
```

If `~/MLXBits.xcworkspace` exists (the multi-Studio workspace: Image Studio,
Video Studio, LTX Dataset Studio), you **must** build through it — never
`-project` against the `.xcodeproj`:

```bash
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" \
           -scheme "MLXBits Image Studio" -configuration Debug build
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" \
           -scheme "MLXBits Image Studio" test
```

On a plain clone without that workspace, substitute
`-project "MLXBits Image Studio.xcodeproj"`.

SwiftFormat and SwiftLint also run as pre-build scripts, so a build rewrites
formatting. Lint before you build to avoid a confusing second diff.

## Repo map

```
App/           Entry point + ContentView root layout
Models/        Job models, model catalog, LoRA entries, prompt history/templates
Runner/        Generic JobRunner<Spec> engine, per-family specs, warm-driver controller
Stores/        @Observable app state (settings, per-family job stores, gallery, timings)
Utilities/     Keychain, metadata sidecars, progress parsing, installers, caption/scenario LLMs
Views/         SwiftUI, one subdirectory per surface (see below)
Tests/         Swift Testing unit tests — pure logic only, no UI tests
Resources/     Info.plist, entitlements, and the Python drivers shipped in the bundle
project.yml    XcodeGen manifest — source of truth for targets, sources, Info.plist
```

`Resources/mflux_driver.py` and `Resources/scenario_llm_driver.py` are bundled
resources, not build inputs. Changing the NDJSON protocol means changing both
the Python driver and `Runner/DriverProtocol.swift`.

## Naming conventions

Five model families, defined in `Models/ModelFamily.swift`: `flux`, `ideogram4`,
`krea2`, `zimage`, `seedvr2`. Files follow the family name exactly:

| Concern | Path |
|---|---|
| Job model | `Models/<Family>Job.swift` |
| Runner spec | `Runner/<Family>JobRunner.swift` — `enum <Family>RunnerSpec: JobRunnerSpec` plus `typealias <Family>JobRunner = JobRunner<<Family>RunnerSpec>` |
| Job store | `Stores/<Family>JobStore.swift` |
| Params UI | `Views/<Family>/<Family>ParamsPanelView.swift` + `…ParamsPanelState.swift` |
| Preview UI | `Views/<Family>/<Family>PreviewViews.swift` |
| Settings form | `Views/Settings/ModelDefaultsView+<Family>Form.swift` |

Glob for these rather than grepping file contents.

**Three irregularities to know before you search:**

1. **Flux is the unprefixed default.** Its store is `Stores/JobStore.swift` (not
   `FluxJobStore`), its panel state is `Stores/ParamsPanelState.swift`, and its
   views live in `Views/ParamsPanel/`, not `Views/Flux/`. There is no
   `Views/Flux/` directory.
2. **SeedVR2 has no `Views/SeedVR2/`.** It is an upscale action on an existing
   image, not a pickable family, so its UI lives in
   `Views/PreviewPane/SeedVR2PreviewViews.swift` and `SeedVR2UpscaleSheet.swift`.
   It appears in `ModelFamily` only to get its own `GenerationCoordinator` gate
   identity (the OOM guard that serializes it against generative runs).
   `ModelFamily.generative` is the list that excludes it.
3. **Ideogram 4 is much larger than the others.** `Views/Ideogram4/` carries a
   whole bounding-box editor (`BBoxEditorView` plus `+Canvas`, `+Gestures`,
   `+Subviews` extensions) and a caption editor. Start at `BBoxSemantics.swift`
   and `BBoxGeometry.swift` for the model behind that UI.

## Do not search these

Gitignored but present on disk, and expensive to grep:

- `build/`, `DerivedData/` — build output
- `.jscpd-report/` — duplication-checker HTML
- `*.xcodeproj/` — generated from `project.yml`; read the manifest instead
- `docs/screenshots/` — binary PNGs

## Architecture in one paragraph

`Runner/JobRunner.swift` is a generic engine: `JobRunner<Spec: JobRunnerSpec>`
owns queueing, progress parsing, cancellation, and output handling, while each
family's `Spec` supplies only `buildArgs(job:ctx:settings:)` and a few hooks.
Jobs conform to `GeneratedJob`, stores to `GenerationJobStore`.
`GenerationCoordinator` serializes runs across families so two models never sit
resident at once. `MfluxDriverController` is the alternative fast path: a
long-lived warm Python process spoken to over NDJSON on stdio
(`Runner/DriverProtocol.swift`), keyed by a fingerprint of family + model +
quantization + LoRA stack — a fingerprint mismatch forces an unload before the
next load.

When adding a parameter, prefer extending the family's `buildArgs` over touching
`JobRunner` itself. If a change needs `JobRunner` edits, it probably belongs to
all five families.

## Recipe: add a model family

Adding Z-Image touched 24 files. In dependency order:

1. `Models/ModelFamily.swift` — add the case; add to `.generative` unless it is
   an action like SeedVR2.
2. `Models/<Family>Job.swift` — the job model, conforming to `GeneratedJob`.
3. `Models/FluxModelCatalog.swift` — model IDs, variants, defaults.
4. `Runner/<Family>JobRunner.swift` — the spec enum, `buildArgs`, the typealias.
5. `Stores/<Family>JobStore.swift` — conform to `GenerationJobStore`.
6. `Stores/AppSettings.swift` — persisted per-family defaults.
7. `Views/<Family>/` — params panel, panel state, preview views.
8. `Views/Settings/ModelDefaultsView+<Family>Form.swift`, then register it in
   `ModelDefaultsView.swift`.
9. Wire the surfaces that switch on family: `App/ContentView.swift`,
   `App/MLXBitsImageStudioApp.swift`, `Views/ParamsPanel/ModelPickerView.swift`,
   `Views/ParamsPanel/ParamsPanelView.swift`, `Views/PreviewPane/PreviewPaneView.swift`,
   `Views/Queue/QueueDrawerView.swift`, `Views/Gallery/GenerationGalleryView.swift`,
   `Views/PreviewPane/GalleryItemDetailView.swift`.
10. Metadata and constraints: `Utilities/MetadataSidecar.swift`,
    `Views/Shared/ImageMetadataInfo.swift`, `Views/Shared/DimensionConstraints.swift`,
    `Stores/GalleryStore.swift`, `Utilities/BinaryDetector.swift`.
11. If the family needs a new *directory*, add it to `sources:` in `project.yml`
    and re-run `xcodegen generate`. New files inside an existing directory are
    picked up automatically — no manifest change needed.

Grepping for `ZImage` is the fastest way to find any touchpoint this list misses.

## Conventions and gotchas

- Swift 5.9 with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` — types are
  main-actor isolated by default. Annotate explicitly to move work off the main
  actor.
- Tests are Swift Testing (`@Test`, `#expect`), not XCTest, and cover pure logic
  only. Do not add UI tests.
- Progress reporting parses mflux's tqdm output (`Utilities/JobProgressParser.swift`).
  Use the raw step value; do not add app-side ETA estimates on top.
- Secrets go through `Utilities/KeychainHelper.swift`. `.env` holds the Apple
  Team ID for release builds and is gitignored — never commit it or echo it.
- The app is unsandboxed (`com.apple.security.app-sandbox: false`) to reach
  user-chosen model directories.
- Do not script bulk reads or edits over the user's image output directory.
  Fix the code and describe the manual cleanup instead.

## Using this file with your agent

`AGENTS.md` is the portable convention, read by Cursor, Codex, and others.
Claude Code auto-loads `CLAUDE.md`, so point one at the other locally:

```bash
ln -s AGENTS.md CLAUDE.md
```

That symlink is gitignored — this file is the only tracked copy, so there is no
second document to keep in sync. Recreate the link after a fresh clone.

If you ever stage the link, use a plain `git add`. Do **not** use `git add -N`
on it: unstaging an intent-to-add symlink writes the empty blob over the link
target and silently breaks it.
