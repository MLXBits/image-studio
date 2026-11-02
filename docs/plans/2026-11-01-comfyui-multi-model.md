# Plan: extend the ComfyUI remote path to FLUX.2/3, Z-Image, and Ideogram 4

Date: 2026-11-01 · Status: draft (builder-checked; awaiting partner approval) · Repo: MLXBits Image Studio, branch `main` · Related: issue #69 (Krea 2 remote path is text-to-image only)

## 1. Intent and the why

Image Studio already runs two families through a remote ComfyUI backend — **Krea 2** (text-to-image) and **SeedVR2** (upscale). That loop is proven end-to-end: per-family routing, model-file config, live progress, LoRA filtering, and gallery ingest. The transport (`ComfyUIClient`), the routing gate (`JobRunner.comfyGraph`), and the settings/discovery layer (`ComfyModelStore`, `ModelDefaultsView`) are family-agnostic.

This project extends that remote path to the remaining generative families — **FLUX.2 klein, FLUX.3 Image Klein, Z-Image, and Ideogram 4** — so users with beefier GPUs can run the same jobs remotely and stream results back into the same Lightroom-style gallery.

- **Driving use case:** bulk image iteration on stronger hardware. The app is a better frontend for iterating over many generations than ComfyUI's own UI (gallery + params vs. files in a folder).
- **Secondary benefit:** parity — a job that runs locally on mflux should also be able to run remotely on ComfyUI.
- **Ships in the first slice:** Krea 2 migrates to the template system (two bundled templates, t2i + i2i, from Krea 2's default ComfyUI workflows); the i2i template fixes #69 (remote i2i silently ignores the source image). This slice proves the new mechanism on the simplest graph.

## 2. Goals / Non-goals / Anti-goals

**Goals**
- Remote ComfyUI generation for FLUX.2 klein, FLUX.3 Image Klein, Z-Image, and Ideogram 4, for each flow the model supports (t2i; reference/i2i; edit).
- Stable, compatibility-safe workflow templates authored and hardened by the user in ComfyUI, exported per-flow in API format.
- Per-family model-file configuration in Settings (UNet/CLIP/VAE + family extras).
- Multi-LoRA support on the remote path.
- Fix Krea 2 #69 (remote i2i ignores the source image).
- A **non-Swift dry-run harness** that validates each export against live ComfyUI before any Swift is written.

**Non-goals**
- An in-app workflow builder / node-graph editor (off the table for compatibility).
- In-app-purchase gating of the ComfyUI backend (deferred; not a current requirement).
- Changes to the local mflux runners or their behavior.
- Making the app the source of truth for graph topology.

**Anti-goals**
- Hand-building node topology in Swift per family (rejected — fragile; the user runs thousands of images through Comfy and wants stable, hardened, portable workflows they control).
- Coupling the app to a specific ComfyUI node set in a way that breaks on updates.

## 3. Constraints

- **Wire format is fixed.** The app posts `POST /prompt` with the API/prompt form `{nodeID: {class_type, inputs}}`, where inputs reference other nodes as `[nodeID, outputIndex]`. Confirmed against the live server and the existing `buildKrea2Workflow`.
- **Templates are the source of truth for topology.** The user authors + hardens each flow in ComfyUI and exports it in API format. The app loads the template and injects variables; it does not author graph shape.
- **Display names do not survive the API export.** Exported nodes are `{_meta, class_type, inputs}` only — no title, no `mode`. Parameters are therefore anchored on **stable node IDs**, not names.
- **Node IDs are stable for a frozen template** (`prefix:seq` form, e.g. `71:53`). They change only when the user adds/removes nodes, which triggers a re-run of the param-map sanity pass.
- **Dry-run before Swift.** Each export is validated by a non-Swift harness (load template → apply param map with a real job's values → POST `/prompt` → verify output) against live ComfyUI **before** the Swift wrapper is written.
- **Templates + param maps are bundled app resources.** The app loads them from the bundle by a family/flow key; there is no user-facing template management or runtime discovery. A template change (re-export + re-run the sanity pass) ships with an app release. Rationale (user): templates are not expected to change often, and the ComfyUI userbase is already power-user/edge-case.

## 4. Approaches considered

| Approach | Trade-off | Verdict |
|---|---|---|
| **A. Hand-built Swift graph builders per family** (extend the `buildKrea2Workflow` pattern) | Full control, but the app becomes the source of truth for topology. The official templates use a complex, evolving advanced-sampler stack (`SamplerCustomAdvanced`, `CFGGuider`/`DualModelGuider`, `Flux2Scheduler`/`Ideogram4Scheduler`, `ConditioningZeroOut`, `ModelSamplingAuraFlow`, `ReferenceLatent`/`ReferenceMultiLatent`). Re-implementing and keeping that compatible in Swift is fragile and high-maintenance. | **Rejected** — compatibility risk; the user wants stable hardened workflows they own. |
| **B. Stable user-authored API-JSON templates + app-side param injection** | The user owns + hardens topology in ComfyUI (where they already test); the app runs a small, deterministic param-injection layer. Compatibility is pinned to the frozen template, not to Swift code. | **Chosen.** |
| **C. In-app workflow builder / template wrapper** | Would let non-experts edit graphs, but the user ruled it out for compatibility; the overhead isn't worth it vs. providing a stable template. | **Rejected** (user decision). |

The user picked **B**.

## 5. The how (as decided)

### 5.1 Per-family/flow unit of work
For each family and each flow it supports:
1. **Author + export.** User builds + hardens the flow in ComfyUI, exports per-flow in API format.
2. **Param map (one-time sanity pass).** We identify, for each injectable parameter, the `(node_id, input)` it maps to. Stored as a sidecar. Re-run only when the user adds/removes nodes.
3. **Dry-run harness (non-Swift gate).** A Python/curl script loads the export, applies the param map with a real job's values (prompt, seed, W/H, steps/cfg, model files, LoRAs, source image), POSTs to live ComfyUI `/prompt`, and verifies the output. This is also where the LoRA no-op / strength-0 test runs. **No Swift is written until this passes.**
4. **Swift implementation.** Generic template loader + param-map injection + the family's `comfyGraph` runner spec + settings-form rows + a topology test. Then live validation from the actual app.
5. **Bundle.** The validated template + its param-map sidecar are added to the app bundle under a family/flow key (e.g. `krea2/t2i`, `krea2/i2i`); the loader loads from the bundle by that key.

### 5.2 Param-map contract
- A sidecar JSON per template: `{ "<param>": { "node": "<node_id>", "input": "<input_name>" }, ... }`.
- The app fills each mapped input from the job. Some params map to the **root of a chain** (a Primitive/toggle); the chain does the rest (prompt upsampling, 16-rounding, preset lookup). The map names the root; the app does not trace the chain.
- The sanity pass is a one-time, human-in-the-loop activity (read the export, identify injection points). Re-run only on node changes.
- Confirmed injection-point shapes from the user's two example exports:
  - **Krea 2:** prompt → a `PrimitiveStringMultiline` (root of the upsampler/concat chain), *not* the `CLIPTextEncode`; seed/steps/cfg/sampler/scheduler/denoise → the `KSampler`; W/H → `EmptyLatentImage`; model files → the three loaders; LoRA on/off → a `PrimitiveBoolean`; LoRA name/strength → the `LoraLoaderModelOnly`; upsampler on/off → a `PrimitiveBoolean`.
  - **Ideogram 4:** prompt (JSON caption) → `CLIPTextEncode.text`; seed → `RandomNoise.noise_seed`; cfg → `DualModelGuider.cfg`; W/H → two `PrimitiveInt` roots feeding a `ComfyMathExpression` (rounds to 16); **steps are preset-driven** via a `CustomCombo` → JSON → `Ideogram4Scheduler`, not a free scalar (matches the app's existing preset-driven Ideogram behavior).

### 5.3 LoRA strategy (10-slot chain)
- The template wires **10 `LoraLoader` nodes** in a linear chain off the `UNETLoader` anchor. The app fills 0–10 slots; unused slots must be no-ops. The app caps remote LoRA stacks at 10.
- **Mechanism depends on a live test** (run in the dry-run harness):
  1. If an empty/unknown `lora_name` is a clean passthrough → unused slots left empty. Simplest.
  2. Else if `strength_model=0` + `strength_clip=0` with a valid name is a clean no-op (expected) → unused slots get a valid name + zero strength.
  3. Else → each slot behind a `ComfySwitchNode`; app flips the switch + sets the name for used slots. (Whether a switch prunes its unselected branch is implementation-dependent; confirm in the same test before relying on it.)
- **Open (builder/user):** `LoraLoader` (model + CLIP) vs `LoraLoaderModelOnly` (model only) per family. Full `LoraLoader` matches local mflux behavior (applies to CLIP via `strength_clip`); the user's Krea export uses `LoraLoaderModelOnly`.

### 5.4 i2i / edit semantics (important correction)
- **Krea 2** is classic denoise-based i2i: `LoadImage → VAEEncode → KSampler(denoise=imageStrength)`. The #69 fix adds this branch; `imageStrength` maps directly to `denoise`.
- **FLUX.2 / FLUX.3** use **reference-conditioned generation**, not denoise i2i: the source image goes through `ReferenceLatent` / `ReferenceMultiLatent` (reference conditioning), and single-reference "i2i" and multi-reference "edit" are the **same flow** (one vs. many references). There is no denoise knob.
  - **Consequence:** the app's local `imageStrength` slider does **not** map onto these server flows (see open item §7.1).
- **Z-Image:** t2i has official templates; i2i/edit is the separate **Z-Image-Edit** model, which has **no official template** — the user authors it.
- **Ideogram 4:** t2i only (no image input in the job model).

### 5.5 Per-family flow matrix

| Family | t2i | i2i (single ref) | edit (multi-ref) | Notes |
|---|---|---|---|---|
| Krea 2 | ✅ template | ✅ denoise-based, template (fixes #69) | — | first slice; two bundled templates (t2i + i2i) from Krea 2's default ComfyUI workflows |
| FLUX.2 klein | ✅ | ✅ reference | ✅ reference (same flow) | official templates to harden |
| FLUX.3 Image Klein | ✅ | ✅ reference | ✅ reference + bboxes | needs prompt-upsampler (open item §7.2) |
| Z-Image | ✅ | ⚠️ Z-Image-Edit (author) | ⚠️ Z-Image-Edit (author) | no official edit template |
| Ideogram 4 | ✅ | — | — | dual-model CFG + JSON caption (app already produces it) |

### 5.6 Per-family model files (settings-form rows)
(from recon of official templates + the user's exports)
- **FLUX.2 klein:** UNet `flux-2-klein-{4b,9b}[-base]`; CLIP `qwen_3_4b` / `qwen_3_8b_fp8mixed` (type `flux2`); VAE `flux2-vae` (t2i) / `full_encoder_small_decoder` (edit — needs the full encoder to read the reference).
- **FLUX.3 Image Klein:** UNet `flux3-image-klein[-base]-int8-convrot`; CLIP `qwen3vl_4b_int8_convrot` (type `flux3`); VAE `flux2-vae`; **prompt-upsampler** `qwen3.5_9b_flux3_prompt_upsampler` (type `flux3`).
- **Z-Image:** UNet `z_image[-turbo]_bf16`; CLIP `qwen_3_4b` (type `lumina2`); VAE `ae.safetensors`. Turbo ≈ 8 steps / cfg 1; Base ≈ 25–50 steps / cfg 3–5.
- **Ideogram 4:** UNet `ideogram4_fp8_scaled` **and** `ideogram4_unconditional_fp8_scaled` (dual-model CFG); CLIP `qwen3vl_8b_fp8_scaled` (type `ideogram4`); VAE `flux2-vae`.

### 5.7 Sequencing
1. **Krea 2** (first slice): migrate to the template system — two bundled templates (`krea2/t2i`, `krea2/i2i`) based on Krea 2's default ComfyUI workflows, hardened with the 10-slot LoRA chain + param maps; the i2i template fixes #69; the Swift `buildKrea2Workflow` is dropped. Proves the whole mechanism on the simplest graph.
2. **FLUX.2 klein:** the flagship; exercises the advanced sampler stack + reference-conditioned i2i/edit.
3. **FLUX.3 Image Klein:** adds the prompt-upsampler + bounding boxes.
4. **Z-Image:** t2i (official) + i2i/edit (user-authored Z-Image-Edit).
5. **Ideogram 4:** t2i, dual-model + JSON caption.

(FLUX.2/3 are grouped — the user noted "Flux2/3 would follow" Krea.)

## 6. What's left to the builder
- The Swift **template loader** (loads bundled templates + sidecars by family/flow key) **+ param-map injection** layer (generic, family-agnostic).
- The **10-slot LoRA chain** transform (per the tested mechanism, §5.3).
- Per-family `comfyGraph` runner specs, settings-form rows, and topology tests.
- Source-image upload + reference wiring for i2i/edit flows.
- The reusable **non-Swift dry-run harness**.
- Per-family param maps (produced from the user's exports during each slice).

## 7. Open items (resolve during implementation)

Items 1–3 are slice-2/3 product decisions, deferred to when we reach those families. Items 4–5 resolve during slice 1 (dry-run + first templates).

1. **`imageStrength` for reference-conditioned families (FLUX.2/3).** The local slider is a denoise knob; the server flow has no denoise. Options: hide the slider when routed to ComfyUI; repurpose it as an on/off "use reference"; or map it to a reference-influence param if the model supports one. **Needs a decision.**
2. **FLUX.3 prompt-upsampler.** The template includes a `TextGenerate` upsampler (BFL: don't run without it). The app already has prompt-enhancement (Gemma/OpenAI). Decide: keep the template's upsampler (app sets the on/off boolean), or feed an already-enhanced prompt and disable the template's. **Needs a decision.**
3. **Z-Image-Edit authoring.** No official template; the user authors the i2i/edit flow. Scope/effort confirmed when we reach Z-Image.
4. **LoRA no-op test result.** Determines the 10-slot mechanism (§5.3). User runs in ComfyUI.
5. **`LoraLoader` vs `LoraLoaderModelOnly`** per family (§5.3).

## 8. Decisions resolved during review

- **Template storage:** bundled app resources — no user-facing template management; template changes ship with releases. (User: not expected to change often; the ComfyUI userbase is already power-user/edge-case.)
- **Krea 2 structure:** two bundled templates — `krea2/t2i` and `krea2/i2i` — based on Krea 2's default ComfyUI workflows; the i2i template fixes #69; the Swift `buildKrea2Workflow` is dropped.
- **Builder calls (my calls, overridable):**
  - **Per-variant model files:** extend the existing per-family `comfyUNet/Clip/Vae` settings to per-variant (FLUX.2 4b/9b, FLUX.3, Z-Image turbo/base, Ideogram's two UNets); app values override the template's baked-in filenames. Consistent with today's Krea 2/SeedVR2 pattern.
  - **Multi-ref overflow:** reference slot count is a per-template detail (set when the FLUX.2/3 reference template is authored); if a job has more refs than slots, cap the picker at the param-map count, else a clear error.
  - **Ideogram 4 remote:** `cfg` comes from the template's `DualModelGuider` (baked in); a plain-prompt Ideogram job routed remote feeds the app-produced JSON caption into the template (same caption the local path uses).

## Appendix A — Reference topologies (recon)
Parsed from `Comfy-Org/workflow_templates` (official) + the user's two example exports. For the builder's reference when building param maps.

- **FLUX.2 klein t2i** — `SamplerCustomAdvanced` + `CFGGuider` + `Flux2Scheduler` + `RandomNoise`; `ConditioningZeroOut` on the distilled checkpoints; latent `EmptyFlux2LatentImage`; prompt via `CLIPTextEncode`.
- **FLUX.2 klein edit** — references via `LoadImage → VAEEncode → ReferenceLatent` (chained for multi-ref); `ImageScaleToTotalPixels` + `GetImageSize` resize the reference; edit VAE is `full_encoder_small_decoder`.
- **FLUX.3 Image Klein t2i** — `KSampler` (base ≈ 15 steps / cfg 1 / `er_sde`); built-in prompt-upsampler: a second `CLIPLoader` (`qwen3.5_9b_flux3_prompt_upsampler`, type `flux3`) + `TextGenerate`; latent `EmptyFlux2LatentImage`.
- **FLUX.3 Image Klein edit** — same UNet/CLIP/VAE; reference via `ReferenceMultiLatent`; `Flux3LayoutPrompt` + `CreateBoundingBoxes` for bounding boxes; `<ref_image_N>` tokens in the prompt.
- **Z-Image Turbo** — `KSampler` 8 steps / cfg 1 / `res_multistep`; `ModelSamplingAuraFlow` (shift 3); `ConditioningZeroOut`; latent `EmptySD3LatentImage`; no negative prompt.
- **Z-Image Base** — `KSampler` ≈ 25–50 steps / cfg 3–5; has a negative `CLIPTextEncode`; otherwise as Turbo.
- **Ideogram 4 t2i** — `DualModelGuider` (base + unconditional UNet) + `Ideogram4Scheduler` + `CFGOverride` + `SamplerCustomAdvanced`; prompt is the structured JSON caption; W/H via `ComfyMathExpression` (round to 16); steps/mu/std from a `CustomCombo` quality preset.

## Appendix B — Existing code touch points
- **Transport:** `Utilities/ComfyUIClient.swift` (`buildKrea2Workflow`, `submit`, history poll, `ProgressTracker`), `Utilities/ComfyUIClient+SeedVR2.swift`.
- **Routing gate:** `Runner/JobRunner.swift` — `static func comfyGraph(job:settings:client:) async throws -> ComfyGraph?` (default `nil`); `ComfyGraph(totalNodes:totalSteps:render:)`.
- **Existing remote specs:** `Runner/Krea2JobRunner.swift` (t2i graph; #69), `Runner/SeedVR2JobRunner.swift` (upscale).
- **Local specs (no change):** `Runner/FluxJobRunner.swift`, `Runner/Ideogram4JobRunner.swift`, `Runner/ZImageJobRunner.swift`.
- **Job models:** `Models/Krea2Job.swift` (`imagePath`, `imageStrength`), `Models/FluxJob.swift` (`imagePath`, `imageStrength`, `editImagePaths`), `Models/ZImageJob.swift` (`imagePath`, `imageStrength`), `Models/ModelFamily.swift`, `Models/FluxModelCatalog.swift`.
- **Settings/discovery:** `Stores/AppSettings.swift` (`comfyURL`, `comfyUNet/Clip/Vae`, `comfyBackendEnabled`), `Stores/ComfyModelStore.swift`, `Views/Settings/ModelDefaultsView.swift` + per-family `+Krea2Form`/`+SeedVR2Form`/`+Ideogram4Form`/`+ZImageForm`/`+Forms`.
- **LoRA UI:** `Views/ParamsPanel/LoraManagerView.swift`, `Views/Settings/LoraLibraryEditorView.swift` (both switch behavior when `routedToComfyUI`).
- **Tests:** `Tests/ComfyLoraNameResolutionTests.swift`, `Tests/ComfySeedVR2WorkflowTests.swift`, `Tests/ComfyHistoryFailureDecodeTests.swift`, `Tests/ComfyProgressDecodeTests.swift`, `Tests/ActiveComfyURLTests.swift`.
