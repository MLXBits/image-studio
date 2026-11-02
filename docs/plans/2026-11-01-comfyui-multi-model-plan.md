# Plan: ComfyUI template mechanism + Krea 2 remote path (slice 1)

Date: 2026-11-01 · Status: implemented (slice 1 shipped in PR #70) · Spec: `docs/plans/2026-11-01-comfyui-multi-model.md`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the generic ComfyUI template mechanism (bundled-template loader, param-map injection, 10-slot LoRA transform, non-Swift dry-run harness) and the Krea 2 remote path on top of it (t2i + i2i), fixing #69 and proving the mechanism end-to-end.

**Architecture:** The app loads a frozen API-format template + a param-map sidecar from the bundle, keyed by family/flow (e.g. `krea2/t2i`, `krea2/i2i`). A generic `renderGraph` fills the mapped inputs from the job and wires the 10-slot LoRA chain, producing the `/prompt`-ready graph. Krea 2's runner spec picks the flow (t2i vs i2i by presence of a source image), builds the job params, and returns a `ComfyGraph` whose render closure calls `renderGraph`. A non-Swift Python harness validates each template + param map against a live ComfyUI before any Swift is written.

**Tech Stack:** Swift (macOS app), Swift Testing (tests), Python (dry-run harness), live ComfyUI server (dry-run + validation).

## Context / verified findings

- The remote transport (`ComfyUIClient.submit`, history poll, `ProgressTracker`), the routing gate (`JobRunner.comfyGraph`), and the settings/discovery layer are family-agnostic and already proven by Krea 2 (t2i) + SeedVR2. This plan reuses them; the new work is the template mechanism + Krea 2's i2i + the Krea 2 migration.
- The wire form is `POST /prompt` with `{nodeID: {class_type, inputs}}`; inputs are scalars or `[nodeID, outputIndex]` refs. Display names do not survive the API export, so parameters are anchored on stable node IDs via a param-map sidecar.
- **Krea 2 i2i is classic denoise-based:** `LoadImage → VAEEncode → KSampler(denoise=imageStrength)`. The i2i template fixes #69 (the current Swift `buildKrea2Workflow` is t2i-only and silently drops the source image).
- **External dependencies (user-provided; gate for PR 1):** (a) Krea 2 t2i + i2i ComfyUI exports in API format, each with the 10-slot `LoraLoader` chain added; (b) a live ComfyUI server with the Krea 2 model files + a test LoRA, for the dry-run + LoRA no-op test.

## Scope

This plan is **slice 1 only**: the shared template mechanism + Krea 2 (t2i + i2i). It ships a working Krea 2 remote path (fixing #69) and proves the mechanism. **Subsequent slices (FLUX.2 klein, FLUX.3 Image Klein, Z-Image, Ideogram 4) each get their own plan** built on this mechanism — they add templates + runner specs + per-variant settings on top of what this plan builds. The per-variant model-file settings extension (spec §8) is a later-slice concern; Krea 2 is a single variant and uses the existing per-family `comfyUNet/Clip/Vae` slots.

## File structure

- **Create** `scripts/comfy_dry_run.py` — the non-Swift dry-run harness (reference implementation of param injection; validates template + param map against live ComfyUI; runs the LoRA no-op test).
- **Create** `Utilities/ComfyTemplate.swift` — `ComfyTemplate`, `ComfyNode`, `ComfyInputValue` (the API wire form) + `ComfyParamMap` (the sidecar) + bundle loading.
- **Create** `Utilities/ComfyTemplate+Injection.swift` — `ComfyJobParams`, `LoraMechanism`, `renderGraph(...)` (fills mapped inputs + wires the 10-slot LoRA chain + i2i source-image wiring).
- **Create** `Resources/comfy_templates/krea2/{t2i,i2i}.json` + `{t2i,i2i}.parammap.json` — the two Krea 2 templates + sidecars (bundled).
- **Modify** `Runner/Krea2JobRunner.swift` — `comfyGraph` picks the flow, builds `ComfyJobParams`, returns a `ComfyGraph` whose render closure calls `renderGraph`.
- **Modify** `Utilities/ComfyUIClient.swift` — remove `buildKrea2Workflow` (replaced by the mechanism).
- **Modify** `Views/Settings/ModelDefaultsView+Krea2Form.swift` — confirm the Krea 2 UNet/CLIP/VAE rows feed `settings.comfyUNet/Clip/Vae["krea2"]` (t2i + i2i share the same model files; likely no structural change).
- **Test** `Tests/ComfyTemplateTests.swift` — topology tests (t2i/i2i graph shape, param-map mismatch, 10-slot LoRA chain).

## Global Constraints

- Wire form is `POST /prompt` with `{nodeID: {class_type, inputs}}`; refs are `[nodeID, outputIndex]`. (spec §3)
- Templates + param maps are **bundled app resources**; loaded by family/flow key; no user-facing template management. (spec §3, §8)
- Parameters are anchored on **stable node IDs** via the param-map sidecar, never display names. (spec §3)
- **Dry-run before Swift:** each template + param map is validated by the Python harness against live ComfyUI before the Swift that consumes it is written. (spec §3)
- **10-slot LoRA cap:** the template wires exactly 10 `LoraLoader` nodes; the app fills 0–10 and neutralizes the rest per the tested `LoraMechanism`. (spec §5.3)
- App model-file settings **override** the template's baked-in filenames. (spec §8)
- A param-map mismatch (mapped node/input not in the template) must **fail loudly**, never silently produce a wrong graph. (spec §3; this is the #69 failure class)

## Review Focus

Input classes / failure modes the spec implies but no single task's test fully pins; each is added to the owning task's tests.

1. **Stale param map** (user re-exported, node IDs shifted) → `renderGraph` must throw on a missing mapped node/input, not silently emit a graph with an unfilled prompt. (Task 3)
2. **More LoRAs than 10 slots** → cap at 10 with a clear error, not a truncated silent stack. (Task 3)
3. **i2i job whose source image fails to upload** → fail the job with a clear error, never fall back to t2i (the #69 silent-drop class). (Task 4)
4. **Template references a model file absent on the server** → surface the server's error clearly (model not found), not a generic failure. (Task 1 harness + Task 7 live)
5. **Flow/param-map mismatch** (i2i template missing a `denoise` input, or a t2i template with a stray `LoadImage`) → caught at render time. (Task 6)

## Work items, in dependency order

### Task 1: Dry-run harness (non-Swift gate)

Reference implementation of param injection + the validation gate. Built and proven before any Swift.

**Files:** Create `scripts/comfy_dry_run.py` · **Produces:** a reusable harness with `--template`, `--param-map`, `--params <json>`, `--url`, optional `--image <path>`, and a `--lora-test` mode.

- [x] **Step 1: Write the harness CLI + injection.** Load the template (`{nodeID: {class_type, inputs}}`) + param map (`{param: {node, input}}`), fill each mapped input from `--params`, and serialize the graph to the `/prompt` body. Reuse the existing `ComfyUIClient` endpoints: `POST /prompt` (body `{"prompt": graph, "client_id": <uuid>}`), `GET /history/<prompt_id>`, and the output download. Keep the injection logic minimal + explicit — this is the reference the Swift (Task 3) must match.
- [x] **Step 2: Add the `--lora-test` mode.** Given a base template + a test LoRA + a fixed seed, run four variants and compare outputs: (a) no LoRA, (b) empty `lora_name`, (c) bogus `lora_name`, (d) valid `lora_name` with `strength_model=0` + `strength_clip=0`. Report which unused-slot strategies are clean no-ops (identical output to (a) at the same seed). This result fixes the `LoraMechanism` for Task 3.
- [x] **Step 3: Verify against live ComfyUI.** Run a t2i job end-to-end (template + param map + a real prompt/seed/size); confirm a valid image and that params are honored (change seed → different image; change size → different dimensions). Also confirm a template pointing at a missing model file surfaces the server's error clearly (Review Focus #4). Run the `--lora-test` and record the result.
  - Expected: t2i produces a valid image with honored params; the `--lora-test` names the cleanest no-op strategy.

### Task 2: Krea 2 templates + param maps (depends on user exports)

**Files:** Create `Resources/comfy_templates/krea2/{t2i,i2i}.json` + `{t2i,i2i}.parammap.json` · **Depends on:** the user's Krea 2 t2i + i2i exports (API format, each with the 10-slot `LoraLoader` chain).

- [x] **Step 1: Ingest the exports.** Confirm each is API format (`{nodeID: {class_type, inputs}}`, no `nodes`/`links`); confirm the i2i export has the `LoadImage → VAEEncode → KSampler(denoise)` branch and both have the 10-slot `LoraLoader` chain.
- [x] **Step 2: Sanity pass → param maps.** For each template, identify the `(node, input)` for: prompt, negative prompt (if present), seed, width, height, steps, cfg, sampler, scheduler, denoise (i2i only), unet/clip/vae loader names, the 10 LoRA slots (on/off + name + strengths), and (i2i) the source-image filename input. Write each to `<flow>.parammap.json`.
- [x] **Step 3: Validate with the harness.** Run Task 1's harness against both templates + param maps (t2i, and i2i with a real source image); confirm valid outputs + honored params. **Do not start Task 3 until both pass.**

### Task 3: Swift template mechanism (generic)

**Files:** Create `Utilities/ComfyTemplate.swift`, `Utilities/ComfyTemplate+Injection.swift` · Test `Tests/ComfyTemplateTests.swift`

**Produces (exact interfaces):**
- `ComfyTemplate: Decodable` — `nodes: [String: ComfyNode]`; `static func load(familyFlowKey: String) throws -> ComfyTemplate` (reads bundled `comfy_templates/<key>.json`).
- `ComfyNode: Decodable` — `classType: String`, `inputs: [String: ComfyInputValue]` (`_meta` ignored on decode).
- `ComfyInputValue: Decodable` — `case scalar(ComfyScalar)` (Int/Double/String/Bool) / `case ref(nodeID: String, outputIndex: Int)`.
- `ComfyParamMap: Decodable` — `params: [String: ParamTarget]`; `ParamTarget { node: String, input: String }`; `static func load(familyFlowKey: String) throws -> ComfyParamMap`.
- `ComfyJobParams` — `prompt: String`, `negativePrompt: String?`, `seed: Int`, `width: Int`, `height: Int`, `steps: Int`, `cfg: Double`, `sampler: String`, `scheduler: String`, `denoise: Double?`, `unetName/clipName/vaeName: String?`, `sourceImageName: String?`, `loras: [(name: String, strengthModel: Double, strengthClip: Double)]`.
- `LoraMechanism` — `case emptyNoOp, strengthZero, switchBased` (set from Task 1's `--lora-test` result).
- `func renderGraph(template: ComfyTemplate, paramMap: ComfyParamMap, params: ComfyJobParams, loraMechanism: LoraMechanism) throws -> [String: ComfyNode]`.

- [x] **Step 1: Write the failing decode tests.** Decode a small fixture template (2–3 nodes; one scalar + one `[nodeID, outputIndex]` ref input) and assert `classType` + input values; decode a param map and assert a target. Run → FAIL (types don't exist).
- [x] **Step 2: Implement the decode types + bundle loading.** `ComfyInputValue` decodes from either a scalar or a `[String, Int]` array (the ref form). `load(familyFlowKey:)` reads `comfy_templates/<key>.json` from the bundle. Run the decode tests → PASS.
- [x] **Step 3: Write the failing injection tests.** (a) `renderGraph` fills a mapped scalar input (e.g. `KSampler.steps`) from `params`; (b) a mapped input whose node or input name is absent throws (Review Focus #1); (c) more than 10 LoRAs throws (Review Focus #2); (d) the 10-slot chain is wired for N used slots with the rest neutralized per `loraMechanism`. Run → FAIL.
- [x] **Step 4: Implement `renderGraph`.** Fill each mapped input from `params` (throw on a missing node/input). Wire the 10-slot LoRA chain: for each used slot set name + strengths; neutralize unused slots per `loraMechanism` (empty / valid-name+zero / switch-off). For i2i, set the source-image filename input from `params.sourceImageName`. Match the Task 1 harness's injection exactly (same graph for the same inputs). Run the injection tests → PASS.
- [x] **Step 5: Commit.**

### Task 4: Krea 2 runner spec + drop the old builder

**Files:** Modify `Runner/Krea2JobRunner.swift`, `Utilities/ComfyUIClient.swift` · Test `Tests/ComfyTemplateTests.swift` (extend) · **Consumes:** `ComfyTemplate.load`, `ComfyParamMap.load`, `renderGraph` (Task 3).

- [x] **Step 1: Write the failing runner tests.** `Krea2RunnerSpec.comfyGraph` returns a non-nil `ComfyGraph` for a t2i job and for an i2i job (with `imagePath`); the i2i render closure produces a graph whose `KSampler.denoise` equals `imageStrength` (Review Focus #3: a source image is required for i2i). Run → FAIL.
- [x] **Step 2: Implement `comfyGraph`.** Pick the flow key: `job.imagePath != nil ? "krea2/i2i" : "krea2/t2i"`. Load the template + param map. Build `ComfyJobParams` from the job + `settings.comfyUNet/Clip/Vae["krea2"]` (override the template's filenames) + the LoRA stack. Return a `ComfyGraph(totalNodes:totalSteps:render:)` whose render closure calls `renderGraph` per seed. For i2i, upload the source image first (reuse the existing upload path) and set `sourceImageName`; if the upload fails, throw (Review Focus #3 — never fall back to t2i).
- [x] **Step 3: Remove `buildKrea2Workflow`.** Delete it from `ComfyUIClient.swift` and update its only caller (Krea 2). Confirm no other references remain.
- [x] **Step 4: Run the full test suite.** `xcodebuild test` — count real results via `grep 'passed after'` in the log (the XCTest "Executed 0 tests" summary is misleading; TEST SUCCEEDED + exit 0 = green). Expected: all green, including the new Krea 2 topology tests.
- [x] **Step 5: Commit.**

### Task 5: Settings forms

**Files:** Modify `Views/Settings/ModelDefaultsView+Krea2Form.swift`

- [x] **Step 1: Confirm the Krea 2 rows feed the template.** The existing UNet/CLIP/VAE rows write to `settings.comfyUNet/Clip/Vae["krea2"]`, which Task 4 step 2 reads into `ComfyJobParams.unetName/clipName/vaeName`. Confirm t2i + i2i share the same model files (they do for Krea 2); if the i2i template needs a different VAE, add a `comfyVaeI2i` per-flow override here and in Task 4.
- [x] **Step 2: Commit.**

### Task 6: Topology tests (pin the real templates)

**Files:** Test `Tests/ComfyTemplateTests.swift`

- [x] **Step 1: Add t2i + i2i topology tests against the real bundled templates.** Load `krea2/t2i` + `krea2/i2i`, render with sample params, and assert: the expected node set (t2i: `EmptyLatentImage`, `UNETLoader`, `CLIPLoader`, `VAELoader`, `KSampler`, `VAEDecode`, `SaveImage`; i2i: + `LoadImage`, `VAEEncode`), `KSampler` steps/cfg/sampler/scheduler match the params, the prompt is injected, the i2i `KSampler.denoise` == `imageStrength`, and the LoRA chain is correct (Review Focus #1, #3, #5).
- [x] **Step 2: Run → PASS. Commit.**

### Task 7: Bundle + live validation

**Files:** Modify the Xcode project (add `Resources/comfy_templates/**` to the bundle)

- [x] **Step 1: Add the templates + sidecars to the app bundle.** Ensure `ComfyTemplate.load`/`ComfyParamMap.load` find them at runtime (bundle resource path).
- [x] **Step 2: Live validation.** In the app, route a real Krea 2 t2i job and a real Krea 2 i2i job (with a source image) to ComfyUI; confirm both complete, the i2i result reflects the source image (the #69 fix), progress streams, and the output lands in the gallery.
- [x] **Step 3: Commit.**

## Open questions to resolve during implementation

- **`LoraMechanism`** (spec §5.3): fixed by Task 1's `--lora-test` result before Task 3 is written.
- **`LoraLoader` vs `LoraLoaderModelOnly`** (spec §5.3): the Krea 2 exports use `LoraLoaderModelOnly`; confirm the 10-slot chain uses the same class in both templates.
- **i2i VAE:** confirm the Krea 2 i2i template uses the same VAE as t2i (expected); if it needs a full-encoder VAE, add the per-flow override in Task 5.

## PR split

1. **PR 1 — dry-run gate + templates.** `scripts/comfy_dry_run.py` + the two Krea 2 templates + param maps (bundled resources) + the recorded `--lora-test` result. Proves the templates + param maps against live ComfyUI. No app-visible change. *(Depends on the user's Krea 2 exports + live server.)*
2. **PR 2 — Swift mechanism.** `ComfyTemplate`/`ComfyParamMap`/`renderGraph`/`LoraMechanism` + the decode + injection unit tests. The generic mechanism, tested in isolation; Krea 2 still on the old builder.
3. **PR 3 — Krea 2 migration (ships #69).** `Krea2RunnerSpec.comfyGraph` (t2i + i2i) via the mechanism, drop `buildKrea2Workflow`, settings-form confirmation, real-template topology tests, bundle the templates, live validation. This is the shippable change.
