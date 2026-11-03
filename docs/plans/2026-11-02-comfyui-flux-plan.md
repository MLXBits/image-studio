# Plan: ComfyUI remote path for FLUX.2 (slice 2a)

Date: 2026-11-02 · Status: planned · Spec: `docs/plans/2026-11-01-comfyui-multi-model.md` (shared multi-model spec; this is the FLUX.2 slice)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the proven ComfyUI template mechanism (slice 1, Krea 2) to **FLUX.2** (4 variants: 4b Base, 4b Distilled, 9b Base, 9b Distilled) so FLUX.2 jobs can route to a remote ComfyUI server. This requires generalizing the dynamic LoRA insertion (FLUX uses the full `LoraLoader` with model + clip, not Krea 2's `LoraLoaderModelOnly`) and adding a `FluxRunnerSpec.comfyGraph` that picks a per-variant/per-mode template. **FLUX.3 is a separate workstream** (see "FLUX.3 workstream" below) — it has distinct complexity (bounding boxes for both t2i and edit, the prompt-upsampler, no LoRAs, no i2i).

**Architecture:** FLUX.2 uses one runner (`FluxRunnerSpec`) and one `.flux` family. The runner picks a per-variant/per-mode flow key (`flux2/4b-t2i-base`, `flux2/4b-i2e-distilled`, … — 8 total, flat `<size>-<flow>-<variant>` naming), loads the bundled template + param map, builds the params, and returns a `ComfyGraph`. The generic mechanism (`ComfyTemplate`/`ComfyParamMap`/`render`) is reused; the one real change is `insertLoras` generalizing from `LoraLoaderModelOnly` (model-only) to the full `LoraLoader` (model + clip), with the model consumer found by **reference-rewrite** (FLUX.2's advanced sampler stack has no `KSampler` — the model consumer is `CFGGuider.model`).

**Tech Stack:** Swift (macOS app), Swift Testing (tests), Python (dry-run harness), live ComfyUI server (dry-run + validation).

## Context / verified findings

From three read-only analyses (variant landscape, ComfyUI node-type research, mechanism generalization):

- **One runner, FLUX.2 variants.** FLUX.2 has 4 variants: 4b Base, 4b Distilled, 9b Base, 9b Distilled. They share `ModelFamily.flux` (id `flux2`) and `FluxRunnerSpec`. The ComfyUI routing gate (`JobRunner.makeComfyTarget`, `Runner/JobRunner.swift:824-835`) is already family-level (`family.id == "flux"`) and needs no change. `FluxRunnerSpec` currently has no `comfyGraph` override (default nil, `Runner/JobRunner.swift:110-112`) — FLUX always runs locally today.
- **Modes.** FLUX.2: t2i + i2i (single-ref) + edit (multi-ref). The UI keeps i2i and edit as separate modes; i2i = edit with 1 reference (one `<variant>/edit` template handles both).
- **LoRA.** FLUX.2 uses LoRAs (`--lora-paths`, `Runner/FluxJobRunner.swift:289-293`). In ComfyUI, FLUX uses the **full `LoraLoader`** (`strength_model` + `strength_clip`), not `LoraLoaderModelOnly`. A zero-strength `LoraLoader` is a clean no-op.
- **Topology.** FLUX.2 uses a single `CLIPLoader` (type `flux2`), **not** `DualCLIPLoader` + `FluxGuidance` (that's FLUX.1). FLUX.2 t2i = advanced sampler stack (`UNETLoader`, `CLIPLoader`, `VAELoader`, `CLIPTextEncode`, `ConditioningZeroOut` for Distilled, `CFGGuider`, `KSamplerSelect`, `Flux2Scheduler`, `RandomNoise`, `EmptyFlux2LatentImage`, `SamplerCustomAdvanced`, `VAEDecode`, `SaveImage`). FLUX.2 edit = reference-conditioned (`LoadImage → ImageScaleToTotalPixels → VAEEncode → ReferenceLatent`, chained for multi-ref).
- **Base vs Distilled differ structurally:** Distilled = `ConditioningZeroOut` + cfg=1, no negative; Base = CFG + empty negative. So each variant (Base/Distilled × 4b/9b) gets its own templates. **The user has all 8 FLUX.2 templates in place** (explicitly labeled Distilled and Base).
- **Seed is flow-agnostic.** FLUX.2 t2i's seed lives on `RandomNoise.noise_seed`, not `KSampler.seed` — the parammap carries that; the per-seed closure handles it generically (like Krea 2, `Runner/Krea2JobRunner.swift:177-184`).
- **The loader already supports the flat per-variant keys (sanity-checked).** `ComfyTemplate.load(familyFlowKey:)` splits on `/` (last segment = resource, leading segments = subdir, `Utilities/ComfyTemplate.swift:248-251`), so `flux2/4b-t2i-base` → `comfy_templates/flux2/4b-t2i-base.json`. `comfy_templates` is a folder reference in the xcodeproj (`project.pbxproj:542`), so the `flux2/` subdir lands in the bundle automatically — **no pbxproj edits**. **Verified against the user's placed templates (named lowercase, flat) — compatible as-is.**

## Scope

This plan is the **FLUX.2 slice** (4 variants × t2i/edit = 8 templates). It ships a working FLUX.2 remote path on top of the slice-1 mechanism. **FLUX.3 is a separate workstream** (see below). Z-Image and Ideogram 4 remain later slices.

## File structure

- **Create** 8 param maps (the 8 templates are already in place, named lowercase) at `Resources/comfy_templates/flux2/<size>-<flow>-<variant>.parammap.json`, where `<size>` ∈ {`4b`, `9b`}, `<flow>` ∈ {`t2i`, `i2e`}, `<variant>` ∈ {`base`, `distilled`}. (i2i = i2e with 1 ref; one `<size>-i2e-<variant>` template handles both — see Open questions.)
- **Modify** `scripts/comfy_dry_run.py` — generalize `insert_loras` (`--lora-kind full|model-only`, clip chaining, reference-rewrite consumer).
- **Modify** `Utilities/ComfyTemplate.swift` — `render(map:params:loras:loraKind:)` + `insertLoras` generalization.
- **Modify** `Runner/FluxJobRunner.swift` — add `FluxRunnerSpec.comfyGraph` (FLUX.2 only).
- **Create** `Views/Settings/ModelDefaultsView+FluxForm.swift` + wire into `ModelDefaultsView.modelForm` — per-variant ComfyUI section (Inference Backend toggle + server URL + UNet/CLIP/VAE rows).
- **Test** `Tests/ComfyTemplateTests.swift`, `Tests/ComfyInsertLorasTests.swift`, `Tests/ComfyBundleLoadTests.swift` — full-LoRA chain, clip rewrite, `CFGGuider` consumer, missing-`CLIPLoader` guard, flux2 key resolution.

## Global Constraints

- Wire form is `POST /prompt` with `{nodeID: {class_type, inputs}}`; refs are `[nodeID, outputIndex]`. (shared spec §3)
- Templates + param maps are **bundled app resources**; loaded by per-variant/per-mode key; no user-facing template management.
- Parameters are anchored on **stable node IDs** via the param-map sidecar, never display names.
- **Dry-run before Swift:** each FLUX.2 template + param map is validated by the Python harness (with LoRAs) against live ComfyUI before the Swift that consumes it is written.
- **LoRA generalization must not break Krea 2:** `render` gains a `loraKind` param defaulting to `.modelOnly`, so Krea 2 + existing tests compile and pass unchanged.
- App model-file settings **override** the template's baked-in filenames.
- A param-map mismatch (mapped node/input not in the template) must **fail loudly**, never silently produce a wrong graph.
- **`imageStrength` is not applied on the reference-conditioned flows** (no denoise knob) — hide the slider when routed remote.

## Resolved design forks

1. **Upsampler slot:** N/A for FLUX.2 (FLUX.3-only; see the FLUX.3 workstream).
2. **FLUX.2 edit VAE ≠ t2i VAE:** bake the edit VAE (`full_encoder_small_decoder`) into the `<variant>/edit` templates; override only the t2i VAE via settings.
3. **Base vs Distilled:** separate templates per variant (they differ structurally: `ConditioningZeroOut` + cfg=1 for Distilled, CFG + empty negative for Base). The template key is per-variant-per-flow (e.g. `flux2/4b-t2i-base`, `flux2/4b-t2i-distilled`). The user has all 8 FLUX.2 templates in place (explicitly labeled Distilled and Base).
4. **`imageStrength` on reference flows:** hide the slider when the job routes to ComfyUI.
5. **FLUX.3 upsampler on/off:** N/A for FLUX.2 (FLUX.3-only; see the FLUX.3 workstream).

## Review Focus

1. **LoRA clip chain correctness** — the `.full` LoRA chain must feed the LoRA'd clip to **both** the positive and negative `CLIPTextEncode` nodes (a Base template has a negative encoder referencing the same `CLIPLoader`).
2. **Model consumer via reference-rewrite** — the chain tail must replace every `[unetID, 0]` reference (covers `KSampler.model`, `CFGGuider.model`, and multi-consumer graphs), not just "find the KSampler."
3. **Multi-ref overflow** — cap `editImagePaths` at the template's `source_image_N` slot count (countable from the parammap) or throw a clear error.
4. **Stale param map** — a mapped node/input absent from the template must throw (the slice-1 failure class).
5. **Per-variant template selection** — the runner must pick the correct `<variant>/<flow>` template based on the job's variant (4b/9b × Base/Distilled) + mode (t2i/edit).

## Work items, in dependency order

### Task 1: FLUX.2 param maps (templates already in place, named lowercase)

**Files:** Create 8 param maps at `Resources/comfy_templates/flux2/<size>-<flow>-<variant>.parammap.json` (the 8 templates are already in place, named lowercase) · **Depends on:** the user's FLUX.2 ComfyUI exports (API format, subgraphs flattened) — all 8 templates in place (named lowercase: `4b-t2i-base`, `4b-t2i-distilled`, `4b-i2e-base`, `4b-i2e-distilled`, `9b-t2i-base`, `9b-t2i-distilled`, `9b-i2e-base`, `9b-i2e-distilled`).

- [ ] **Step 1: Ingest the exports.** Confirm each is API format (`{nodeID: {class_type, inputs}}`, no `nodes`/`links`); confirm each `<variant>/edit` has the N-ref `LoadImage → ImageScaleToTotalPixels → VAEEncode → ReferenceLatent` chain; confirm the Base variants have `CFGGuider` + empty negative, the Distilled variants have `ConditioningZeroOut` + cfg=1.
- [ ] **Step 2: Sanity pass → param maps.** For each template, identify the `(node, input)` for the parammap keys (shapes below). Write each to `<size>-<flow>-<variant>.parammap.json`.
  - `<size>-t2i-<variant>`: `prompt`, `width`, `height`, `seed` (→`RandomNoise.noise_seed`), `steps` (→`Flux2Scheduler.steps`), `cfg` (→`CFGGuider.cfg`), `sampler` (→`KSamplerSelect.sampler_name`), `unet_name`, `clip_name`, `vae_name`, `save_subfolder`. **No** `scheduler` (Flux2Scheduler is fixed), **no** `denoise`.
  - `<size>-i2e-<variant>`: `prompt`, `source_image` (+ `source_image_1..5`, 6 slots total), `seed`, `steps`, `cfg`, `sampler`, `unet_name`, `clip_name`, `vae_name`, `save_subfolder`. **No** width/height (derived from ref via `GetImageSize`), **no** `denoise`.
- [ ] **Step 3: Validate with the harness.** Run Task 2's harness against all eight templates + param maps (t2i, and edit with a real source image). Confirm valid outputs + honored params. **Do not start Task 3 until all eight pass.**

### Task 2: Generalize the dry-run harness (non-Swift gate)

**Files:** Modify `scripts/comfy_dry_run.py` · **Produces:** `insert_loras` with `--lora-kind full|model-only`.

- [ ] **Step 1: Add `--lora-kind`.** `model-only` = current `LoraLoaderModelOnly` (Krea 2). `full` = `LoraLoader` with model + clip chains.
- [ ] **Step 2: Generalize the consumer.** Find the model consumer by reference-rewrite (replace every `[unetID, 0]` ref with the chain tail) instead of "find the KSampler" — covers `KSampler.model` and `CFGGuider.model`.
- [ ] **Step 3: Add the clip chain for `full`.** Anchor on the `CLIPLoader` feeding a `CLIPTextEncode`; each inserted node is `{model, clip, lora_name, strength_model, strength_clip}`; chain both streams; the tail clip replaces all `[clipID, 0]` refs (feeds both positive + negative encoders).
- [ ] **Step 4: Verify against live ComfyUI.** Run a FLUX.2 t2i job with LoRAs (full kind) end-to-end; confirm valid output + LoRAs honored (zero-strength = clean no-op, full-strength = distinct). Confirm the harness is the gate before Swift.

### Task 3: Generalize `insertLoras` (Swift)

**Files:** Modify `Utilities/ComfyTemplate.swift` · Test `Tests/ComfyInsertLorasTests.swift`, `Tests/ComfyTemplateTests.swift`

- [ ] **Step 1: Write the failing tests.** (a) `.full` LoRA chain wires both model + clip; (b) the model consumer via reference-rewrite feeds `CFGGuider.model` (no `KSampler` present); (c) the tail clip feeds both positive + negative `CLIPTextEncode`; (d) a missing `CLIPLoader` in `.full` mode throws; (e) Krea 2 (`.modelOnly`) is unchanged. Run → FAIL.
- [ ] **Step 2: Implement.** Add `loraKind` to `render` (default `.modelOnly`). In `insertLoras`: empty-LoRAs early return; model consumer via `[unetID,0]` reference rewrite; `.full` chains clip from the `CLIPLoader` anchor + rewrites all `[clipID,0]` refs; `strength_clip` = the app's single `strength`. Run → PASS.
- [ ] **Step 3: Run the full suite.** Confirm Krea 2 + existing tests pass unchanged. Commit.

### Task 4: Add `FluxRunnerSpec.comfyGraph` (FLUX.2)

**Files:** Modify `Runner/FluxJobRunner.swift` · Test `Tests/ComfyTemplateTests.swift` (extend) · **Consumes:** Task 3's `render(map:params:loras:loraKind:)`.

- [ ] **Step 1: Write the failing runner tests.** `FluxRunnerSpec.comfyGraph` returns a non-nil `ComfyGraph` for a FLUX.2 t2i job (each variant) and a FLUX.2 edit job (with refs); returns nil when the model-file settings are incomplete; picks the correct `<variant>/<flow>` template. Run → FAIL.
- [ ] **Step 2: Implement `comfyGraph`.** Pick the flow key by variant + mode (`flux2/4b-t2i-base`, `flux2/4b-i2e-base`, …); guard on `comfyUNet/Clip/Vae[variantID]` all set; build the params (prompt, seed, steps, cfg, width/height for t2i only); map LoRAs (full kind); upload source images for i2i/edit and set `source_image`/`source_image_N`; return a `ComfyGraph` whose render closure calls `render` per seed. Run → PASS.
- [ ] **Step 3: Run the full suite. Commit.**

### Task 5: FLUX.2 settings form

**Files:** Create `Views/Settings/ModelDefaultsView+FluxForm.swift` · Modify `ModelDefaultsView.modelForm` wiring

- [ ] **Step 1: Build the form.** Reuse `comfyBackendPicker`/`comfyServerRow`/`comfyFileRow` from `ModelDefaultsView+Krea2Form.swift`. Add: the Inference Backend toggle (per family: `comfyBackendEnabled["flux2"]`), the server URL row (`comfyURL`), the UNet/CLIP/VAE rows (per variant: `comfyUNet/Clip/Vae[variantID]`).
- [ ] **Step 2: Wire into `ModelDefaultsView.modelForm`** (the flux branch).
- [ ] **Step 3: Commit.**

### Task 6: Topology tests + bundle + live validation

**Files:** Test `Tests/ComfyTemplateTests.swift`, `Tests/ComfyBundleLoadTests.swift` · Modify the Xcode project (if needed — folder ref should auto-include)

- [ ] **Step 1: Add t2i + edit topology tests** against the real bundled templates (all 4 FLUX.2 variants). Assert the expected node sets, the `CFGGuider` consumer, the LoRA chain, the prompt injection, and the param-map mismatch (a mapped node/input absent from the template throws).
- [ ] **Step 2: Add bundle-load tests** for the flux2 per-variant key resolution.
- [ ] **Step 3: Live validation.** In the app, route a real FLUX.2 t2i job (each variant) and a FLUX.2 edit job (with a source image) to ComfyUI; confirm all complete, the edit results reflect the source images, progress streams, and the output lands in the gallery.
- [ ] **Step 4: Commit.**

## FLUX.3 workstream (separate)

FLUX.3 is split into its own workstream due to distinct complexity. A separate plan will be created for it. Key differences from FLUX.2:

- **Bounding boxes for both t2i and edit** — FLUX.3 supports bounding boxes (BBs) in **both** modes. The form (UI) needs to account for this. Likely **repurpose the Ideogram 4 BB UI**, but **without the JSON** — the Ideogram BB UI uses a node created specifically to support Ideogram BBs, which may not map to FLUX.3's BB node (`CreateBoundingBoxes` / `Flux3LayoutPrompt`). This needs a focused analysis of the Ideogram BB node vs the FLUX.3 BB node before the UI is built.
- **Prompt-upsampler** — FLUX.3 has a mandatory prompt-upsampler stage (second `CLIPLoader` + `TextGenerate` + `ComfySwitchNode`); needs a `comfyClip2` settings slot + the `upsampler` parammap bool (set per flow: t2i OFF, edit ON — matching the official templates).
- **No LoRAs** — FLUX.3 drops LoRAs entirely (`&& !effective.isFlux3`, `Runner/FluxJobRunner.swift:289`); its templates skip the LoRA slot; `comfyGraph` passes `loras: []` and the mechanism no-ops.
- **No i2i** — FLUX.3 has no i2i mode; only t2i + edit (multi-ref).
- **2 variants** — klein (Distilled), klein base (Base); 2 t2i + 2 edit = 4 templates (the user has them in place, labeled Distilled and Base).
- **Reuses:** the generalized LoRA mechanism (Task 3, no-op for FLUX.3) + the per-variant template loader.

## Open questions to resolve during implementation

- **i2i vs edit template:** this plan uses one `<variant>/edit` template for both i2i (1 ref) and edit (N refs). If the user prefers separate `<variant>/i2i` + `<variant>/edit` exports, adjust Task 1 + the flow-key selection in Task 4 (the UI is unchanged either way).
- **Multi-ref slot count: 6.** The app supports up to 6 reference images (the model max, for flexibility). The `<size>-i2e-<variant>` templates have 6 `source_image_N` slots; the app caps `editImagePaths` at 6 (Review Focus #3).
- **Variant → flow-key mapping:** the runner maps `FluxModelVariant` → flow key `flux2/<size>-<flow>-<variant>` (e.g. `.flux2Klein4B` → `flux2/4b-t2i-distilled`, `.flux2KleinBase4B` → `flux2/4b-i2e-base` for i2e/edit) + settings key `FluxModelVariant.rawValue` (e.g. `flux2-klein-4b`). The naming is confirmed lowercase, flat.

## PR split

1. **PR 1 — harness generalization + templates.** `scripts/comfy_dry_run.py` (`--lora-kind`) + the 8 FLUX.2 template/parammap files (bundled resources) + the recorded dry-run results. Proves the FLUX.2 templates + param maps against live ComfyUI. No app-visible change. *(Depends on the user's FLUX.2 exports + live server.)*
2. **PR 2 — Swift LoRA generalization.** `ComfyTemplate.render(map:params:loras:loraKind:)` + `insertLoras` (full LoRA, clip chain, reference-rewrite consumer) + the tests. Krea 2 unchanged.
3. **PR 3 — FLUX.2 migration (ships the FLUX.2 remote path).** `FluxRunnerSpec.comfyGraph`, the FLUX.2 settings form, real-template topology tests, bundle + live validation. This is the shippable change.
