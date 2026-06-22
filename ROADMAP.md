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

### Keep Model Warm (Persistent Daemon)
**Plan:** [`.claude/plans/image-studio-keep-model-warm-daemon.md`](.claude/plans/image-studio-keep-model-warm-daemon.md)

Replace the current one-shot subprocess-per-job architecture with a persistent `mflux-daemon` Python process that keeps the model loaded in Metal memory between generations. Communication via Unix domain socket (newline-delimited JSON). Eliminates the model reload cost on back-to-back jobs.

Key points:
- Settings toggle with memory warning for ≤32 GB Macs
- Idle timeout auto-unloads weights (process stays alive, saving ~3s of Python/mflux import time)
- Manual Eject button in app header
- `--low-ram` jobs always fall back to the existing one-shot CLI path
- Requires `mflux-daemon` entry point added to mflux
