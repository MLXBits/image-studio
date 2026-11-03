# FLUX.2 Klein 9B

The 9B variant of the FLUX.2 Klein family — the best quality/speed trade-off of
the FLUX.2 models. It ships in two flavors:

- **FLUX.2 Klein 9B (distilled)** — 4 steps, guidance-free (guidance is fixed at
  1.0). Fast, with the 9B model's higher quality.
- **FLUX.2 Klein Base 9B** — ~50 steps with classifier-free guidance and a
  negative prompt. Full diffusion for maximum control.

Both flavors do text-to-image, image-to-image, and multi-reference editing (up to
6 references), and take any number of LoRA adapters with per-adapter strength.

## Local or remote

FLUX.2 Klein 9B can generate **locally** on your Mac or **remotely** on a ComfyUI
server — choose per variant in **Settings → Models → FLUX.2 Klein 9B** (the
**Inference backend** picker).

- **Local (mflux / MLX)** — the default. Runs on your Apple Silicon with no
  server; the weights download from HuggingFace on first use. Steps, guidance,
  quantization, and low-RAM mode are set here.
- **Remote (ComfyUI)** — routes the job to a ComfyUI server. Set the server URL
  and the variant's three model files (**UNet model**, **CLIP encoder**, **VAE**)
  under the variant's section. The app warns until all three are set. Local mflux
  and the remote config are saved independently, so switching back never loses
  either. If the files are incomplete, a job falls back to local mflux
  automatically.

> **Before first use (remote):** enter the ComfyUI server URL and the UNet/CLIP/VAE
> filenames for the variant. Expected names are `flux-2-klein-9b-fp8.safetensors`
> (distilled) / `flux-2-klein-base-9b-fp8.safetensors` (base),
> `qwen_3_8b_fp8mixed.safetensors` for the CLIP encoder, and
> `full_encoder_small_decoder.safetensors` for the VAE. On reference-conditioned
> (edit) jobs routed remote, the `imageStrength` slider is hidden — those flows
> have no denoise knob.
