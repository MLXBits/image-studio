# Model Manager Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dedicated "Models" window that teaches which model to pick and manages every app-owned cached model (download / remove per quant), replacing the download UI in Settings ▸ Models.

**Architecture:** A pure layer (`RAMFit`, `ModelGuide`, `ModelInventory`) computes everything the window shows and is unit-tested. `WeightDownloadStore` is re-keyed per download target so quants (and SeedVR2 sizes) download independently. A `Window` scene hosts a `NavigationSplitView`; a small `ModelManagerRouter` carries the selection in and "use this model" requests out to `ContentView`.

**Tech Stack:** Swift 6 (default `MainActor` isolation), SwiftUI, Swift Testing, Python 3 (`Resources/hf_cache_probe.py`, `unittest`).

**Spec:** `docs/superpowers/specs/2026-11-22-model-manager-window-design.md`

## Global Constraints

- Read `AGENTS.md` first. Never edit `.xcodeproj`; `Views/` is one source path in `project.yml`, so `Views/ModelManager/` needs no manifest change.
- Every unannotated declaration is `@MainActor`. Anything used from `Task.detached` needs `nonisolated` on the type **and** its extensions. No `@unchecked Sendable`, no `nonisolated(unsafe)`.
- Icon-only buttons use `.buttonStyle(.iconButton)` (28pt) or `.iconButtonCompact` (22pt, chips/list rows only). No hand-rolled frames.
- Never delete a hub repo folder by hand when `hf cache rm` can run (shared blob store).
- Every model loads `mflux-community/<stem>-mflux-<level>` (`FluxModelVariant.publishedRepoID`); SeedVR2 and Gemma are the only non-community repos and come from mflux / settings, never hard-coded revisions.
- Lint gate before every commit, both must pass:
  `swiftformat --lint --config .swiftformat .` and
  `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
- Focused test run: `xcodebuild test -project "MLXBits Image Studio.xcodeproj" -scheme "MLXBits Image Studio" -only-testing:"MLXBits Image StudioTests/<Suite>" 2>&1 | grep -E "<Suite>|passed|failed|error:"`
- Full gate per PR: `xcodebuild … test` (all), Debug build with zero warnings, jscpd share not up >0.1 pts, `python3 -m unittest discover -s scripts/tests`.
- No AI attribution in commits or PR bodies. One CodeRabbit CLI review per branch before opening its PR.
- Three PRs, each on its own branch off `main`: `feat/model-manager-core` (Tasks 1–3), `feat/model-manager-window` (Tasks 4–8), `feat/model-manager-tools` (Tasks 9–10). Settings cleanup lands in PR 2 (Task 8) so the old and new download UIs never coexist on `main` (jscpd).

## Review Focus

1. **A download running when the window closes** must keep running and its row must reappear on reopen; only finished/failed rows clear. → test in Task 4 (`dismissFinishedKeepsRunningRuns`).
2. **Two quants of one model downloading at once** must not overwrite each other's row or cancel each other. → test in Task 4 (`twoQuantsOfOneModelRunSideBySide`).
3. **Removing Gemma, then running the Scenario Generator in the same launch** must re-download, not fail with missing weights. → test in Task 10 (`forgetMakesTheNextEnsureFetchAgain`).
4. **Disk total with hf 2.x shared blobs** (Klein and Klein Base linking the same text-encoder blob) must count the blob once. → test in Task 3 (`aBlobLinkedFromTwoReposCountsOnce`).
5. **"Use this model" for a model already selected** (no `onChange` fires) must still apply the chosen quant. → covered by the pure helper test in Task 3 (`preferredQuantize…`) plus the explicit branch in Task 7, Step 2; checked manually in Task 7, Step 4.

---

## PR 1 — `feat/model-manager-core`

### Task 1: `RAMFit`, shared by the picker and Settings header

**Files:**
- Create: `Utilities/RAMFit.swift`, `Views/Shared/RAMFit+Color.swift`
- Modify: `Views/ParamsPanel/ModelPickerView.swift` (`vramEstimate`, ~L229-245), `Views/Settings/ModelDefaultsView.swift` (`modelHeader`, `vramColor` ~L232)
- Test: `Tests/RAMFitTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum RAMFit: Equatable, Sendable {
      case comfortable, tight, strained, tooBig
      static func of(ramGB: Double, physicalGB: Double) -> RAMFit
      static var physicalGB: Double            // ProcessInfo.processInfo.physicalMemory / 1_073_741_824
      var tooltip: String
  }
  extension RAMFit { var color: Color }       // .green .yellow .orange .red
  ```

- [ ] **Step 1: Write the failing test** — `RAMFitTests`:
  ```swift
  @Test(arguments: [(9.0, RAMFit.comfortable), (9.6, .tight), (12.8, .strained), (14.4, .tooBig), (20.0, .tooBig)])
  func fitIsTheShareOfPhysicalRAM(ram: Double, expected: RAMFit) { #expect(RAMFit.of(ramGB: ram, physicalGB: 16) == expected) }
  @Test func unknownPhysicalRAMIsTooBig() { #expect(RAMFit.of(ramGB: 1, physicalGB: 0) == .tooBig) }
  @Test func everyFitHasATooltip() { for f in [RAMFit.comfortable, .tight, .strained, .tooBig] { #expect(!f.tooltip.isEmpty) } }
  ```
  (Boundaries: fraction `< 0.6` comfortable, `< 0.8` tight, `< 0.9` strained, else tooBig — 9.6/16 = 0.6 exactly is `tight`.)
- [ ] **Step 2: Run, expect FAIL** (`RAMFit` undefined).
- [ ] **Step 3: Implement `RAMFit`.** Tooltips: comfortable "Fits your Mac well", tight "Tight — may be slower on this Mac", strained "Very tight — expect swapping and slow runs", tooBig "Likely too big to run on this Mac".
- [ ] **Step 4: Switch callers.** `ModelPickerView.vramEstimate` uses `RAMFit.of(ramGB: gb, physicalGB: RAMFit.physicalGB).color`; `ModelDefaultsView.modelHeader`'s `vramColor` does the same (drops the fixed 18/30 GB cutoffs).
- [ ] **Step 5: Run `RAMFitTests`, expect PASS; lint gate.**
- [ ] **Step 6: Commit** `feat: one RAM-fit rule for the picker and Settings`.

### Task 2: `ModelGuide` — per-model teaching copy

**Files:**
- Create: `Models/ModelGuide.swift`
- Test: `Tests/ModelGuideTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct ModelGuide: Equatable, Sendable { let blurb: String; let greatAt: [String]; let note: String? }
  extension FluxModelVariant { nonisolated var guide: ModelGuide }   // exhaustive switch, no `default`
  ```

- [ ] **Step 1: Write the failing test**:
  ```swift
  @Test func everyModelHasABlurbAndTags() {
      for m in FluxModelVariant.allModels {
          #expect(!m.guide.blurb.isEmpty, "\(m)"); #expect((1 ... 4).contains(m.guide.greatAt.count), "\(m)")
      }
  }
  @Test func blurbsAreDistinct() { #expect(Set(FluxModelVariant.allModels.map(\.guide.blurb)).count == FluxModelVariant.allModels.count) }
  @Test func ideogramNotesItsGatedRepos() { #expect(FluxModelVariant.ideogram4.guide.note?.contains("token") == true) }
  ```
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write the copy.** 2–3 plain sentences per model, 1–4 short tags, drawn from `docs/models/*.md`, the catalog (`isStepDistilled`, `defaultSteps`, `supportsNegativePrompt`) and mflux docs. Required notes: Ideogram 4 — Q8/Q4 gated, accept access and set an HF token in Settings ▸ Advanced; Qwen-Image 2.1 — does Generate and Edit; Z-Image (base) — takes a negative prompt. `custom` gets a one-line generic guide. Mark the PR body "copy needs owner review".
- [ ] **Step 4: Run, expect PASS; lint gate.**
- [ ] **Step 5: Commit** `feat: add per-model guide copy for the model manager`.

### Task 3: `ModelInventory` — sections, rows, preferred quant, disk total

**Files:**
- Create: `Stores/ModelInventory.swift`
- Test: `Tests/ModelInventoryTests.swift`

**Interfaces:**
- Consumes: `RAMFit` (Task 1); `FluxModelVariant.approximateSizeGB(quantize:)`, `baseWeightLabel`.
- Produces:
  ```swift
  nonisolated struct QuantStatus: Equatable, Sendable { let quantize: Int; let label: String; let cached: Bool; let sizeGB: Double; let ramGB: Double; let fit: RAMFit }
  struct ModelRow: Equatable, Identifiable { let model: FluxModelVariant; let quants: [QuantStatus]; let toolMissing: Bool; var id: FluxModelVariant { model } }
  nonisolated struct ModelSection: Equatable, Identifiable, Sendable { let title: String; let models: [FluxModelVariant]; var id: String { title } }
  enum ModelInventory {
      static let quantOrder = [0, 8, 4]
      static let sections: [ModelSection]
      static func row(for model: FluxModelVariant, isCached: (Int) -> Bool, ramGB: (Int) -> Double,
                      physicalGB: Double, toolMissing: Bool) -> ModelRow
      static func preferredQuantize(_ row: ModelRow) -> Int
      nonisolated static func diskBytes(repoFolders: [URL]) -> Int64
  }
  ```

- [ ] **Step 1: Write the failing tests**:
  - `sectionsListEveryModelOnceInOrder`: `ModelInventory.sections.map(\.title) == ["FLUX.3", "FLUX.2", "Ideogram", "Krea", "Qwen", "Z-Image"]`; flattened models `== [.flux3Klein, .flux3KleinBase, .flux2Klein9B, .flux2Klein4B, .flux2KleinBase9B, .flux2KleinBase4B, .ideogram4, .krea2, .qwen21Turbo, .zimageTurbo, .zimage]` and as a `Set` equals `Set(FluxModelVariant.allModels)`.
  - `aRowCarriesEachQuantInOrder`: `row(for: .krea2, isCached: { $0 == 4 }, ramGB: { _ in 10 }, physicalGB: 32, toolMissing: false)` → `quants.map(\.quantize) == [0, 8, 4]`, labels `["BF16", "Q8", "Q4"]`, `cached == [false, false, true]`, `quants[2].sizeGB == 15.8`, `quants[0].fit == .comfortable`.
  - `preferredQuantizeIsTheLargestCachedQuantThatFits`: cached {8, 4}, RAM 8→`.strained`, 4→`.comfortable` ⇒ `4`; cached {0, 8} both comfortable ⇒ `0`; nothing cached ⇒ `8`; only cached quant is `.tooBig` ⇒ `8`. ("Fits" = `.comfortable` or `.tight`.)
  - `aBlobLinkedFromTwoReposCountsOnce`: temp dir with `store/abc` (1 MB file) and two `models--a--x/blobs/abc`, `models--b--y/blobs/abc` symlinks to it ⇒ `diskBytes == 1_048_576`.
  - `aMissingRepoFolderCountsZero`: `diskBytes(repoFolders: [nonexistent]) == 0`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** `diskBytes` walks each folder's `blobs/`, resolves symlinks, sums `fileSize` over a `Set<String>` of resolved paths (same resolution as `ModelDownloadStore.blobBytes`).
- [ ] **Step 4: Run, expect PASS; lint gate.**
- [ ] **Step 5: Commit** `feat: add the model inventory behind the model manager`. Open PR 1.

---

## PR 2 — `feat/model-manager-window`

### Task 4: Re-key `WeightDownloadStore` per download target

**Files:**
- Modify: `Stores/WeightDownloadStore.swift`, `Views/Settings/ModelDefaultsView.swift` (callers: `runs[model]`, `dismiss(model)`, `cancel(run.model)`)
- Test: `Tests/WeightDownloadStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct HFDownloadSpec: Hashable, Sendable { let repo: String; let revision: String?; let include: [String] }
  enum DownloadTarget: Hashable { case weights(FluxModelVariant, quantize: Int); case seedVR2(is7B: Bool) }
  // WeightDownloadStore
  typealias MakeProcess = (_ spec: HFDownloadSpec, _ settings: AppSettings) throws -> Process
  static func downloadArgs(_ spec: HFDownloadSpec) -> [String]   // ["download", repo] + ["--revision", r]? + ["--include", p]…
  private(set) var runs: [DownloadTarget: Run]
  func start(model: FluxModelVariant, quantize: Int, settings: AppSettings)          // kept; builds .weights + publishedRepoID spec
  func start(_ target: DownloadTarget, spec: HFDownloadSpec, expectedGB: Double, settings: AppSettings)
  func cancel(_ target: DownloadTarget)
  func dismiss(_ target: DownloadTarget)
  func dismissFinished()                    // drops every non-running run
  func deleteRepo(_ repo: String, settings: AppSettings) async   // hf cache rm model/<repo>, folder fallback, bumps revision
  // Run gains: let target: DownloadTarget; let spec: HFDownloadSpec; let expectedGB: Double  (repo == spec.repo)
  static func progressTarget(of run: Run, hubDir: URL) -> (folder: URL, totalGB: Double)   // uses run.expectedGB
  ```
  `delete(model:quantize:settings:)` keeps its signature and calls `deleteRepo` after removing the legacy `saved/` copy.

- [ ] **Step 1: Write the failing tests** (update `FakeTool.make` to `(_: HFDownloadSpec, _: AppSettings)`; existing `store.runs[model]` lookups become `store.runs[.weights(model, quantize: q)]`):
  - `twoQuantsOfOneModelRunSideBySide`: with `longRunning`, start `.krea2` q8 and q4 ⇒ both runs `.running`, `tool.launches == 2`; cancel both; wait until `runs.isEmpty`.
  - `dismissFinishedKeepsRunningRuns`: q8 `exit 0` (wait `.done`), q4 `longRunning` ⇒ `dismissFinished()` leaves only `.weights(.krea2, quantize: 4)`.
  - `downloadArgsCarryRevisionAndIncludes`: `downloadArgs(HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: "abc", include: ["a.safetensors", "b.safetensors"])) == ["download", "numz/SeedVR2_comfyUI", "--revision", "abc", "--include", "a.safetensors", "--include", "b.safetensors"]`; with `revision: nil, include: []` ⇒ `["download", repo]`.
- [ ] **Step 2: Run `WeightDownloadStoreTests`, expect FAIL.**
- [ ] **Step 3: Implement the re-key**; `toolProcess` uses `downloadArgs`. Update `ModelDefaultsView` callers to the selected model's targets (temporary — Task 8 removes this UI).
- [ ] **Step 4: Run, expect PASS (old and new tests); lint gate.**
- [ ] **Step 5: Commit** `refactor: key weight downloads per target so quants download independently`.

### Task 5: Window scene, router, list, entry chip

**Files:**
- Create: `Stores/ModelManagerRouter.swift`, `Views/ModelManager/ModelManagerView.swift`, `Views/ModelManager/ModelManagerListRow.swift`
- Modify: `App/MLXBitsImageStudioApp.swift` (new `@State router`, `Window` scene, inject into main window + Settings), `Views/ParamsPanel/ModelPickerView.swift` (chip after `InfoButton`)
- Test: `Tests/ModelManagerRouterTests.swift`

**Interfaces:**
- Consumes: `ModelInventory.sections/row`, `RAMFit.color/tooltip`, `WeightDownloadStore.runs`.
- Produces:
  ```swift
  @Observable final class ModelManagerRouter {
      enum Item: Hashable { case model(FluxModelVariant), seedVR2, gemma }
      struct UseRequest: Equatable { let model: FluxModelVariant; let quantize: Int; let id = UUID() }
      var selection: Item? = .model(.flux3Klein)
      var pendingUse: UseRequest?
      func show(_ item: Item, open: OpenWindowAction)   // sets selection (custom → nil-safe: maps .custom to .model(.flux3Klein)), opens ModelManagerView.windowID
  }
  struct ModelManagerView: View { static let windowID = "model-manager" }
  ```
  Scene: `Window("Models", id: ModelManagerView.windowID)`, `.defaultSize(width: 760, height: 520)`, `.defaultPosition(.center)`; environment: `settings`, `weightDownloads`, `modelDownloads`, `router`, `coordinator`.

- [ ] **Step 1: Write the failing test** `showingACustomModelSelectsFlux3`: `router.selection` after a pure helper `ModelManagerRouter.item(for: .custom) == .model(.flux3Klein)` and `item(for: .krea2) == .model(.krea2)` (split `show` so the mapping is a testable `static func item(for:)`).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement router + scene + list.** `NavigationSplitView`: sidebar `List(selection:)` over `ModelInventory.sections` (section headers) then a "Tools" section with placeholder SeedVR2 / Gemma rows (filled in Task 10); detail shows `Text(model.displayName)` placeholder for now. `ModelManagerListRow`: fit dot for the Q8 quant (`.help(fit.tooltip)`), name, green capsule chips for cached quants (`.font(.caption2)`), `ProgressView().controlSize(.small)` when any `runs[.weights(model, _)]` is `.running`, and " — not in this mflux install" when `toolMissing` (`model.generateTool.map { !settings.toolchain.hasTool($0) } ?? false`). `isCached` = `model.isOnDisk(quantize:savedIn:hubDir:)`; `ramGB` = `approximateRAMGB(quantize:settings:)`. Refresh verdicts with `.task(id: "\(weightDownloads.revision) \(settings.hfHubDir.path)") { await HFCacheVerdictStore.shared.refresh(settings: settings) }`; `.onDisappear { weightDownloads.dismissFinished() }`.
- [ ] **Step 4: Add the picker chip.** In `ModelPickerView`, after the `InfoButton`: `Button { router.show(ModelManagerRouter.item(for: model), open: openWindow) } label: { Image(systemName: "questionmark.circle").font(.caption) }.buttonStyle(.iconButton).help("Which model? Open the Models window").accessibilityLabel("Open Models window")`.
- [ ] **Step 5: Run tests, expect PASS; build; launch the app** — chip opens the window on the current model; window appears in the Window menu; header still fits beside Generate at minimum window width.
- [ ] **Step 6: Lint gate; commit** `feat: add the Models window and its picker entry point`.

### Task 6: Detail pane — guide + quant table with download/remove

**Files:**
- Create: `Views/ModelManager/ModelManagerDetailView.swift`, `Views/ModelManager/QuantRowView.swift`
- Modify: `Views/ModelManager/ModelManagerView.swift` (detail switch)

**Interfaces:**
- Consumes: `ModelGuide`, `ModelRow/QuantStatus`, `WeightDownloadStore.start(model:quantize:settings:)/cancel/delete/progressTarget/runs`.
- Produces: `struct ModelManagerDetailView: View { let model: FluxModelVariant }`, `struct QuantRowView: View { let model: FluxModelVariant; let status: QuantStatus }`.

- [ ] **Step 1: Header + guide.** Name (`.title2.bold()`), family line (`model.family` display + "Distilled · N steps" / "Base · N steps" as in Settings' list), `guide.blurb`, "Great at" tag capsules, `guide.note` in `.callout .secondary` when present; "Override set in Settings" caption when `settings.defaults(for:).modelRepoOverride` (or `ideogram4ModelRepoOverride`) is non-empty.
- [ ] **Step 2: `QuantRowView`.** Columns: label · "≈N GB download" · fit dot + "≈N GB RAM" (`.help(fit.tooltip)`) · status. Status by `weightDownloads.runs[.weights(model, quantize: q)]?.phase`: `.running` → elapsed + "x.x / N GB" (move `downloadedSuffix` and the `TimelineView` from `ModelDefaultsView.runningRow`) + Cancel; `.failed(msg)` → red message + Retry + `DisclosureGroup("Log")` with the monospaced log; else cached → "Cached" + Remove (`role: .destructive`); else Download. Buttons `.buttonStyle(.bordered)` at `.controlSize(.regular)`.
- [ ] **Step 3: Remove confirmation** with the existing copy: title "Delete cached weights?", message "This will permanently delete the \(label) weights for \(model.displayName) from disk. You can re-download them later." → `await weightDownloads.delete(model:quantize:settings:)`.
- [ ] **Step 4: Selection change clears finished rows** of the previous model: `.onChange(of: router.selection)` → `dismiss` each finished `.weights(old, _)`.
- [ ] **Step 5: Build; launch; manual check:** download FLUX.2 Klein 4B Q4 (~4.6 GB) — progress shows, list chip spinner appears; close and reopen the window mid-download — row still running; on finish the Q4 chip appears; Remove → chip gone and `hf cache ls` no longer lists `mflux-community/flux2-klein-4b-mflux-q4`.
- [ ] **Step 6: Lint gate; commit** `feat: show each model's guide and per-quant downloads in the Models window`.

### Task 7: "Use this model" and the first-run opening

**Files:**
- Modify: `Views/ModelManager/ModelManagerDetailView.swift`, `App/ContentView.swift` (`headerModelPicker` `onChange(of: params.model)` ~L208; sheet ~L374; launch ~L401)

**Interfaces:**
- Consumes: `ModelManagerRouter.pendingUse`, `ModelInventory.preferredQuantize`, `GenerationCoordinator.activeFamily`, `MLXBitsImageStudioApp.mainWindowID`.

- [ ] **Step 1: Detail footer.** Quant `Picker` (BF16/Q8/Q4) defaulting to `ModelInventory.preferredQuantize(row)`, and `Button("Use this model") { router.pendingUse = .init(model:quantize:); openWindow(id: MLXBitsImageStudioApp.mainWindowID) }.buttonStyle(.borderedProminent).disabled(coordinator.activeFamily != nil)` with `.help("Finish or stop the running job first")` when disabled.
- [ ] **Step 2: ContentView consumes it.** `@State private var pendingUseQuantize: Int?`. `.onChange(of: router.pendingUse)`: guard a request and `coordinator.activeFamily == nil`; if `params.model == req.model`, set `unifiedQuantize.wrappedValue = req.quantize` directly; else set `pendingUseQuantize = req.quantize` then `params.model = req.model`. In the existing `.onChange(of: params.model)`, add a first-line `defer { if let q = pendingUseQuantize { unifiedQuantize.wrappedValue = q; pendingUseQuantize = nil } }` so the quant lands after both the defaults reset and the `adoptFamilyForm` early return. Clear `router.pendingUse = nil` after handling.
- [ ] **Step 3: First run.** `@AppStorage("firstRun.modelManagerShown") private var modelManagerShown = false`; give the `OutputDirectoryPromptView` sheet `onDismiss: { guard !modelManagerShown else { return }; modelManagerShown = true; router.show(.model(.flux3Klein), open: openWindow) }`. DEBUG: where the launch path sets `showingOutputDirPrompt` (~L401), also set it when `UserDefaults.standard.bool(forKey: "showFirstRunPrompt")` inside `#if DEBUG`.
- [ ] **Step 4: Build; launch; manual check:** Use this model on Krea 2 at Q4 → main window comes forward on Krea 2, precision Q4, LoRAs reset as a menu switch would; repeat with Krea 2 already selected and Q8 → precision changes to Q8. Disabled while a job runs. Launch with `-showFirstRunPrompt YES -firstRun.modelManagerShown NO`, press Skip for Now → Models window opens on FLUX.3 Klein; relaunch without the args → it does not open.
- [ ] **Step 5: Lint gate; commit** `feat: use a model from the Models window and open it after first run`.

### Task 8: Settings ▸ Models links out instead of downloading

**Files:**
- Modify: `Views/Settings/ModelDefaultsView.swift`, `App/MLXBitsImageStudioApp.swift` (Settings scene gets `router`), `AGENTS.md`

- [ ] **Step 1: Remove** `cacheStatusRow`, `runningRow`, `cacheLogView`, `downloadedSuffix`, `deleteCachedVariant`, the delete alert, `pendingDeleteVariant`, `cacheRevision`, and the `.onChange(of: selection)` dismiss. Keep the header's RAM capsule (now `RAMFit`).
- [ ] **Step 2: Add** under the header: `Button("Manage Downloads…") { router.show(.model(selectedModel), open: openWindow) }` (and for the SeedVR2 selection, `.seedVR2`).
- [ ] **Step 3: AGENTS.md.** Repo map: add `Views/ModelManager/` to the surface list. "Recipe: add a model family" step 3: also add the variant's `guide` (`Models/ModelGuide.swift`, the compiler enforces it) and its section in `ModelInventory.sections` (a test enforces it).
- [ ] **Step 4: Full gate** — all tests, Debug build zero warnings, jscpd, lint; launch: Settings ▸ Models shows defaults and the link opens the window on that model.
- [ ] **Step 5: Commit** `refactor: Settings ▸ Models hands downloads to the Models window`. CodeRabbit review; open PR 2.

---

## PR 3 — `feat/model-manager-tools`

### Task 9: Probe mode that reports SeedVR2's download spec

**Files:**
- Modify: `Resources/hf_cache_probe.py`, `Utilities/MfluxProbes.swift`
- Test: `scripts/tests/test_hf_cache_probe.py`, `Tests/MfluxProbesTests.swift`

**Interfaces:**
- Produces:
  - CLI: `hf_cache_probe.py --download-spec <name> …` prints `{"<name>": {"repo": str, "revision": str | null, "include": [str]}}` for `seedvr2-3b`, `seedvr2-7b`; unknown names are left out. Repo from `mflux.models.common.config.model_config.AVAILABLE_MODELS[name].model_name`, revision from `mflux.models.common.resolution.model_revisions.ModelRevisions.get(repo)`, include from `mflux.models.seedvr2.weights.seedvr2_weight_definition.SeedVR2WeightDefinition3B/7B.get_download_patterns()`. `--check` also fails unless both names answer.
  - Swift: `nonisolated static func downloadSpecs(python: String?, script: URL, names: [String]) -> [String: HFDownloadSpec]?` in `MfluxProbes` (`HFDownloadSpec` gains `Decodable` with `include` defaulting to `[]`).

- [ ] **Step 1: Failing Python tests** — extend the fake mflux (`write_mflux`) with `common/config/model_config.py` (`AVAILABLE_MODELS = {"seedvr2-3b": types.SimpleNamespace(model_name="numz/SeedVR2_comfyUI"), …}`), `common/resolution/model_revisions.py` (`ModelRevisions.get` → `"rev123"`), and the two SeedVR2 definitions. Tests: `test_download_spec_reports_repo_revision_and_patterns` (exact JSON for `seedvr2-3b`: repo, `"rev123"`, `["seedvr2_ema_3b_fp16.safetensors", "ema_vae_fp16.safetensors"]`); `test_download_spec_leaves_out_unknown_names`; `test_check_fails_without_seedvr2_definitions`.
- [ ] **Step 2: Run** `python3 -m unittest discover -s scripts/tests`, expect FAIL.
- [ ] **Step 3: Implement the mode** in `hf_cache_probe.py` (own `SPECS` table next to `DEFINITIONS`; update the module docstring usage lines).
- [ ] **Step 4: Failing Swift test** `downloadSpecsDecodeTheProbesAnswer` in `MfluxProbesTests`: a fake interpreter printing the JSON (pattern: `HFCacheVerdictStoreTests.interpreter(printing:)`) ⇒ `specs["seedvr2-7b"] == HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: "rev123", include: [...])`; a failing interpreter ⇒ `nil`.
- [ ] **Step 5: Implement `downloadSpecs`** via `runProbe(python:arguments:)`.
- [ ] **Step 6: Run both suites, expect PASS; run `scripts/build-python-runtime.sh`** (its `--check` must pass against real mflux); lint gate.
- [ ] **Step 7: Commit** `feat: ask mflux for SeedVR2's pinned download spec`.

### Task 10: SeedVR2 and Gemma rows, disk-total footer

**Files:**
- Create: `Views/ModelManager/ModelManagerToolDetailView.swift`, `Views/ModelManager/ModelManagerFooter.swift`
- Modify: `Stores/ModelDownloadStore.swift` (`forget`), `Stores/ModelInventory.swift` (tool helpers), `Views/ModelManager/ModelManagerView.swift`
- Test: `Tests/ModelDownloadStoreTests.swift`, `Tests/ModelInventoryTests.swift`

**Interfaces:**
- Consumes: `MfluxProbes.downloadSpecs` (Task 9), `WeightDownloadStore.start(_:spec:expectedGB:settings:)` and `deleteRepo` (Task 4), `ModelInventory.diskBytes` (Task 3).
- Produces:
  ```swift
  // ModelDownloadStore
  func forget(_ repo: String)                       // removes every `ready` key for repo
  // ModelInventory
  nonisolated static func isCached(_ spec: HFDownloadSpec, hubDir: URL) -> Bool   // snapshots/<commit>/<each include> exists (follows links); snapshots/<revision> when that folder exists (a pinned commit), else the commit in refs/<revision> (nil ⇒ refs/main)
  static func listedRepoFolders(hubDir: URL, seedVR2Repo: String?, gemmaRepo: String?) -> [URL]  // every allModels × quantOrder hubCacheFolder that exists + tool folders that exist
  ```

- [ ] **Step 1: Failing tests:**
  - `forgetMakesTheNextEnsureFetchAgain` (ModelDownloadStoreTests): a counting `fetch` stub; `ensureAvailable("org/gemma", …)` twice ⇒ 1 fetch; `forget("org/gemma")`; once more ⇒ 2 fetches.
  - `aSpecIsCachedWhenEveryIncludeIsInItsRevision` (ModelInventoryTests): temp `models--numz--SeedVR2_comfyUI/snapshots/<40-hex commit>/` with both files, spec pinned to that commit ⇒ true; one file missing ⇒ false; files under another revision only ⇒ false; nil or branch revision resolved through `refs/` with the files in its commit ⇒ true.
  - `listedRepoFoldersSkipMissingOnes`: create only the Krea 2 Q4 folder and a Gemma folder ⇒ exactly those two URLs.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `forget`, `isCached`, `listedRepoFolders`.
- [ ] **Step 4: Tool detail view.** On appear, read `let python = try? settings.toolchain.mfluxInterpreter()` on the main actor, then `Task.detached` → `MfluxProbes.downloadSpecs(python: python, script: <bundled hf_cache_probe.py>, names: ["seedvr2-3b", "seedvr2-7b"])`.
  - **SeedVR2**: copy "Upscales an existing image. 3B is fast; 7B is sharper and slower. Both are quantized in memory, so there's one download per size." Two rows (3B, 7B): Cached / Downloading x/y GB + Cancel / Download (`start(.seedVR2(is7B:), spec:, expectedGB: <bytes of the include files once known, else 0>, …)`) / Failed + Retry. No spec ⇒ Download replaced by "Downloads on first upscale". One "Remove SeedVR2 weights" with confirm "This deletes both the 3B and 7B SeedVR2 weights from disk. You can re-download them later." → `deleteRepo(spec.repo)`.
  - **Gemma**: repo `settings.gemmaModel`; if `FileAccessPath.isLocal(repo)` show "Local model — managed outside the app" and no actions. Else Cached (`ModelDownloadStore.hasCachedWeights` + `bytesOnDisk`) + Remove (confirm, `deleteRepo` then `modelDownloads.forget(repo)`), or Download → `Task { do { try await modelDownloads.ensureAvailable(repo, settings:) } catch { downloadError = error.localizedDescription } }`, progress from `modelDownloads.active[repo]`, Cancel → `modelDownloads.cancel(repo)`. Copy: "The local language model behind the Scenario Generator and Ideogram captions."
  - List rows in Tools: chips "3B"/"7B" for SeedVR2, "✓" for Gemma.
- [ ] **Step 5: Footer** (`.safeAreaInset(edge: .bottom)` on the sidebar): `"\(GB) GB in \(hubDir path, tilde-abbreviated)"` from `diskBytes(repoFolders: listedRepoFolders(…))` computed in `Task.detached` keyed on `weightDownloads.revision`, the hub path, the Gemma repo and whether a Gemma download is running (a Gemma fetch never bumps the revision), plus a "Show in Finder" `.iconButtonCompact` (`NSWorkspace.shared.activateFileViewerSelecting([hubDir])`).
- [ ] **Step 6: Full gate; launch; manual check:** SeedVR2 3B download fetches only its two files (`hf cache ls` size ≈ the files, not the whole repo) and the 3B chip appears; an upscale then starts without downloading; Remove clears both sizes. Gemma Remove, then run the Scenario Generator ⇒ it re-downloads. Footer total matches `hf cache ls` for the listed repos. Build the App Store scheme too.
- [ ] **Step 7: Commit** `feat: manage SeedVR2 and Gemma weights and show total disk use`. CodeRabbit review; open PR 3.
