# Audit Fixes and Family Lanes: Improvement Plan

> **Status: PARKED (2026-11-21).** Reviewed but not scheduled. Before you pick it up,
> check every file and line reference against the current `main`. The verdicts were
> made against `08435d4`.

**Goal:** Fix the real bugs from the 2026-11-21 Ponytail audit. Then replace the
six-way family enumeration in the App layer with one generic lane per family. This
makes model adds cheaper and lets `FamilyQueues` be tested.

**Inputs, each checked against the code:**
- `docs/ponytail-audit-2026-11-21.md`: 20 findings, of which the audit itself kept 14.
- The Family Registry design spec. It is an out-of-repo draft, so its relevant content
  is summarised in Part 2.

**Tech stack:** Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, SwiftUI, Swift Testing.

## Global constraints

- Lint gate, which must pass before every commit:
  `swiftformat --lint --config .swiftformat .` and
  `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
- Tests: `xcodebuild -project "MLXBits Image Studio.xcodeproj" -scheme "MLXBits Image Studio" test`
- A clean build has zero warnings. CI fails a PR that raises jscpd's duplicated-token
  share by more than 0.1 points.

---

## Part 1: Audit, re-verified

### Fix in PR 1 (real and cheap)

| # | Verdict | Fix |
|---|---|---|
| F6: queue save swallows errors | Real. `JobHistoryFile.write` uses `try?` three times. Severity: **should-fix, not must-fix.** The write is `.atomic`, so a failure leaves the previous file intact and loses only the newest change. | Make `write` throw. In `save()`, set `saveError` on the store, using the same pattern as `AppSettings.saveError` and `LoraLibraryStore.saveError`, and show it to the user. |
| F13: a probe timeout is cached as "unsupported" | Real, and the doc comment on `runProbe` admits it. `runProbe` returns nil on a timeout, `== "1"` turns that into `false`, and `baseModelCache` stores the `false`. | Make the probe closure return `Bool?`, and do not cache nil. Check whether `ProbeCache` can skip storing a value. If it cannot, add a path that does not cache. Keep the 60 s timeout. |
| F14: two pastes collide on one temp file | Real, but rare. | Add a UUID suffix to the file name. This is a one-line change. |
| F8: a lost ComfyUI prompt polls for 1 hour | **The problem is real, but the audit's fix is wrong.** For an unknown id, ComfyUI answers `/history/{id}` with **200 `{}`**, not 404, so the proposed 404 check never fires. A non-2xx answer (for example 5xx) is also silently treated as pending. | After N empty polls, check `/queue`. If the id is not in the running list or the pending list, fail the job with "prompt lost — server may have restarted". Count non-2xx answers toward `consecutiveFetchFailures`. Before you write code, confirm the 200 `{}` behaviour against a live ComfyUI server. |
| F4: `sessionCompleted` / `inSession` are dead | Real. There are 7 hits, all writes, all in `Runner/JobRunner.swift`. | Delete both properties. Keep `activeJob = nil` in the else branch. |
| F17: caption encode drops `artStyle` | Real, but reachable only from foreign JSON. | Change `isPhotoMode` to `photo?.isEmpty == false`. Add a round-trip test. |
| F3: no fingerprint test for a strength-only change | A test gap only. | Add one assertion per family. |

### Drop (the audit is wrong)

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

### Folded into Part 2

- **F5** (a `batchImageLanded` overwrite can skip one rescan) and **F7** (one full gallery
  scan per completion) both come from the six completion `onChange` blocks in
  `ContentView`. The single completion handler in PR 2 fixes both of them.

---

## Part 2: The Family Registry spec, re-verified

**What the spec proposes:** `FamilyQueues` holds one `FamilyBinding` per family.
`PreviewState` collapses to three cases. Replay moves onto the binding. A new
`ParamsState` protocol is added across the five panel states (C6). A single aggregated
completion path replaces the six completion `onChange` blocks (C9).

**Verdict:** The direction is right, but the design needs corrections. Build a smaller
version.

**Facts the spec gets wrong:**
- `FamilyQueues` is a `struct` that `ContentView` builds on demand from its environment.
  It has no stored state, so making it `@Observable` gains nothing.
- `isRunning` is on the store, not the runner.
- The runner has no `run(job:)`. Enqueue is already generic
  (`FamilyQueues.enqueue<Spec>`).
- `App/GenerateAction.swift` already exists (#117). A `binding.generate()` would duplicate it.
- Defaults are already keyed by variant (`AppSettings.defaults(for:)`).
- Only the Flux `ParamsPanelState` has `model`. It is the picker for every family.

**Design holes and their corrections:**
1. A non-generic `FamilyBinding` cannot hold six different `JobRunner<Spec>` types.
   Use a generic `FamilyLane<Spec>` behind a protocol `AnyFamilyLane`. No downcast is
   then needed, and tests can use fake lanes.
2. `.activeJob(FamilyBinding)` loses *which* job the preview shows. The drawer previews
   and retries failed or finished jobs that are no longer `activeJob`. Use
   `case job(any QueueListedJob)` instead.
3. An aggregated `completedPath` cannot be computed, because six values stay set after
   each run. A "first non-nil" aggregate misses the second family to finish. Drive
   completion from each lane's `onImagesLanded` event.
4. Replay crosses families. It moves the shared picker and arms ContentView's
   `suppressedModelObservers` guard before it applies the family's form, so one binding
   cannot do it alone. Use one `ReplayAction` over the existing `AnySidecar`.
5. The proposed `ParamsState` protocol (C6) would mostly be forced conformances. For
   example, Ideogram has a caption document and Qwen has edit refs. **Skip it.**

**Payoff:** A model add touches about 18 files instead of 24, so it does not become a
single registration. The real win is App-layer sanity: about 150 lines of switches and
duplicate `onChange` blocks go away, and the new `FamilyQueues` gets tests.

---

## Part 3: Descriptor registry (optional, after PR 3)

**Why:** Parts 1 and 2 bring the cost of a model add to about 18 files. Swift does not
set that number. Most of the remaining edits are exhaustive `switch`es over
`ModelFamily` that are spread across the codebase. A descriptor registry can bring the
floor to **about 6–8 new files, one registration line, and no edits to existing
switches.**

**Where the 18 come from:**
- **New code that every design needs (about 7):**
  - the job model
  - the runner spec
  - the params view and its state
  - the settings form
  - the metadata sidecar type
  - the catalog entries
  - the `tools.txt` line
- **Registration edits (about 11):**
  - `ModelPickerView`
  - `ParamsPanelView`
  - `GalleryItemDetailView`
  - `ImageMetadataInfo`
  - `DimensionConstraints`
  - `GalleryStore`
  - `AnySidecar`
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
- Drawers and views get their family's lane through the registry, so the per-family
  store and runner entries in `.environment(...)` go away.
- Move the per-family `lastX` settings into one dictionary keyed by family, holding
  `Codable` snapshots. Add a decode shim that reads the old `profile.json` keys once.
  This is a migration, so test it against a real profile.

**Trade-offs:**
- **Behaviour outside the descriptor is not checked by the compiler.** An exhaustive
  switch makes the compiler flag every place a new case must be handled. A protocol
  flags only its own requirements. Anything outside the descriptor silently gets no
  handling for the new family.
- **Type erasure:** the params panels and settings forms are built through `AnyView`.
  The cost is negligible for a fixed 350pt panel, but the code is less idiomatic SwiftUI.
- **The Flux picker stays special.** It owns `model` for every family. The registry
  can drive the picker's menu, but replay must still move the picker first.

**Recommended stopping point:**
1. **Phase 3a:** Do the generic store, and move the gallery, metadata, constraint and
   sidecar switches onto the descriptor. This is low risk and reaches about 8 files.
2. **Phase 3b:** Erase the params panels and settings forms, and migrate the settings.
   Do this only if several more families are expected.

**Verification:** Do everything in the Part 2 checks. Also:
- Load a `profile.json` from before the migration, and confirm that each family's form
  comes back as it was saved.
- Confirm that the gallery decodes, displays and replays a sidecar from every family.
- As a dry run, sketch the file list for a new placeholder family and confirm that it
  matches the count above.

---

## Sequenced PRs

### PR 1: Audit fixes

- [ ] F6: `Stores/JobHistoryFile.swift`. `write` throws. The store sets `saveError`, and
      the error is shown to the user. Test that the error propagates.
- [ ] F13: `Utilities/MfluxProbes.swift`. Do not cache a nil probe result. Test that a
      nil result is not cached.
- [ ] F14: `Utilities/ImagePasteboard.swift`. Add a UUID suffix to the temp file name.
- [ ] F8: `Utilities/ComfyUIClient.swift`. Cross-check against `/queue`, and count
      non-2xx answers as failures.
- [ ] F4: `Runner/JobRunner.swift`. Delete the dead session state.
- [ ] F17: `Models/IdeogramCaption.swift`. Fix `isPhotoMode` and add a round-trip test.
- [ ] F3: add the fingerprint strength assertions.

### PR 2: Family lanes

- [ ] New file `Runner/FamilyLane.swift`: `protocol AnyFamilyLane` and
      `final class FamilyLane<Spec>`. The lane wraps the runner, store, settings,
      coordinator and timing.
- [ ] `App/FamilyQueues.swift` stays a struct. It holds `lanes` in
      `GenerationCoordinator.runOrder` order, plus the typed fields that `enqueue` and
      the drawers still need.
- [ ] Turn `activeJobID`, `isAnyRunning`, `pump`, `stopAll`, `hasWaitingJobs` and `restart`
      into loops over the lanes. Keep the Flux-only `driverController.eject` rule.
- [ ] `App/ContentView.swift`: turn `restoreActiveJobPreview` into a loop. Replace the 11
      completion `onChange` blocks with one `onImagesLanded` handler that debounces
      `gallery.scan`. This fixes F5 and F7.
- [ ] Add `Tests/FamilyQueuesTests.swift`, which uses fake lanes.

### PR 3: Preview and replay

- [ ] `PreviewState` becomes `idle | job(any QueueListedJob) | galleryItem`.
- [ ] Add `App/ReplayAction.swift`, which switches once on `AnySidecar`.
- [ ] `PreviewPaneView` and `JobCompletedPreviewView` take one remix closure instead of five.
- [ ] Update step 9 of the AGENTS.md "add a model family" recipe to list the smaller set
      of touchpoints.

### PR 4+ (optional): Descriptor registry

- [ ] Phase 3a: `FamilyDescriptor` and `FamilyRegistry`, the generic `FamilyJobStore<Job>`,
      and the gallery, metadata, constraint and sidecar switches moved onto the
      descriptor. See Part 3.
- [ ] Phase 3b, only if several more families are planned: erase the params panels
      and settings forms, and migrate the `lastX` settings.

**Out of scope:** the `ParamsState` protocol (C6), F2, F15, F16, F18 and F20.

## Verification

- For each PR, run the lint gate, then the full test suite. Confirm that the jscpd
  share does not rise.
- PR 1:
  - Use a stub interpreter that sleeps past the probe timeout. Confirm that the next
    job probes again.
  - Restart ComfyUI during a job. Confirm that the job fails quickly instead of after
    1 hour.
- PR 2 and PR 3, in the built app:
  1. Queue Flux, Krea 2 and SeedVR2 jobs together.
  2. Confirm that the queues hand off in run order.
  3. Confirm that the gallery auto-selects the result of each family.
  4. Confirm that a batch of 10 images triggers only a few scans.
  5. Retry a failed job from the drawer.
  6. Preview a drawer row while another family runs.
  7. Use Remix and Apply Settings for every family.
