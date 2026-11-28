# Audit Fixes and Family Queues: Improvement Plan

> **Status (2026-11-27):** PRs 1–6 (#128–#131, #133, #134) and PR 4a (#132) are
> merged, and their in-app checks pass. Only the optional "Later" items remain. A second
> architecture review ran against `43dad04`; Part 4 assesses it and orders the next
> PRs (4–6). Its decisions were settled on 2026-11-25.
> Before you start a PR, check its file and symbol references against the current `main`.
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
For example, Ideogram has a caption document and Qwen has edit refs. D9 (Part 4)
amends this with a narrow protocol.

**Payoff:** The real win is App-layer sanity. The 11 completion `onChange` blocks and
the switches in `FamilyQueues`, `restoreActiveJobPreview`, `GenerateAction`, the queue
drawer and replay go away, and `FamilyQueues` gets tests. A model add still touches
roughly 18–20 files, because `PreviewPaneView` keeps its per-family case.

**Recount after PR 3:** the number did not drop. PR 3 added `App/ReplayAction.swift`
and removed `GenerationGalleryView`. `GalleryCollectionView` was always a touchpoint,
but the recipe did not list it. Each edit is now smaller: replay and preview are one
`case` per family.

---

## Part 3: Descriptor registry (parked; Part 4 orders the steps before it)

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

## Part 4: Architecture review, run 2 (2026-11-25), assessed

**Input:** an outside architecture review (Qwen Flash Next / Hermes) of `main` at
`43dad04`. It names 10 candidates, C1–C10. The review's own verifier pass was still
pending, so each claim below was checked against the code. The review agrees that the
queue, landing and replay seams from PRs 2 and 3 are done.

### Verdicts

| # | Candidate | Claims | Verdict |
|---|---|---|---|
| C1 | One registry at the injection edge | **True.** 41 `.environment(...)` calls in `MLXBitsImageStudioApp`, 25 `@Environment` in `ContentView`, a six-term `[any JobOutcomeReporting]`, 5 typed queues in `GenerateAction` and 5 params states in `ReplayAction`. | **Adopt.** It is Part 3's injection piece plus deferred minor 2. See "Shape" below. |
| C2 | A params protocol | **True, but the payoff is overstated.** `canGenerate`, `seedIsRandom`, `seedIsFixed`, `setActiveBoard` and `useInImg2Img` each switch over the five params states, about 40 lines in all. The "~120 lines" figure was not reproduced. | **Adopt in a narrow form (D9).** |
| C3 | One `activeJob(any GeneratedJob)` case | **True, but it does not answer D4.** The wrap and unwrap are real: six `Spec.preview` functions, and one `as? Spec.Job` in `ContentView.previewSelection`. But job types carry no family (D3), so getting from `any GeneratedJob` to its spec needs an `as?` chain or a new job-to-spec link. Either way, a new family no longer fails to compile in the pane. | **Reject. D4 stands.** Reconsider only if `GeneratedJob` gains an `associatedtype Spec`. |
| C4 | Remove duplication in params states, persistence and settings forms | **True.** `adoptImg2ImgSource` and `adoptResolvedPromptForImg2Img` are copied in Flux, Krea 2 and Z-Image; only the metadata type and a `?? ""` differ. `Krea2FormState` and `ZImageFormState` share 13 fields. 4 of the settings forms carry the ComfyUI file pickers. Ideogram keeps bespoke `lastIdeogram*` scalars. | **Split:** (a) the adopt helpers and the batch-seed tail: adopt, small. (b) the shared form core and (c) the `[String: ModelDefaults]` move: these are Phase 3b, and (c) is a `profile.json` migration, a one-way door. (d) hoisting the generate ceremony: only after C2. |
| C5 | Gallery menus: one rule on the sidecar | **True.** This is deferred minor 1, plus "Copy Image" written twice (the detail view writes `NSPasteboard` itself). The detail footer still offers img2img on an upscale where the menus do not. | **Adopt, first.** It is small, independent and fixes a behaviour disagreement users can see. The rule ended up on the active model, not the sidecar (D10). |
| C6 | `FamilyDescriptor` for the scattered family facts | **True.** This is Phase 3a. The six `is*` flags on `FluxModelVariant` are real. `queueStatusLabel` is a hand-written six-branch `if` chain, and adding `activeJob` and `pendingCount` to `AnyFamilyQueue` would make it a loop. | **Keep as Phase 3a.** Do the `queueStatusLabel` loop in the C1 PR. |
| C7 | Name the ComfyUI policy seam | **Partly false.** No ComfyUI API key setting exists. All four `ComfyUIClient(config:)` sites pass nil, so nothing is "silently dropped". The runner and the status poller also trim the URL the same way. The hot spot is real: 5 of the 10 commits before the plan work were poll-path fixes. `ComfyRoute.runsOnComfy` does copy the runner's gate, but on purpose, `ComfyRouteTests` covers it, and commit `2444cc2` added it as the fix. | **Defer.** Name the poll policy as its own tested type if the poll path churns again. |
| C8 | `AppSettings`: synthesized `Codable` and a migration type | Not checked in depth. The interface is deep, and the cost is the hand-written field lists. | **Defer, with Phase 3b.** It shares the migration risk of C4(c). |
| C9 | Family facts as data on `ModelFamily` | Speculative. | **Drop.** C6 absorbs the actionable half. |
| C10 | A test seam for the ComfyUI progress socket | **Partly false.** Frame decoding is tested (`ComfyProgressDecodeTests`, 6 tests). The socket loop is not, and the tracker builds its own `URLSession`. | **Defer, with C7.** |

### Shape of C1

`FamilyQueues` is rebuilt on every body evaluation (D1). That stays. The registry is
a separate object, built once in `App.init`:

- It holds the six typed `FamilyQueue<Spec>` values. A typed lookup from a mixed list
  would need a cast, so typed fields stay, and they live in one place.
- It holds the five params states, which settles deferred minor 2. (Amended in
  PR 5: the forms went into a separate `FamilyForms`. See the ruling there.)
- `GenerateAction`, `ReplayAction`, the queue drawers and the `JobOutcomeReporting`
  list read from the registry instead of from separate environment entries.
- `FamilyQueues` is still built from `registry.all`, so `FamilyQueuesTests` keeps its
  fake queues (D2 holds).

### Decisions (settled 2026-11-25)

**D9. A narrow params protocol (amends D8).** D8 rejected a full `ParamsState`
protocol, because `makeJob`, Ideogram's caption document and Qwen's edit references
would be forced conformances. That still holds. The narrow protocol covers only what
all five states already have: `seed`, `board`, `quantize`, `loras`, readiness and
`applyDefaults`. `makeJob`, img2img and the prompt field stay on the concrete types.
Readiness is not uniform yet: Flux's check is inline in `ContentView`, and the others
have both `canGenerate` and `isReadyToGenerate(settings:)`. So PR 6 first gives it one
name. It comes after C1 and goes through a `form(for:)` accessor on `FamilyForms`.

**D4 stands against review C3.** For the reason, see the table. It is recorded here so
that the second rejection is deliberate.

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

### PR 3: Preview and replay (merged, #130)

- [x] Add `App/ReplayAction.swift`, which switches once on `AnySidecar`, with
      `ReplayMode = .remix | .applySettings` (D7).
- [x] Add a `GalleryItem.sidecar: AnySidecar?` accessor, plus `replaySidecar`: an
      upscale replays its source (`AnySidecar.replayTarget`), and every gallery replay
      is filed under the board the image is in now (`filed(under:)`).
- [x] One `onReplay` closure through `PreviewPaneView`, `JobCompletedPreviewView`,
      `GalleryItemDetailView`, `ContentView.applySettingsAction(for:)` and `FailedJobView`.
      Also through `GenerationGalleryView` and `GalleryCollectionView`, whose context
      menu had its own copy of the replay chain.
- [x] Rename `FailedJobView`'s "Load Settings" button to "Apply Settings".
- [x] `ContentView.queueSheet`'s `previewSelection(...)` calls and `GenerateAction`'s
      `preview:` arguments use `Spec.preview` (D4).
- [x] Update the replay and preview parts of the AGENTS.md "add a model family" recipe
      (step 9's `PreviewPaneView`, `GalleryItemDetailView` and replay touchpoints, and
      `App/ReplayAction.swift`). PR 2 already updated its own lines.
- [x] `Tests/ReplayActionTests.swift` and `Tests/ReplayTargetTests.swift`.
- [x] In-app verification, step 4 under Verification (2026-11-27).

Deferred from the PR 3 review. Each is now placed in a PR below:
1. The family-to-source-image item ("Use as Img2Img Input" or "Use as Edit
   Reference") is written twice, in `GalleryItemDetailView` and `GalleryCollectionView`.
   The detail footer has a third form (`acceptsSourceImage`), which offers img2img
   on an upscale where the menus do not. One accessor on `AnySidecar` would settle it.
   → PR 4.
2. The five params states are listed in `GenerateAction`, `ReplayAction` and both
   their initializers in `ContentView`. One struct holding them would make a new
   family's edit one line. → PR 5.
3. The completed-job preview of an upscale offers no replay, while its gallery item
   replays the source. → PR 4, as it is the same menu-and-footer rule.

### PR 4: Gallery menu rules (review C5, C4a)

**D10. The active model decides the source-image item (settled 2026-11-25).** The
item always fed the active picker family (`ContentView.useInImg2Img`), but five
places chose whether to show it and what to call it, mostly from the image's family.
So with Qwen active, a Flux image said "Img2Img" but became an edit reference. That
was reachable only in a view left over from a family switch: the grid shows only the
active family's images.
Now one rule, `SourceImageInput.forActive(variant, fluxEditMode:)`, sets both from
the active model. Any image can be a source: an upscale, an Ideogram image, or an
image with no sidecar. FLUX 3 has no img2img, so it always offers "Use as Edit
Reference", and using it turns Edit mode on, as Qwen does (amended 2026-11-27, PR 4a;
PR 4 hid the item outside Edit mode). A custom checkpoint is the exception: its Flux
form has no Generate/Edit switch, so outside Edit mode a custom FLUX 3 offers nothing.
The rule lives with the active model, not on `AnySidecar`.

- [x] `Models/SourceImageInput.swift`: the rule, plus `SourceImageAction` (the input
      and what choosing it does). It replaces `ModelFamily.acceptsSourceImage`.
      Both gallery menus, the detail footer, and the completed preview's menu and
      footer read it. "Adjust Boxes…" still follows the image's own Ideogram sidecar.
- [x] One "Copy Image" path: the detail menu, the completed preview and the metadata
      panel use `ImagePasteboard.copyImages`, as the grid already did. That puts the
      file URL on the pasteboard as well as the pixels.
- [x] Replay from an upscale's completed preview (deferred minor 3), through
      `SeedVR2Metadata.replaySidecar`. The source is filed under the upscale's board,
      as its gallery item does, and "Default" means no board on both paths.
- [x] One batch-seed tail: `GeneratedJob.applyBatchSeeds(count:typed:)` replaces four
      copies. `GeneratedJob.seed` is now `{ get set }`.
- [x] Ruling: the shared `adoptResolvedPrompt` helper is dropped. The three copies
      differ only in which family's sidecar they read, so merging them saves little,
      and it would force a decision about cross-family prompt adoption that nobody
      has made.
- [x] Tests: `SourceImageInputTests` (every model, Flux edit mode, FLUX 3),
      `BatchSeedsTests`, and the upscale replay cases (its board, and "Default") in `ReplayTargetTests`. A mutant
      confirmed each one.
- Deferred from the PR 4 review:
  - An upscale's completed preview reads its sidecar file each time it needs it,
    four times per body evaluation. The view is rare, but if the upscale moves to
    another board, replay quietly disappears. Read it once into `@State`.
  - No test pins that `ContentView` passes `currentSelection.variant` (a custom
    checkpoint's loads-as variant) and not `params.model`. Done in PR 4a: `forActive`
    takes the `ModelSelection`, and a test covers custom checkpoints.
- [x] In-app (2026-11-27). The grid shows only the active family's images (an upscale shows with
      its source's family), so check each family in turn. Right-click an image and an
      upscale, in the grid and in the detail view:
      1. Krea 2 active: "Use as Img2Img Input" puts the image into Krea 2's img2img input.
      2. Qwen active: "Use as Edit Reference" adds the image to Qwen's edit references.
      3. FLUX 3 active, in Generate mode: "Use as Edit Reference" turns Edit mode on
         and adds the image. In Edit mode it adds the image too.
      4. Ideogram active: the item is absent.
      5. An upscale's completed preview offers Remix and Apply Settings.

      Only a view left over from before a family switch can hold another family's
      image: the detail view or a completed preview. If either still shows after you
      switch, its item follows the new family's rule.

### PR 5: Family registry at the injection edge (review C1, C6 part)

- [x] `App/FamilyRegistry.swift`: built once in `App.init` and injected as one
      environment entry, in place of 12 store and runner entries. It holds the six
      typed queues. Its `members` list feeds `all`, the profile store's job stores,
      the outcome reporters, the dock badge and the warm driver's attachment.
- [x] Ruling: the five params states are not in the registry. They are one
      `FamilyForms` struct in ContentView's `@State`. ContentView is keyed by the
      profile, so a switch rebuilds the forms from the new profile, while the queues
      outlive it. App-level forms would carry one profile's form into the next. This
      still settles deferred minor 2: `GenerateAction` and `ReplayAction` each take
      `forms`, not five states.
- [x] `GenerateAction`, `ReplayAction` and the queue drawers read the registry. The
      drawer takes its `FamilyQueue` as a parameter, not from the environment.
      `FamilyQueues` is built from `families.all`.
- [x] `AnyFamilyQueue` gains `activeJob` and `pendingCount`, and `queueStatusLabel`
      becomes one `FamilyQueues.runningQueue` lookup.
- [x] `PreviewPaneView`'s unused `FluxJobRunner` environment read is gone.
- [x] Tests: `FamilyRegistryTests` (run order, the shared driver, job stores,
      reporters, images left) and `runningQueue` in `FamilyQueuesTests`. A mutant
      confirmed each one.
- [x] AGENTS.md recipe step 9: the registry, `FamilyForms`, and no edit to
      `MLXBitsImageStudioApp`.
- [x] In-app (2026-11-27): generate in two families and check the queue drawer, the toolbar's
      queue label, the dock badge, Stop and a retry. Switch profile while idle and
      confirm each family's form and queue come from the new profile.

### PR 6: Narrow params protocol (review C2, D9) (merged, #134)

- [x] A protocol with `seed`, `board`, `quantize`, `loras`, one readiness member and
      `applyDefaults`. All five params states conform.
- [x] `canGenerate`, `seedIsRandom`, `seedIsFixed`, `setActiveBoard` and the fixed-seed
      clear go through `forms.form(for:)`.
- [ ] ~~Then, optionally, hoist `GenerateAction`'s shared generate ceremony (C4d).~~
      Skipped: see the rulings.
- [x] In-app (2026-11-27): on each family, a fixed seed shows the Fixed Seed pill and hides the
      batch button, and the pill's ✕ clears it. New Group puts its name on that
      family's board. Generate is off with an empty prompt, and for Flux and Qwen
      in Edit mode with no reference. The header's precision follows the picker.

Rulings:

- The protocol is `FamilyParamsForm`, in `App/FamilyForms.swift`. Readiness is
  `canGenerate`: four states had it, and `isReadyToGenerate(settings:)` ignored its
  argument, so it is gone. Flux gains `canGenerate`, and its `applyDefaults(from:)`
  label becomes `settings:`.
- `FamilyForms` has `all`, `active` (the picker's family) and `clearFixedSeeds()`
  beside `form(for:)`. The onAppear defaults and the pill's ✕ loop over `all`.
- `unifiedQuantize` goes through `active` too. For a custom checkpoint it now reads
  its target family's form, not Flux's. Nothing shows it: a custom key ignores
  precision, the model button shows "loads as" instead, and no path writes it
  while a custom checkpoint is picked. One reachable effect: picking a model from
  the chevron while on a custom checkpoint carries its family's precision. If a
  precision picker is ever added for a custom checkpoint, note that one loading as
  Ideogram 4 would then also save `lastIdeogramQuantize`.
- C4d is skipped. After `PromptFanOut`, the five generates share one line (the
  `lastModel` rule), and GenerateAction has no tests: testing it queues on real
  runners.

### Later (optional): Descriptor registry

- [ ] Phase 3a: `FamilyDescriptor`, the generic `FamilyJobStore<Job>`, and the
      gallery, metadata, constraint and sidecar switches moved onto the descriptor.
      It builds on PR 5's registry. See Part 3.
- [ ] Phase 3b, only if several more families are planned: erase the params panels
      and settings forms, the shared form core (C4b), and migrate the `lastX`
      settings into the `ModelDefaults` dictionary (C4c, C8). This is a `profile.json`
      migration, so it is a one-way door.
- [ ] ComfyUI policy seam and progress-socket tests (C7, C10), if the poll path churns
      again.

**Out of scope:** collapsing `PreviewState` into one job case (D4, and review C3),
the full `ParamsState` protocol (D8; the narrow one is D9), family facts
as data on `ModelFamily` (review C9), an incremental `gallery.insert(paths:)` (D6),
and F2, F15, F16, F18 and F20.

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
