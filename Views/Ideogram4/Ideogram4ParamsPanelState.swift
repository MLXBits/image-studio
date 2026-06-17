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

    var canGenerate: Bool {
        if usePlainPrompt {
            return !plainPrompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !caption.highLevelDescription.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func applyDefaults(settings: AppSettings) {
        preset = settings.lastIdeogramPreset ?? .normal
        width = settings.lastIdeogramWidth ?? 1024
        height = settings.lastIdeogramHeight ?? 1024
        quantize = 0 // FP8 only — quantization not yet supported for Ideogram 4
        lowRam = false
        board = settings.defaultBoard
        if let cap = settings.lastIdeogramCaption { caption = cap }
        if let prompt = settings.lastIdeogramPlainPrompt { plainPrompt = prompt }
        if let usePlain = settings.lastIdeogramUsePlainPrompt { usePlainPrompt = usePlain }
        loras = settings.defaultLoras.filter { $0.modelFamily == .ideogram4 }
    }

    /// Replays a completed generation's settings back into the form.
    /// `newSeed == true` (Remix) resets the seed to random; otherwise the
    /// original seed is restored. LoRAs are not captured in the sidecar and
    /// are left untouched.
    func apply(metadata meta: Ideogram4Metadata, newSeed: Bool) {
        caption = meta.caption
        usePlainPrompt = meta.usePlainPrompt
        plainPrompt = meta.plainPrompt
        preset = meta.preset
        width = meta.width
        height = meta.height
        quantize = meta.quantize
        lowRam = meta.lowRam
        board = meta.board ?? ""
        batchSeeds = []
        seed = newSeed ? -1 : meta.seed
    }

    func makeJob() -> Ideogram4Job {
        let job = Ideogram4Job(
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
            board: board
        )
        if !batchSeeds.isEmpty {
            job.seeds = batchSeeds
        }
        return job
    }

    func isReadyToGenerate(settings _: AppSettings) -> Bool {
        canGenerate
    }
}
