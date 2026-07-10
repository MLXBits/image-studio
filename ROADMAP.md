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

### Additional mflux models (Z-Image-Turbo, ERNIE-Image-Turbo, SeedVR2)

**Analysis:** [`.claude/plans/one-of-my-image-logical-zephyr.md`](.claude/plans/one-of-my-image-logical-zephyr.md)

mflux supports several image models beyond the three we ship (Flux.2, Ideogram 4, Krea 2). After a value÷effort review, the approved next batch is three; Qwen-Image-Edit and FIBO are deferred, and FLUX.1-legacy is out of scope (deprecation risk upstream).

Structural note: none of these can use the cheap `FluxModelVariant`-case path — that only works for more **Flux.2** sizes. Every other mflux model uses a different architecture/CLI/encoder, so each is a full "new family" (new `JobRunnerSpec`, `mflux_driver.py` branch, params panel, settings form, `ContentView` wiring). Effort differences come down to how exotic each one's params/modes are.

Build order (value ÷ effort):

1. **Z-Image-Turbo** — mflux's fastest/smallest quality model (6B, 9-step). Cheapest new family: params clone the existing **Krea 2** panel (steps/seed/img2img-strength, guidance hidden). q4 community build exists (`filipstrand/Z-Image-Turbo-mflux-4bit`). CLI `mflux-generate-z-image-turbo`; ship `z-image` base as a precision peer.
2. **ERNIE-Image-Turbo** — same Krea-2-shaped effort; **smallest footprint of all candidates (q4 ~6.2 GB, q8 ~12 GB)** — the "runs on any Mac" win. Do back-to-back with #1 to amortize the twin-panel plumbing. CLI `mflux-generate-ernie-image-turbo`.
3. **SeedVR2** — upscaler, _different shape_: no prompt/model-picker slot. Wire as an **"Upscale" action on gallery images** (resolution/softness sheet). CLI `mflux-upscale-seedvr2`; default `seedvr2-3b`, expose `-7b` as a quality toggle. Pairs with every existing model.

Deferred: **Qwen-Image-Edit** (~58 GB + net-new multi-image edit UI) and **FIBO** (JSON-native caption editor + ~8 GB companion VLM + multiple modes incl. RMBG background removal).
