# Plan: add Flux 3 to MLXBits Image Studio (mflux 0.21 → 0.23)

Date: 2026-10-20 · Status: agreed (3 PRs; store stays on 0.17.3 until fsspec gate passes, Flux 3 ships as 0.18.0)

## Context / verified findings

**Where the pin lives.** `Runtime/requirements.in` pins `mflux==0.21.0` exactly, with
the standing rule that a bump is "a deliberate app change (new model families, changed
CLI flags) and ships with an app release." Re-lock via `scripts/lock-python-runtime.sh`,
rebuild the bundled runtime via `scripts/build-python-runtime.sh`. The build already
guards bumps: every tool in `Runtime/tools.txt` must pass `--help`, and
`Resources/hf_cache_probe.py --check` fails loudly if mflux renames the private method
the app's "downloaded" check calls.

**What mflux 0.23.0 adds for Flux 3** (verified by diffing the 0.21.0 vs 0.23.0 wheels):

- Two new CLI entry points: `mflux-generate-flux3` and `mflux-generate-flux3-edit`.
  Flux 3 is a *new model family in mflux* (its own package under `mflux/models/flux3/`).
- Model IDs: `flux3-image-klein` (distilled; CLI default, ~16 steps) and
  `flux3-image-klein-base` (undistilled Base; ~50 steps + CFG, guidance default 3.5).
  Aliases include `flux3`, `flux3-base`.
- CLI quirks that matter to us:
  - `--negative-prompt` is **rejected** — the CLI exits with an error when it's set.
  - `--scheduler` and `--lora-style` are ignored (use plain `--lora`).
  - `--guidance` only applies to the Base checkpoint; on the distilled model it is
    ignored with a warning (no CFG branch).
  - Supports metadata config and dimension scale factor.
- Dependency deltas from the bump: new transitive dep `fsspec>=2026.6.0`, and
  `urllib3` floor moves 2.7 → 2.8. No change to mflux's transformers/mlx pins, so the
  existing `transformers>=5.5,<5.13` constraint should still hold (confirm at lock time).
- The private cache-probe method `_find_complete_cached_snapshot` **still exists** in
  0.23 (`mflux/models/common/resolution/path_resolution.py`) — the "downloaded" check
  survives; the build-time `--check` covers any future rename anyway.

**How the app is shaped for this.** The catalog (`Models/FluxModelCatalog.swift`,
`FluxModelVariant: CaseIterable`) drives picker and settings from per-variant metadata:
`displayName`, `mfluxModelID`, default steps/guidance, `supportsNegativePrompt`, prompt
length cap, size estimate, and — crucially — `generateTool`. The model list is already
filtered by tool availability (`allModels.filter { $0.generateTool.map(toolchain.hasTool) }`),
so a variant whose tool isn't in the runtime is hidden automatically. Editing reuses the
existing per-job edit mode; `FluxRunnerSpec.tool(job:)` currently maps
`isEditMode ? .flux2Edit : .flux2`. The generic `JobRunner<Spec>` engine, `FluxJob`,
`JobStore`, AppSettings defaults, gallery/metadata all key off the variant — so new
variants ride existing machinery.

## Scope decision (recommendation)

**Treat Flux 3 as variants of the existing `.flux` ModelFamily**, not a new family:
add catalog entries + two `PythonTool` cases and extend tool selection in
`FluxRunnerSpec`. Same runner engine, job model, settings, gallery — only the CLI differs.
This is far smaller than the full "add a model family" recipe (Z-Image touched 24 files)
and matches how the catalog already spans families.

Fall back to a dedicated `.flux3` family case only if implementation shows deeper
semantic divergence (e.g., flux3 edit payloads or quantization behave unlike flux2).

## Work items, in dependency order

### A. mflux bump (foundation; no app-visible change)

1. `Runtime/requirements.in`: bump to `mflux==0.23.0`, refresh the comment.
   Review the 0.22.x + 0.23 release notes (filipstrand/mflux) for behavior changes to
   existing families (flux2/krea2/z-image) while in there.
2. Re-lock: `scripts/lock-python-runtime.sh`. Expect in the lock diff: `fsspec` added,
   urllib3 floor raised. Sanity-check nothing else shifts and no conflict with the
   `transformers<5.13` / `mlx-vlm==0.6.3` pins.
3. Rebuild runtime: `scripts/build-python-runtime.sh`. Gates that must pass:
   - every existing tool in `tools.txt` still `--help`s;
   - `hf_cache_probe.py --check` (private-method guard);
   - App Store API/denylist check — **fsspec is new surface**, verify it passes.
4. Do not add the two new 0.23 controlnet tools (`mflux-generate-krea2-controlnet`,
   `...-qwen-2.1-controlnet`) to `tools.txt` — out of scope; keep the diff focused.

### B. Flux 3 in the app model surface

5. `Utilities/PythonTool.swift`: add cases `flux3 = "mflux-generate-flux3"` and
   `flux3Edit = "mflux-generate-flux3-edit"`, plus same-named lines in
   `Runtime/tools.txt` (a test keeps the two equal).
