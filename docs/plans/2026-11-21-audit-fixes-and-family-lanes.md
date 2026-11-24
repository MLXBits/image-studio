# Audit Fixes and Family Queues: Improvement Plan

> **Status (2026-11-24):** PR 1 is merged (#128). PR 2 and PR 3 are scheduled, and the
> design decisions for them were settled on 2026-11-24 against `943b532`. Part 3 stays
> parked until PR 3 lands. Before you start a PR, check its file and symbol references
> against the current `main`.
>
> The file name still says "family-lanes" because #128 links to it. The design uses
> **queue**, not "lane": see `GLOSSARY.md`.

**Goal:** Fix the real bugs from the 2026-11-21 Ponytail audit (done). Then replace the
six-way family enumeration in the App layer with one generic queue per family. This
makes model adds cheaper and lets `FamilyQueues` be tested.

**Inputs, each checked against the code:**
- `docs/ponytail-audit-2026-11-21.md`: 20 findings, of which the audit itself kept 14.
- The Family Registry design spec. It is an out-of-repo draft, so its relevant content
  is summarised in Part 2.
- `GLOSSARY.md`: the terms this plan uses (family, queue, run, landing, gate, run
  order, hand-off, replay, Remix, Apply Settings).

**Tech stack:** Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, SwiftUI, Swift Testing.

## Global constraints

- Lint gate, which must pass before every commit:
  `swiftformat --lint --config .swiftformat .` and
  `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
- Tests: `xcodebuild -project "MLXBits Image Studio.xcodeproj" -scheme "MLXBits Image Studio" test`
- A clean build has zero warnings. CI fails a PR that raises jscpd's duplicated-token
  share by more than 0.1 points.

---

## Part 1: Audit, re-verified (done in #128)

### Fixed in PR 1

| # | Verdict | Fix |
|---|---|---|
| F6: queue save swallows errors | Real. `JobHistoryFile.write` used `try?` three times. Severity: **should-fix, not must-fix.** The write is `.atomic`, so a failure leaves the previous file intact and loses only the newest change. | `write` throws. `save()` sets `saveError`, using the same pattern as `AppSettings.saveError` and `LoraLibraryStore.saveError`, and the error is shown to the user. |
| F13: a probe timeout is cached as "unsupported" | Real, and the doc comment on `runProbe` admitted it. `runProbe` returned nil on a timeout, `== "1"` turned that into `false`, and `baseModelCache` stored the `false`. | The probe closure returns `Bool?`, and nil is not cached. The 60 s timeout stays. |
| F14: two pastes collide on one temp file | Real, but rare. | A UUID suffix on the file name. |
| F8: a lost ComfyUI prompt polls for 1 hour | **The problem was real, but the audit's fix was wrong.** For an unknown id, ComfyUI answers `/history/{id}` with **200 `{}`**, not 404 (confirmed against a live server on 2026-11-24). A non-2xx answer was also treated as pending. | After N empty polls, check `/queue`. If the id is in neither the running list nor the pending list, read `/history` once more: a record there means the prompt just finished, and a failed read decides nothing. Only a recheck that still finds no record fails the job with "prompt lost — server may have restarted". Non-2xx answers, dropped connections and bodies that aren't JSON count toward `consecutiveFetchFailures`. |
| F4: `sessionCompleted` / `inSession` are dead | Real. 7 hits, all writes, all in `Runner/JobRunner.swift`. | Both properties deleted. `activeJob = nil` kept in the else branch. |
| F17: caption encode drops `artStyle` | Real, but reachable only from foreign JSON. | `isPhotoMode` stays `photo != nil`. An empty `photo` decodes as nil, so foreign JSON keeps its `art_style`. A round-trip test covers that input and asserts that `photo == ""` still means photo mode. |
| F3: no fingerprint test for a strength-only change | A test gap only. | One assertion per family. |

### Dropped (the audit is wrong)

- **F2: watchdog.** Only `resetCancelState()` (`Runner/MfluxDriverController.swift`)
  cancels the watchdog. That function runs when a run ends or when the process dies,
  so at that point nothing is left to kill. The proposed `hardKill()` on cancellation
  would kill a healthy warm driver after every clean Stop.
- **F20: caption teardown write.** `persistPromptState()` sets three in-memory
  `AppSettings` properties. The profile save is debounced, so this is not a disk
  write. `onDisappear` cancels the pending autosave **first**, so the proposed
  `autosaveTask == nil` guard would skip the only save and **lose edits**. Also,
  `autosaveTask` is never set back to nil.
- **F18: Qwen21Job decode defaults.** `let defaults = Qwen21Job()` keeps the defaults in
  one place. Inline literals would make a second copy that can drift.
- **F16: progress cap of 500.** The cap is unreachable, because steps are clamped to 150
  or fewer.
- **F15: keychain `.denied` treated as settled.** This applies only to the *legacy*
  item. A retry would show the denial prompt again on every launch. Leave it unless
  re-prompting is wanted.

### Folded into PR 2

- **F5** (a skipped gallery rescan) and **F7** (one full gallery scan per completion
  event) both come from the 11 completion `onChange` blocks in `ContentView`: 6 on
  `lastCompletedOutputPath`, 5 on `batchImageLanded` (SeedVR2 has none).
  - F5's mechanism: the batch-verify paths assign `batchImageLanded = verified.count`
    (and `= paths.count`). Two batches of the same size in a row assign the same
    value, and `onChange` does not fire on a repeat.
  - F7's mechanism: one landing can fire both observers, so it scans twice. Several
    images that land together (ComfyUI downloads, batch verify) scan once each.

  The single landing handler in PR 2 fixes both.

---

## Part 2: Family queues, as decided

**What the Family Registry spec proposed:** `FamilyQueues` holds one `FamilyBinding`
per family. `PreviewState` collapses to three cases. Replay moves onto the binding. A
new `ParamsState` protocol is added across the five panel states (C6). A single
aggregated completion path replaces the completion `onChange` blocks (C9).

**Verdict:** The direction is right, but the design needed corrections. Build the
smaller version below.

**Facts the spec gets wrong:**
- `FamilyQueues` is a `struct` that `ContentView` builds on demand from its environment,
  on every body evaluation. It has no stored state, so making it `@Observable` gains
  nothing.
- `isRunning` is on the store, not the runner.
- The runner has no `run(job:)`. Enqueue is already generic
  (`FamilyQueues.enqueue<Spec>`).
- `App/GenerateAction.swift` already exists (#117). A `binding.generate()` would duplicate it.
- Defaults are already keyed by variant (`AppSettings.defaults(for:)`).
- Only the Flux `ParamsPanelState` has `model`. It is the picker for every family.
- Runners do not emit events. They set observable properties.

### Decisions

**D1. `FamilyQueue<Spec>`, a struct.** A new file, `Runner/FamilyQueue.swift`, holds
`protocol AnyFamilyQueue` and `struct FamilyQueue<Spec: JobRunnerSpec>: AnyFamilyQueue`.
A queue holds only `family`, `store` and `runner`. It is a struct because
`FamilyQueues` is rebuilt on every body evaluation, and a class would allocate six
objects per render. The shared `settings`, `coordinator` and `timing` stay on
`FamilyQueues` and are passed to `runNext`. The name is "queue", not "lane": a lane
was always the same thing as a family's queue.

**D2. `FamilyQueues` holds no typed fields.** It holds `all: [any AnyFamilyQueue]`
in `GenerationCoordinator.runOrder` order, plus `settings`, `coordinator`, `timing`
and `driverController`. The 12 typed store and runner fields go away, so tests can
build `FamilyQueues` from fake queues.
- `GenerateAction` is the only typed consumer. It gets its own 5 typed
  `FamilyQueue<Spec>` fields, next to the 5 params states it already lists.
- `enqueue` becomes `enqueue(_ jobs: [Spec.Job], on queue: FamilyQueue<Spec>) -> Bool`.
- `activeJobID`, `isAnyRunning`, `histories`, `pump`, `stopAll` and `hasWaitingJobs`
  become loops over `all`.
- `pump` keeps the warm-driver rule as `if family != .flux { driverController.eject(…) }`.
  It is not a queue property.

**D3. Restart routes through the queues.** Job types carry no family, and
`store.restart` needs a concrete `Spec.Job`. Each queue gets
`func restart(_ job: any GeneratedJob) -> Bool`, which does `job as? Spec.Job` and
returns false for another family's job. `FamilyQueues.restart(_ job:)` tries each queue
in turn and calls `pump()` once one takes the job. `ContentView` passes `previewState.previewedJob`. This is
the one downcast in the design, and it stays inside the queue.

**D4. `PreviewState` keeps its per-family cases.** The spec's
`case job(any QueueListedJob)` would not remove the family switch in
`PreviewPaneView`. Each family needs its own metadata type, info rows, failed view,
img2img flag and placeholder. The switch would become an `as?` chain with a
`default:`, and a new family would silently show nothing. The switches that cost
something are *outside* the pane, and those go away:
- Each Spec gets `static func preview(_ job: Job) -> PreviewState`.
- Each queue exposes `activePreview: PreviewState?` from it.
- `restoreActiveJobPreview` becomes `queues.all.lazy.compactMap(\.activePreview).first ?? .idle`.
- In PR 3, the drawer's `previewSelection(PreviewState.activeXJob)` calls and
  `GenerateAction`'s `preview:` arguments use `Spec.preview`.

**D5. One landing signal per runner.** `JobRunner` replaces `lastCompletedOutputPath`
and `batchImageLanded` with one observable value:

```swift
struct Landing: Equatable { let seq: Int; let run: Int; let firstPath: String }
private(set) var landing: Landing?
```

- It is state, not an event. Observation coalesces writes made in the same
  main-actor turn, so a per-image `{path, selects}` event would let a batch's later
  images overwrite the one that selects. The value carries the run's first image
  instead, and the handler selects when `run` changes.
- `seq` only goes up, for the runner's lifetime. A repeated batch size can no longer
  hide a landing, which fixes F5.
- Only the **first landing of each run** (one run = one job) selects, on every
  runner path. Today the paths disagree: images that land one by one select the
  first, ComfyUI then jumps to the last when the batch finishes, and batch verify
  selects the last. All paths now select the first image and leave the selection
  alone after that, because the user may already be looking at it. A fan-out or a
  multi-image upscale is several runs, so the selection still moves forward run by run.
- The runner remembers the paths a run has landed, so the end-of-run reconcile
  lands only the images the poller or the driver missed.

This is a `JobRunner` change, and it applies to all six families, as AGENTS.md
expects of `JobRunner` edits.

**D6. One landing handler with a debounced scan.**
- `FamilyQueues` exposes `landings: [Landing?]`, in `all` order.
- `ContentView` replaces the 11 completion `onChange` blocks with one
  `.onChange(of: queues.landings)`.
- A pure function (`LandingDiff.compare`) compares the old and new arrays. It returns
  whether anything landed and the path to select, if any. It is pulled out of `ContentView` so it can be tested.
- The handler sets `pendingSelectPath` from that path and calls
  `GalleryStore.scheduleScan(outputDir:)`. That method cancels and restarts a 250 ms
  trailing `Task` before it calls `scan`.
- The other `scan` callers (launch, output-dir change, deletes) stay immediate.
- `scanGeneration` already throws away stale results.
- `activate(thumbnailDirectory:)` cancels a pending scheduled scan. Its `scanGeneration`
  bump only discards a scan already running, so without the cancel a profile switch
  inside the delay would load the previous library into the new one.

This fixes F7 for landings that happen together. It does **not** make a sequential
batch scan less often: local images land one seed at a time, seconds apart, so each one
still gets its own scan. An incremental `gallery.insert(paths:)` would fix that. It is
out of scope.

**D7. Replay is one action over `AnySidecar` (PR 3).** Replay crosses families: it
moves the shared picker and arms `ContentView`'s `suppressedModelObservers` guard
before it applies the family's form. So it lives in the App layer, not on a queue.
- `App/ReplayAction.swift` switches once on `AnySidecar`, with
  `enum ReplayMode { case remix, applySettings }`.
- One closure, `onReplay: (AnySidecar, ReplayMode) -> Void`, replaces the family-typed
  closures at all four sites:
  - `PreviewPaneView` and `JobCompletedPreviewView` (10 closures today)
  - `GalleryItemDetailView` (5 Apply Settings buttons with `corrected*` helpers)
  - `ContentView.applySettingsAction(for:)` (a five-step `if var meta = item.xMetadata` chain)
  - `FailedJobView`'s `onLoadSettings`
- A `GalleryItem.sidecar: AnySidecar?` accessor backs the gallery sites.
- `FailedJobView`'s "Load Settings" button is renamed **"Apply Settings"**. It does the
  same thing. See `GLOSSARY.md`.

**D8. Skip the `ParamsState` protocol (C6).** It would mostly be forced conformances.
For example, Ideogram has a caption document and Qwen has edit refs.

**Payoff:** The real win is App-layer sanity. The 11 completion `onChange` blocks and
the switches in `FamilyQueues`, `restoreActiveJobPreview`, `GenerateAction`, the queue
drawer and replay go away, and `FamilyQueues` gets tests. A model add still touches
roughly 18–20 files, because `PreviewPaneView` keeps its per-family case. Recount
after PR 3.

---

## Part 3: Descriptor registry (parked; decide after PR 3)

**Why:** Parts 1 and 2 bring the cost of a model add to roughly 18–20 files. Swift
does not set that number. Most of the remaining edits are exhaustive `switch`es over
`ModelFamily` that are spread across the codebase. A descriptor registry can bring the
floor to **about 6–8 new files, one registration line, and no edits to existing
switches.**

**Where the remaining edits come from:**
- **New code that every design needs (about 7):**
  - the job model
  - the runner spec
  - the params view and its state
  - the settings form
  - the metadata sidecar type
  - the catalog entries
  - the `tools.txt` line
- **Registration edits (about 11–13):**
  - `ModelPickerView`
  - `ParamsPanelView`
  - `PreviewPaneView` (its `PreviewState` case and `jobPreview` branch, kept by D4)
  - `GalleryItemDetailView`
  - `ImageMetadataInfo`
  - `DimensionConstraints`
  - `GalleryStore`
  - `AnySidecar`
  - `ReplayAction`
  - the per-family `lastX` fields in `AppSettings`
  - the construction and environment injection in `MLXBitsImageStudioApp`
  - the gallery views

  A registry removes these edits.

**Design:**
- Add `protocol FamilyDescriptor` with these static requirements:
  - the family's identity, its `PythonTool`, and its `DimensionConstraints`
  - its sidecar type, and how to decode that type
  - its metadata info rows
  - how to replay a sidecar
  - a `Codable` snapshot of the last-used form
  - `makeParamsPanel(...)` and `makeSettingsForm(...)`, each returning `AnyView`
- Add `FamilyRegistry.all: [any FamilyDescriptor.Type]` in `GenerationCoordinator.runOrder`
  order. Each switch becomes a lookup or a loop. A missing requirement is a compile
  error, so most of the compiler's guidance for an add stays.
- Replace the five identical 12-line store shells with one generic
  `FamilyJobStore<Job>`. SeedVR2 keeps its own store, because it is 19 lines and has
  extra behaviour. Check that the `ProfileScopedJobStore` and `GenerationJobStore`
  conformances still hold on the generic type.
- Drawers and views get their family's queue through the registry, so the per-family
  store and runner entries in `.environment(...)` go away.
- Move the per-family `lastX` settings into one dictionary keyed by family, holding
  `Codable` snapshots. Add a decode shim that reads the old `profile.json` keys once.
  This is a migration, so test it against a real profile.

**Trade-offs:**
- **Behaviour outside the descriptor is not checked by the compiler.** An exhaustive
  switch makes the compiler flag every place a new case must be handled. A protocol
  flags only its own requirements. Anything outside the descriptor silently gets no
  handling for the new family. This is the same reason D4 keeps `PreviewState`'s cases.
- **Type erasure:** the params panels and settings forms are built through `AnyView`.
  The cost is negligible for a fixed 350pt panel, but the code is less idiomatic SwiftUI.
- **The Flux picker stays special.** It owns `model` for every family. The registry
  can drive the picker's menu, but replay must still move the picker first.

**Recommended stopping point:**
1. **Phase 3a:** Do the generic store, and move the gallery, metadata, constraint and
   sidecar switches onto the descriptor. This is low risk and reaches about 8 files.
2. **Phase 3b:** Erase the params panels and settings forms, and migrate the settings.
   Do this only if several more families are expected.

**Verification:** Do everything in the PR 2 and PR 3 checks. Also:
- Load a `profile.json` from before the migration, and confirm that each family's form
  comes back as it was saved.
- Confirm that the gallery decodes, displays and replays a sidecar from every family.
- As a dry run, sketch the file list for a new placeholder family and confirm that it
  matches the count above.

---

## Sequenced PRs

### PR 1: Audit fixes (merged, #128)

- [x] F6: `Stores/JobHistoryFile.swift`.
- [x] F13: `Utilities/MfluxProbes.swift`.
- [x] F14: `Utilities/ImagePasteboard.swift`.
- [x] F8: `Utilities/ComfyUIClient.swift`.
- [x] F4: `Runner/JobRunner.swift`.
- [x] F17: `Models/IdeogramCaption.swift`.
- [x] F3: the fingerprint strength assertions.

### PR 2: Family queues

- [x] New file `Runner/FamilyQueue.swift`: `protocol AnyFamilyQueue` and
      `struct FamilyQueue<Spec>`, holding `family`, `store` and `runner` (D1). It
      exposes `isRunning`, `hasWaitingJobs`, `activeJobID`, `history`, `landing`,
      `activePreview`, `runNext(settings:coordinator:timing:)`, `cancel()` and
      `restart(_:) -> Bool` (D3).
- [x] Each Spec: `static func preview(_ job: Job) -> PreviewState` (D4).
- [x] `App/FamilyQueues.swift`: `all` in run order plus the shared dependencies, with no
      typed fields (D2). Loops for `activeJobID`, `isAnyRunning`, `histories`, `pump`,
      `stopAll`, `hasWaitingJobs`, `restart` and `landings`. `pump` keeps the Flux-only
      `driverController.eject` rule. `enqueue` takes a `FamilyQueue<Spec>`.
- [x] `App/GenerateAction.swift`: 5 typed `FamilyQueue<Spec>` fields, used by its
      `queue(...)` helper.
- [x] `Runner/JobRunner.swift`: `Landing` replaces `lastCompletedOutputPath` and
      `batchImageLanded` on every landing path. Only the first landing of each run
      selects (D5).
- [x] `Stores/GalleryStore.swift`: `scheduleScan(outputDir:)` with a 250 ms trailing
      debounce (D6).
- [x] `App/ContentView.swift`: `restoreActiveJobPreview` becomes a loop. `restart` goes
      through `queues.restart(previewState.previewedJob)`. One `onChange(of: queues.landings)`
      replaces the 11 completion blocks and calls the pure landing diff, then
      `scheduleScan`. This fixes F5 and F7.
- [x] Tests:
  - `Tests/FamilyQueuesTests.swift`, with fake queues: `pump` follows run order;
    `pump` does nothing while any queue runs; `restart` routes a job to its own queue
    only; `stopAll` cancels every queue; `isAnyRunning` and `activeJobID` aggregate.
    The real `MfluxDriverController` is fine here: `eject` does nothing when no model
    is loaded.
  - Landing-diff tests: new landings found per queue, which landing selects, two
    queues changing at once, and a later landing of the same run where only `seq`
    changes (what F5 needed).
  - No tests for the runner's landing emission: it sits inside process-driving code.
- [x] `Tests/GalleryScheduledScanTests.swift`: a scheduled scan waits for the default
      delay, rescheduling replaces the pending scan, and `activate` cancels it.
- [x] AGENTS.md recipe: the lines PR 2 changes (steps 4, 5 and the `ContentView`,
      `FamilyQueues` and `GenerateAction` part of step 9), so the recipe is right
      between the two merges.
- [x] In-app verification, steps 1–3 under Verification (2026-11-24).

### PR 3: Preview and replay

- [ ] Add `App/ReplayAction.swift`, which switches once on `AnySidecar`, with
      `ReplayMode = .remix | .applySettings` (D7).
- [ ] Add a `GalleryItem.sidecar: AnySidecar?` accessor.
- [ ] One `onReplay` closure through `PreviewPaneView`, `JobCompletedPreviewView`,
      `GalleryItemDetailView`, `ContentView.applySettingsAction(for:)` and `FailedJobView`.
- [ ] Rename `FailedJobView`'s "Load Settings" button to "Apply Settings".
- [ ] `ContentView.queueSheet`'s `previewSelection(...)` calls and `GenerateAction`'s
      `preview:` arguments use `Spec.preview` (D4).
- [ ] Update the replay and preview parts of the AGENTS.md "add a model family" recipe
      (step 9's `PreviewPaneView`, `GalleryItemDetailView` and replay touchpoints, and
      `App/ReplayAction.swift`). PR 2 already updated its own lines.

### PR 4+ (optional): Descriptor registry

- [ ] Decide after PR 3, with a fresh file count for a model add.
- [ ] Phase 3a: `FamilyDescriptor` and `FamilyRegistry`, the generic `FamilyJobStore<Job>`,
      and the gallery, metadata, constraint and sidecar switches moved onto the
      descriptor. See Part 3.
- [ ] Phase 3b, only if several more families are planned: erase the params panels
      and settings forms, and migrate the `lastX` settings.

**Out of scope:** collapsing `PreviewState` into one job case (D4), the `ParamsState`
protocol (C6), an incremental `gallery.insert(paths:)` (D6), and F2, F15, F16, F18 and
F20.

## Verification

- For each PR, run the lint gate, then the full test suite. Confirm that the jscpd
  share does not rise.
- PR 2 and PR 3, in the built app. The app can't switch family while a run is in
  progress, so a cross-family queue can't be built by hand. The checks that need one
  are covered by unit tests instead (below).
  1. Confirm that the gallery selects the first image of a run and does not move the
     selection when later images of the same run land. Check this on a local batch
     and a ComfyUI batch.
  2. In one family, run two batches of the same size back to back. Confirm that the
     gallery shows every image of both.
  3. Retry a failed job from the drawer.
  4. PR 3: use Remix and Apply Settings for every family, from the completed
     preview, from the gallery detail view and from a failed job.
- Covered by unit tests, not in the app:
  - The hand-off follows run order, waits while any queue runs, and retry routes a job
    to its own queue (`FamilyQueuesTests`).
  - Images that land together cost one scan, and a profile switch cancels a pending
    one (`GalleryScheduledScanTests`, `LandingDiffTests`).
