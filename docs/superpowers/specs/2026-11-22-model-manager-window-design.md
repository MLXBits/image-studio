# Model Manager window — design

## Context

New users don't know which model to pick or what fits their Mac, and power users
have no single view of what's cached. Option 4 of
`~/Downloads/mlxbits-ux-mockups/model-chooser-options.html` (two-pane helper) was
chosen and extended: the left list shows what's cached, and the detail pane both
teaches (what the model is great at, RAM fit) and manages weights (download/remove
per quant).

Today Settings ▸ Models (`Views/Settings/ModelDefaultsView.swift`) already lists
models with cached-quant chips, Download buttons and delete-with-confirm, on top of
`WeightDownloadStore`, `HFCacheVerdictStore` and `hf cache rm`. This work moves
weight management into one dedicated window with education content, and Settings
keeps only per-model defaults.

## Decisions (user)

- **Own window**, opened from a help chip beside the model switcher, and on first
  run right after the storage-location step (library step in DMG; library +
  models-folder step in App Store).
- **Left list: one row per model** (11 rows) under family headers, each with
  cached-quant chips. Plus a **Tools** section: **SeedVR2** and **Gemma prompt
  LLM**. Plus a **total disk used** footer.
- **Approach A**: pure inventory layer + compile-checked per-model guide content in
  Swift; Settings ▸ Models loses its download/delete UI and links to the window.

## Approaches considered

- **A (picked)** — new window; pure `ModelInventory` + `ModelGuide` in Swift; Settings links out. One place manages weights; the compiler enforces copy for every model.
- B — share Settings' chip/download rows between Settings and the window. Less churn, but two surfaces manage the same weights.
- C — A with copy in a bundled JSON/Markdown. Editable without rebuild, but no check that every model has copy, plus a parser.

## Goals / non-goals / anti-goals

- Goals: pick-a-model education at a glance; see every app-managed cached model and its size; download/remove any quant in one click; works in DMG and App Store builds.
- Non-goals: LoRA management; unknown `models--*` repos; ComfyUI-backend models; custom repos / Settings overrides (row notes "override set in Settings"); a ranking/recommendation engine; changing how downloads work.
- Anti-goals: a second place that downloads or deletes weights; deleting repo folders by hand when `hf cache rm` can run (shared blob store); app-side bulk scripting over user dirs.

## Design

### Window and entry points
- `Window("Models", id: ModelManagerView.windowID)` in `App/MLXBitsImageStudioApp.swift`, following the Support/About/Shortcuts scenes. Resizable, ~760×520 default.
- **Picker chip**: icon button (`.iconButton`, 28pt, `questionmark.circle` or `square.stack.3d.up`) beside the model `Menu` in `Views/ParamsPanel/ModelPickerView.swift`, after its `InfoButton`. The picker sits in the main window header (`ContentView` ~L862), not the 350pt params panel, so the 305pt budget does not apply; keep the header from crowding Generate. Opens the window with that model selected.
- **Window menu**: a `Window` scene lists itself there automatically — no extra item. A keyboard shortcut is left to the builder (check `Models/KeyboardShortcutCatalog.swift`).
- **First run**: the first time the `OutputDirectoryPromptView` sheet is dismissed (Done or Skip; `App/ContentView.swift` ~L356/374/401), open the window, gated by its own `@AppStorage("firstRun.modelManagerShown")` flag. In the App Store build that sheet can reappear later at the models step, so the flag, not the sheet, decides. DEBUG launch arg to force it, like `-supportNudgeThreshold`.
- **Settings ▸ Models**: "Manage downloads…" button opening the window with that model selected.
- Hand-off: a small app-level `@Observable ModelManagerRouter` in the environment carries (a) the row to select when the window opens, set by entry points before `openWindow`, and (b) a pending "use this model" request `(FluxModelVariant, quantize)` that `ContentView` observes. The main window's selection is `@State params` in `ContentView` (per profile), so nothing else at app level can change it.

### Left list
Sections FLUX.3 (Klein, Klein Base) · FLUX.2 (Klein 9B, Klein 4B, Base 9B, Base 4B) · Ideogram · Krea · Qwen · Z-Image (Turbo, Base) · Tools (SeedVR2, Gemma). Row = fit dot (for Q8) + name + green capsule chips for cached quants (BF16/Q8/Q4) + spinner while downloading. A model whose tool the Custom Python lacks gets the same "— not in this mflux install" note as the picker's `modelPickerRow` (which labels but does not disable). Footer: total GB on disk for listed repos, hub path, Show in Finder.

