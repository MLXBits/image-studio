# MLXBits Image Studio — Roadmap

## In progress

### Ideogram 4 — awaiting upstream mflux merge

The Ideogram 4 UI is complete and shipping: structured-caption editor,
Gemma-assisted caption generation, regional bounding-box layout editor, color
palettes with hex entry, and an FP8/Q8/Q4 precision selector. Generation drives
the `mflux-generate-ideogram4` CLI, which is **not yet in a published mflux
release** — Ideogram 4 jobs show a "binary not found" error until that support
merges. FLUX generation is unaffected.

## Planned

### Additional mflux models (ERNIE-Image-Turbo)

**Analysis:** [`.claude/plans/one-of-my-image-logical-zephyr.md`](.claude/plans/one-of-my-image-logical-zephyr.md)

mflux supports several image models beyond those we ship. After a value÷effort review, the approved batch was three; **Z-Image and Z-Image Turbo have now shipped** (see below), leaving ERNIE-Image-Turbo next. Qwen-Image-Edit and FIBO are deferred, and FLUX.1-legacy is out of scope (deprecation risk upstream).

Structural note: none of these can use the cheap `FluxModelVariant`-case path — that only works for more **Flux.2** sizes. Every other mflux model uses a different architecture/CLI/encoder, so each is a full "new family" (new `JobRunnerSpec`, `mflux_driver.py` branch, params panel, settings form, `ContentView` wiring). Effort differences come down to how exotic each one's params/modes are.

Next up:

1. **ERNIE-Image-Turbo** — same Krea-2/Z-Image-shaped effort; **smallest footprint of all candidates (q4 ~6.2 GB, q8 ~12 GB)** — the "runs on any Mac" win. Reuses the twin-panel plumbing proven out by Z-Image. CLI `mflux-generate-ernie-image-turbo`.

Deferred: **Qwen-Image-Edit** (~58 GB + net-new multi-image edit UI) and **FIBO** (JSON-native caption editor + ~8 GB companion VLM + multiple modes incl. RMBG background removal).

## Shipped

### Z-Image & Z-Image Turbo

Alibaba Tongyi's single-stream DiT text-to-image model, shipped as a new
`.zimage` family with **both variants**: the distilled, guidance-free **Z-Image
Turbo** (9-step) and the classifier-free-guidance **base Z-Image** (~50-step,
negative prompt). Full Krea 2 parity — one-shot CLI + warm persistent driver,
LoRA, img2img (image-strength), a BF16/Q8/Q4 precision selector, metadata
sidecars with remix/apply, and a Settings → Models form per variant. Turbo Q4
loads the pre-quantized `filipstrand/Z-Image-Turbo-mflux-4bit` repo directly;
other precisions use the one-time `mflux-save` pass. Drives
`mflux-generate-z-image-turbo` / `mflux-generate-z-image`.

### SeedVR2 upscaler

Diffusion super-resolution as an **"Upscale…" action** on gallery / preview / thumbnail images (not a model-picker family). Scale-factor sheet (2×/3×/4× with live target-dims), softness, 3B/7B, quantize, and a seed control matching the generation panels. Runs the native-MLX `mflux-upscale-seedvr2` via a 4th `JobRunner` family (CLI path, gate-serialized against the generative families). Outputs inherit their source image's family/board so they sit next to the original in the gallery. Settings → Models → Upscale ▸ SeedVR2 holds the remembered defaults.

Known limitation: no on-disk quantized-weights cache — `mflux-save` doesn't support SeedVR2 upstream (no `save_model`), so each run cold-loads fp16 and quantizes in memory. Revisit with an upstream mflux PR if 7B's per-run load proves too heavy.
