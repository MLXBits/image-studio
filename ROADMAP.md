# MLXBits Image Studio — Roadmap

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