### Detail pane (generative model)
- Header: name, family, Distilled/Base · N steps.
- Blurb (2–3 sentences), "Great at" tags, optional "Good to know" line (e.g. Ideogram Q8/Q4 gated + HF token; Qwen does Generate + Edit; Z-Image Base takes a negative prompt).
- Quant table, rows BF16 / Q8 / Q4: download size (`approximateSizeGB`), RAM (`approximateRAMGB`) with fit dot + tooltip, and status/action: **Cached** (size) [Remove] · **Downloading** x / y GB [Cancel] · [Download] · **Failed** [Retry] with log disclosure. Remove confirms with the existing alert copy.
- **"Use this model"** (user: same as a picker switch): behaves exactly like choosing the model in the picker menu — `params.model`'s `onChange` resets quantize/steps to defaults and clears LoRAs and edit images as today — then applies the chosen quant (largest cached quant that fits, else Q8). Disabled while a job runs; brings the main window forward. No download is started; generation fetches as today.
- Quant rows download independently: Q8 and Q4 of one model may run in parallel. A finished or failed row and its log clear when the selection changes or the window closes; a running download carries on (#27 behaviour).

### Tools rows
- **SeedVR2**: 3B and 7B load from one upstream repo (`numz/SeedVR2_comfyUI`, per mflux `ModelConfig`), quantized in memory — so no quant chips; show 3B and 7B as two rows (each its own transformer file, sharing `ema_vae_fp16.safetensors`), each downloadable on its own; one Remove clears the repo, so both (`hf cache rm` works per repo). **Download asks the installed mflux** (user decision): add a mode to the bundled `Resources/hf_cache_probe.py` that prints the SeedVR2 repo, pinned revision (`mflux/models/common/resolution/model_revisions.py`) and include patterns (`mflux/models/seedvr2/weights/seedvr2_weight_definition.py`) as JSON; the app runs `hf download <repo> --revision <rev> --include <p>…`. A bare download would pull the whole ComfyUI repo, and an unpinned one fetches `main`, which mflux then re-downloads. Extend `--check` so a runtime build fails if the mode can't answer; add a case to `scripts/tests/test_hf_cache_probe.py`. If the probe gives no answer (old Custom Python), Download falls back to "downloads on first upscale".
- **Gemma**: the `settings.gemmaModel` repo (`gemmaModelPath`, or the default). Download via `ModelDownloadStore.ensureAvailable` in a Task (already app-owned); Remove via `hf cache rm`, then clear that repo from `ModelDownloadStore`'s launch-long `ready` set (new `forget(_:)`), or the next run would skip the fetch. If the setting is a local path, show "managed outside the app" with no actions.

### Shared pieces (reuse, don't rewrite)
- Downloads: `Stores/WeightDownloadStore.swift` (`start/cancel/delete`, `progressTarget`, `removeArgs`). Its runs are keyed by `FluxModelVariant` (one per model); re-key to a `DownloadTarget` enum — `.weights(FluxModelVariant, quantize)` and `.seedVR2(revision, patterns)` — rather than adding a second store. `dismiss` becomes per target.
- Completeness: `FluxModelVariant.isOnDisk(quantize:savedIn:hubDir:)` + `HFCacheVerdictStore.shared.refresh` on window open and on `weightDownloads.revision` change (copy the `.task(id:)` in `ModelDefaultsView`).
- Sizes: `ModelDownloadStore.blobBytes(in:)`. The footer total must dedupe by resolved blob path (hf 2.x shared store links the same blob from several repos).
- RAM fit: extract the thresholds in `ModelPickerView.vramEstimate` (fraction of physical RAM: <0.6 green, <0.8 yellow, <0.9 orange, else red) into a `nonisolated enum RAMFit` used by the picker, the window, and the Settings header's RAM capsule (which today uses fixed 18/30 GB cutoffs). Keeps four levels (my call) rather than the mockup's three, so all three agree.

### New code
- `Models/ModelGuide.swift` — `nonisolated struct ModelGuide { blurb, greatAt: [String], note: String? }` and `extension FluxModelVariant { var guide: ModelGuide }` with an exhaustive switch (no `default`). Copy drafted by me from `docs/models/*.md` and mflux docs; user reviews in the PR (my call).
- `Stores/ModelInventory.swift` — pure builder: given hubDir, cacheDir, physical RAM, toolchain-has-tool and a completeness closure, returns rows (model × quant → cached?, bytes, sizeGB, ramGB, fit) and tool rows. Unit-testable with temp dirs.
- `Views/ModelManager/` — `ModelManagerView` (split view), `ModelManagerListRow`, `ModelManagerDetailView`, `ModelManagerToolDetailView`. `project.yml` lists `Views` as one source path, so the new subdirectory needs no manifest change.
- `Utilities/RAMFit.swift`.

### Removed
- From `ModelDefaultsView`: `cacheStatusRow`, `runningRow`, `cacheLogView`, `downloadedSuffix`, delete alert and state. The header's RAM capsule stays.

## Implementation phases (three PRs; Settings cleanup folds into the window PR so two download UIs never coexist on `main`)

1. **Pure layer**: `RAMFit` (picker switched to it), `ModelGuide` + content, `ModelInventory`. Tests: `Tests/ModelInventoryTests.swift` (temp hub dirs: cached/partial/missing, dedupe total), `Tests/ModelGuideTests.swift` (every `allModels` has non-empty blurb and ≥1 tag), `RAMFit` thresholds.
2. **Window + generative models**: `DownloadTarget` re-key (update `Tests/` that cover the store), scene, router, list, detail pane, Download/Cancel/Remove/Retry, picker chip, first-run open, "Use this model".
3. **Tools + footer**: probe mode for SeedVR2 download spec (+ Python test, `--check`), SeedVR2 row, Gemma row with `forget(_:)`, deduped disk total.
4. **Settings cleanup**: strip download UI from `ModelDefaultsView`, add "Manage downloads…". Update `AGENTS.md` repo map / recipe step 9 (new surface to wire for a new family) and `GLOSSARY.md` if a term is added.

Task-level steps: `docs/superpowers/plans/2026-11-22-model-manager-window.md`.

## Verification

- `python3 -m unittest discover -s scripts/tests` (probe mode) and `scripts/build-python-runtime.sh` (runs `--check`).
- Lint gate before each commit: `swiftformat --lint --config .swiftformat .` and `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`.
- `xcodebuild -project "MLXBits Image Studio.xcodeproj" -scheme "MLXBits Image Studio" test`; Debug build with zero warnings; jscpd share not up >0.1 pts.
- Launch the built app (new `Window` scene in App): open via chip, Window menu, Settings link; DEBUG first-run arg opens it after the prompt.
- Download FLUX.2 Klein 4B Q4 (~4.6 GB): row chip and progress appear, survive closing the window; Remove → chip gone and `hf cache ls` no longer lists the repo. Footer total matches `hf cache ls` for listed repos.
- Header row still fits beside Generate at the minimum window width; check App Store scheme build too.