6. `Models/FluxModelCatalog.swift`: add variants — proposed names `flux3Klein`
   (`flux3-image-klein`) and `flux3KleinBase` (`flux3-image-klein-base`). Per variant,
   verify against mflux 0.23 source / a live `--help` in the rebuilt runtime:
   - default steps (16 distilled / 50 base) and guidance (base 3.5; distilled — see
     open question on hiding the control);
   - `supportsNegativePrompt = false` (CLI rejects it; buildArgs already gates on this,
     but audit edit-mode paths for any other route that could pass one);
   - max prompt length and dimension constraints (check mflux flux3 resolution config —
     do not copy flux2's numbers unverified);
   - size estimate: measure from the HF repos (`klein`, `klein-base`), don't guess;
   - quantization: check whether `--quantize` is in flux3's general args and whether
     mlx-community pre-quantized repos exist. If unsupported, gate the quantize UI off
     for these variants (precedent: per-variant capability flags).
7. `Runner/FluxJobRunner.swift`: extend `tool(job:)` to select `.flux3` / `.flux3Edit`
   when the variant is a flux3 model. Re-check `buildArgs` against the flux3 parser —
   expect zero changes beyond what per-variant flags already gate (`--negative-prompt`,
   guidance, steps).
8. Picker + Settings: `Views/ParamsPanel/ModelPickerView.swift` and
   `Views/Settings/ModelDefaultsView+FluxForm.swift` iterate the catalog, so new variants
   should appear with no structural change — verify grouping (a "FLUX 3" section is nicer
   than burying them under FLUX.2) and that per-variant default rows key off the variant.
9. Metadata/constraints touchpoints: `Utilities/MetadataSidecar.swift`,
   `Views/Shared/ImageMetadataInfo.swift`, `Views/Shared/DimensionConstraints.swift` —
   add flux3 entries where these switch on model/family.
10. Model availability: confirm how `Resources/hf_cache_probe.py`'s family list reaches
    the app (`HFCacheVerdictStore`) and that the two flux3 repo IDs are probed for
    download status; update `ModelAvailabilityTests` / `FakeRuntime` if they assert the
    model set.

### C. Warm driver (fast path) — PR 3

11. `Resources/mflux_driver.py` + `Runner/MfluxDriverController.swift`: add a `"flux3"`
    family branch for warm resident loads (fingerprint already keys on family+model;
    needs tool selection + text-encoder cache policy). Until it lands, flux3 jobs run
    through the standard CLI path — correctness first.

### D. Tests and verification

12. Unit tests in existing style (Swift Testing): PythonTool↔tools.txt equality; catalog
    invariants for new variants; availability/family-list assertions if they hardcode the
    model set.
13. Manual QA matrix: klein txt2img @16 steps · base @50 + guidance 3.5 · edit mode (txt+image) ·
    LoRA via `--lora` (if any flux3 LoRA exists to test with) · low-ram · cancel mid-run ·
    first-run download progress · second-run load time (CLI path).
14. Confirm the sandboxed (App Store) build is unaffected: all new paths flow through
    existing `effectiveMfluxCacheDir` plumbing.

## Open questions to resolve during implementation

- Distilled klein + `--guidance`: CLI warns and ignores. Precedent (`zimageTurbo`:
  "model forces guidance 0") suggests hiding the guidance control for the distilled
  variant — confirm UX preference.
- Quantization support and pre-quantized repo availability for flux3 (drives UI gating).
- Exact prompt-length cap and allowed dimensions for flux3 from mflux source.
- Whether 0.22.x changed anything user-visible in existing families; smoke-test all five
  families after the runtime rebuild, not just flux3.

## PR split (agreed)

App Store note: the App Store build stays on Image Studio 0.17.3 until the fsspec /
API-denylist gate passes for initial release; Flux 3 then ships as the 0.18.0 release.

1. **PR 1 — mflux bump.** `Runtime/requirements.in` → `mflux==0.23.0`, re-lock via
   `scripts/lock-python-runtime.sh`, runtime rebuild with all build gates (tool `--help`
   smoke, hf_cache_probe check, App Store API/denylist incl. fsspec). No app-visible change;
   review 0.22.x release notes for existing-family behavior changes and smoke-test all five
   families after the rebuild.
2. **PR 2 — CLI + GUI.** PythonTool/tools.txt cases, catalog variants (`flux3Klein`,
   `flux3KleinBase`), `FluxRunnerSpec.tool(job:)` selection, picker/settings verification,
   metadata/constraints touchpoints, availability probing, unit tests, manual QA matrix.
   Ships as 0.18.0 once PR 1's gate is green on the App Store build.
3. **PR 3 — warm driver support.** `"flux3"` family branch in `Resources/mflux_driver.py` +
   `MfluxDriverController.swift` (tool selection, text-encoder cache policy), driver tests.
