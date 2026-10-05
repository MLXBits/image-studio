# App Store listing — MLXBits Image Studio

Paste each block into App Store Connect as is. `python3 scripts/check_appstore_listing.py` checks every length; run it after any edit.

## App information

### Name (max 30)

```text
MLXBits Image Studio
```

### Subtitle (max 30)

```text
Local AI images on your Mac
```

- **Category:** Graphics & Design (secondary: none)
- **Privacy policy URL:** https://github.com/MLXBits/image-studio/blob/main/PRIVACY.md
- **Support URL:** https://github.com/MLXBits/image-studio/issues
- **Marketing URL:** leave empty (the repo page links to other ways of paying)
- **Copyright:** © 2026 MLXBits

## Version page

### Promotional text (max 170)

```text
Generate images with FLUX.2, Krea 2 and Z-Image entirely on your Mac. No account, no cloud, no subscription. Every feature is free.
```

### Keywords (max 100)

```text
ai art,image generator,text to image,image editor,mlx,lora,offline,local ai,prompt,generative,photo
```

### Description (max 4000)

```text
MLXBits Image Studio turns text into images on your Mac, using Apple's MLX framework and the Apple silicon GPU. Nothing is sent to us: your prompts and pictures stay on your Mac unless you connect a server of your own.

GENERATE
• FLUX.2 Klein (4B and 9B), Krea 2 and Z-Image Turbo, with quantized versions for Macs with less memory
• Image editing and image-to-image with your own photos
• LoRAs from any folder, saved as one-click stacks
• A queue: line up dozens of prompts and walk away

SEE IT HAPPEN
• Watch each image take shape step by step
• Keep the model loaded between runs, so back-to-back images skip the load

ORGANISE
• A fast gallery with boards, ratings, flags and side-by-side comparison
• Profiles keep separate libraries, prompts and history, for example personal and work
• Every image remembers its prompt, seed and settings

WRITE BETTER PROMPTS
• Templates, wildcards, a notepad and prompt history
• An optional local language model (Gemma) that writes and varies prompts for you, also on-device

REQUIREMENTS
• A Mac with Apple silicon (M1 or later) and macOS 26
• 16 GB of unified memory or more; 32 GB or more for the larger models
• Model weights download from Hugging Face the first time you use a model (about 8 GB for the smallest). Point the app at an existing Hugging Face folder and it reuses what you already have.

FREE
Every feature is free. Optional tips help keep the project going and unlock nothing.

Images are made from your own prompts, on your Mac. The app can create mature images, so it is rated 18+.
```

Not shown for the first version; keep for later updates.

### What's New (max 4000)

```text
First App Store release.
```

## In-app purchases

All three are Consumable. Product IDs can't be changed or reused once created, so copy them exactly:

| Reference name | Product ID | Price |
|---|---|---|
| Small Tip | `com.mlxbits.image-studio.appstore.tip.small` | $2.99 |
| Medium Tip | `com.mlxbits.image-studio.appstore.tip.medium` | $4.99 |
| Large Tip | `com.mlxbits.image-studio.appstore.tip.large` | $9.99 |

Each gets the same review screenshot: the Support window, with tips loaded, over the main window (SFW profile).

### Small Tip display name (max 30)

```text
Small Tip
```

### Small Tip description (max 45)

```text
A small thank-you. Unlocks nothing.
```

### Medium Tip display name (max 30)

```text
Medium Tip
```

### Medium Tip description (max 45)

```text
A medium thank-you. Unlocks nothing.
```

### Large Tip display name (max 30)

```text
Large Tip
```

### Large Tip description (max 45)

```text
A large thank-you. Unlocks nothing.
```

### Tip review notes (max 4000)

```text
A tip to support the developer. It is a consumable that unlocks no features or content. Open it from the app menu: MLXBits Image Studio ▸ Support MLXBits Image Studio…, or Settings ▸ Advanced ▸ Support. The same window offers all three tips.
```

## App Review

### Review notes (max 4000)

```text
MLXBits Image Studio generates images on-device with Apple MLX. It needs Apple silicon and at least 16 GB of unified memory.

FIRST IMAGE (about 10 minutes, mostly the download)
1. On first launch, choose a library folder and click Done, or click Skip for Now (it uses Pictures ▸ MLXBits Image Studio).
2. On the models step, click Keep Models in the App (or Continue).
3. In the model menu at the top left, choose FLUX.2 Klein 4B and set quantization to Q8.
4. Type a prompt, for example "a red fox in fresh snow, morning light", and click Generate.
The first run downloads the model weights from Hugging Face, about 8 GB, with progress shown. Later runs take seconds.

BUNDLED CODE (guideline 2.5.2)
The app ships its own Python 3.14 runtime with the open-source mflux and MLX libraries inside the signed app bundle; every executable is signed and sandboxed with the app. The app downloads only model data (weights, configs, tokenizers) from Hugging Face. No downloaded file is imported or executed, and remote code loading is off. It never downloads or runs code from outside its bundle.

NETWORK
Hugging Face for model weights. Optionally, servers the user sets up on their own network (LM Studio, ComfyUI) or an OpenAI-compatible service, used only when configured in Settings. Nothing is sent to the developer; the app collects no data.

TIPS
Three consumable in-app purchases in the Support window (app menu ▸ Support MLXBits Image Studio…). They unlock nothing; every feature is free.

CONTENT
Images are generated from the user's own prompts, locally, with no content filter. The app is rated 18+ accordingly, as are comparable apps such as Draw Things.
```

## Age rating answers

Answer honestly; these are the expected answers. The app is already set to 18+.
- **Sexual content or nudity:** frequent or intense (it can generate such images on request; there's no filter)
- **Graphic violence, horror, mature themes:** infrequent or mild (possible on request)
- **User-generated content shared with others:** no (nothing is shared or uploaded)
- **Unrestricted web access:** no
- **Gambling, contests, alcohol and drugs, medical:** no

## App privacy answers

- **Data collection:** "No, we do not collect data from this app."
- Tips are processed by Apple; the developer doesn't receive purchase data that counts as collection.

## Screenshots

- **Size:** 2880×1800 (or 2560×1600), Mac. Up to 10; the first three matter most.
- **Profile:** SFW, with a clean prompt box and gallery.

1. The main window: a finished image, the params panel and a full gallery.
2. Step-by-step preview mid-generation.
3. The gallery's compare view or boards with ratings.
4. The LoRA manager with a stack.
5. The Scenario Generator writing prompts.

No links to other ways of paying in any shot.
