import Foundation

/// Observable form state for the Ideogram 4 params panel.
@Observable
@MainActor
final class Ideogram4ParamsPanelState {
    var caption: IdeogramCaption = .empty()
    var usePlainPrompt: Bool = false
    var plainPrompt: String = ""
    var preset: Ideogram4Preset = .normal
    var width: Int = 1024
    var height: Int = 1024
    var seed: Int = -1
    var batchSeeds: [Int] = []
    var quantize: Int = 0
    var lowRam: Bool = false
    var strictValidation: Bool = false
    var loras: [LoraEntry] = []
    var board: String = ""
    /// Decode with PiD instead of the VAE (output is 4x these dimensions).
    var pidDecode: Bool = false
    /// Latent degradation for PiD (0.0-0.8); ignored unless `pidDecode`.
    var pidDegradeSigma: Double = 0.0

    var canGenerate: Bool {
        if usePlainPrompt {
            return !plainPrompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !caption.highLevelDescription.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func applyDefaults(settings: AppSettings, library: LoraLibraryStore) {
        let last = settings.lastForms.ideogram4
        let defaults = settings.defaults(for: .ideogram4)
        preset = last.preset ?? settings.ideogram4Preset
        width = last.width ?? defaults.width ?? 1024
        height = last.height ?? defaults.height ?? 1024
        // BF16 (0), Q8, or Q4: each an mflux-community repo.
        quantize = last.quantize ?? defaults.quantize ?? 8
        seed = last.seed ?? -1
        lowRam = settings.ideogram4LowRam
        strictValidation = settings.ideogram4StrictValidation
        board = settings.defaultBoard
        if let cap = last.caption {
            caption = cap
        }
        if let prompt = last.plainPrompt {
            plainPrompt = prompt
        }
        if let usePlain = last.usePlainPrompt {
            usePlainPrompt = usePlain
        }
        loras = library.defaultLoras(for: .ideogram4)
    }

    /// The form as ``LastForms`` saves it.
    func snapshot() -> Ideogram4FormState {
        Ideogram4FormState(
            preset: preset, width: width, height: height, quantize: quantize,
            caption: caption, plainPrompt: plainPrompt, usePlainPrompt: usePlainPrompt, seed: seed
        )
    }

    /// Replays a completed generation's settings back into the form.
    /// `newSeed == true` (Remix) resets the seed to random; otherwise the
    /// original seed is restored. LoRAs are restored when present in the sidecar
    /// (older sidecars predate LoRA capture and leave the current selection).
    func apply(metadata meta: Ideogram4Metadata, newSeed: Bool) {
        caption = meta.caption
        usePlainPrompt = meta.usePlainPrompt
        plainPrompt = meta.plainPrompt
        preset = meta.preset
        width = meta.width
        height = meta.height
        quantize = meta.quantize
        lowRam = meta.lowRam
        if let savedLoras = meta.loras {
            loras = savedLoras
        }
        board = meta.board ?? ""
        pidDecode = meta.pidDecode ?? false
        pidDegradeSigma = meta.pidDegradeSigma ?? 0.0
        batchSeeds = []
        seed = newSeed ? -1 : meta.seed
    }

    /// `customModelRepo` carries the picker's `Custom…` entry when a custom
    /// checkpoint is being loaded through the Ideogram 4 pipeline; empty otherwise.
    func makeJob(count: Int = 1, customModelRepo: String = "") -> Ideogram4Job {
        let job = Ideogram4Job(
            customModelRepo: customModelRepo,
            preset: preset,
            caption: caption,
            usePlainPrompt: usePlainPrompt,
            plainPrompt: plainPrompt,
            width: Ideogram4Preset.clampDimension(width),
            height: Ideogram4Preset.clampDimension(height),
            seed: seed,
            quantize: quantize,
            lowRam: lowRam,
            strictValidation: strictValidation,
            loras: loras,
            board: board,
            pidDecode: pidDecode,
            pidDegradeSigma: pidDegradeSigma
        )
        job.applyBatchSeeds(count: count, typed: batchSeeds)
        return job
    }
}
