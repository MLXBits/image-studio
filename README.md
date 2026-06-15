# MLXBits Image Studio

A native macOS app for **FLUX image generation** powered by [mflux](https://github.com/filipstrand/mflux) and Apple MLX. Queue jobs, watch generations unfold step-by-step, and browse your history — all without leaving the GPU.

> **Requires macOS Sequoia 26.5+** and [mflux](https://github.com/filipstrand/mflux) installed via `uv` or `pip`.

---

## Screenshots

<!-- Replace the placeholders below with actual screenshots before publishing. -->
<!-- Suggested shots:
     1. Full app window (params + live preview + gallery)
     2. ParamsPanel close-up (model picker, prompt, LoRA manager)
     3. Step-by-step live preview during generation
     4. Gallery with metadata panel open
     5. Settings → Model Defaults tab
-->

| Main window | Live preview |
|---|---|
| *(screenshot)* | *(screenshot)* |

| Gallery | Settings |
|---|---|
| *(screenshot)* | *(screenshot)* |

---

## Features

- **Text-to-image and image-to-image** generation via FLUX.2 Klein models
- **Step-by-step live preview** — watch the image denoise in real time
- **Persistent job queue** — queue multiple jobs, they survive app restarts
- **Gallery** — scrollable history of every generation with thumbnail cache and metadata sidecars
- **LoRA support** — add any number of LoRA adapters with per-adapter strength sliders
- **Batch generation** — run 1, 4, or a custom count with auto-incrementing seeds
- **Model defaults** — save per-model presets (steps, guidance, LoRAs, dimensions)
- **Prompt templates** — save and reuse favourite prompt fragments
- **Low-RAM mode** — streams transformer blocks to cut peak Metal memory ~75%
- **HuggingFace integration** — enter your HF token once (stored in Keychain); gated models download automatically

## Supported models

| Variant | Steps | Notes |
|---|---|---|
| FLUX.2 Klein 4B (distilled) | 4 min | Fastest |
| FLUX.2 Klein 9B (distilled) | 4 min | Best quality/speed trade-off |
| FLUX.2 Klein 4B (base) | ~50 | Full diffusion |
| FLUX.2 Klein 9B (base) | ~50 | Full diffusion |
| Custom | any | Any HuggingFace repo ID or local path |

---

## Requirements

| Requirement | Version |
|---|---|
| macOS | Sequoia 26.5+ |
| Apple Silicon | M1 or later |
| mflux | 0.17+ |
| uv *(optional but recommended)* | latest |

Install mflux:

```bash
# with uv (recommended)
uv tool install mflux

# or pip
pip install mflux
```

---

## Installation

Download the latest `MLXBits_Image_Studio_<version>.dmg` from [Releases](../../releases), open it, and drag **MLXBits Image Studio** to `/Applications`.

On first launch macOS may show a Gatekeeper prompt — right-click the app and choose **Open** to bypass it (the app is notarized).

---

## Building from source

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [SwiftLint](https://github.com/realm/SwiftLint), [SwiftFormat](https://github.com/nicklockwood/SwiftFormat).

```bash
brew install xcodegen swiftlint swiftformat

git clone https://github.com/YOUR_USERNAME/mlxbits-image-studio
cd mlxbits-image-studio

# Generate the Xcode project
xcodegen generate

# Open and build in Xcode
open "MLXBits Image Studio.xcodeproj"
```

> **Signing:** Set `DEVELOPMENT_TEAM` in `project.yml` to your 10-character Apple Developer Team ID before building a signed Release. Debug builds are unsigned and work without a Team ID.

---

## Creating a signed release DMG

```bash
# 1. Store notarytool credentials once
xcrun notarytool store-credentials "notarytool" \
  --apple-id "your@email.com" \
  --team-id YOUR_TEAM_ID \
  --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com

# 2. Set your Team ID (10-char string from developer.apple.com → Membership)
export DEVELOPMENT_TEAM=YOUR_TEAM_ID
# or store it in a gitignored .env file:  echo "DEVELOPMENT_TEAM=YOUR_TEAM_ID" > .env && source .env

# 3. Run the release script
./release.sh 0.1.0
# → build/MLXBits_Image_Studio_0.1.0.dmg (notarized + stapled)
```

---

## Project layout

```
App/           App entry point and root layout
Models/        Data models (FluxJob, LoraEntry, PromptTemplate, catalog)
Runner/        FluxJobRunner — spawns mflux subprocess, streams output
Stores/        AppSettings, JobStore, GalleryStore (Observable state)
Views/         SwiftUI views (ParamsPanel, PreviewPane, Gallery, Queue, Settings)
Utilities/     KeychainHelper, MetadataSidecar, ThumbnailCache, progress parser
Resources/     Info.plist, entitlements
project.yml    XcodeGen source of truth (never edit .xcodeproj directly)
release.sh     Archive → notarize → DMG pipeline
```

---

## License

MIT — see [LICENSE](LICENSE).
