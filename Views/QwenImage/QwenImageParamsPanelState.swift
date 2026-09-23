import Foundation

/// Persistable snapshot of the Qwen-Image 2.1 form, remembered across app launches.
/// Decoded defensively (every field `decodeIfPresent ?? default`) so adding a
/// field never silently wipes a saved snapshot. Seed is intentionally not stored:
/// generation defaults to a fresh random seed on launch, matching Flux.
struct QwenImageFormState: Codable {
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var steps: Int = 40
    var guidance: Double = 1.0
    var quantize: Int = 0
    var imagePath: String = ""
    var imageStrength: Double = 0.75
    var board: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        negativePrompt = (try? c.decode(String.self, forKey: .negativePrompt)) ?? ""
        width = (try? c.decode(Int.self, forKey: .width)) ?? 1024
        height = (try? c.decode(Int.self, forKey: .height)) ?? 1024
        steps = (try? c.decode(Int.self, forKey: .steps)) ?? 40
        guidance = (try? c.decode(Double.self, forKey: .guidance)) ?? 1.0
        quantize = (try? c.decode(Int.self, forKey: .quantize)) ?? 0
        imagePath = (try? c.decode(String.self, forKey: .imagePath)) ?? ""
        imageStrength = (try? c.decode(Double.self, forKey: .imageStrength)) ?? 0.75
        board = (try? c.decode(String.self, forKey: .board)) ?? ""
    }
}

/// Observable form state for the Qwen-Image 2.1 params panel.
@Observable
@MainActor
final class QwenImageParamsPanelState {
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var steps: Int = 40
    var guidance: Double = 1.0
    var seed: Int = -1
    var batchSeeds: [Int] = []
    var quantize: Int = 0
    var imagePath: String = ""
    var imageStrength: Double = 0.75
    var board: String = ""

    /// The catalog entry this form generates with.
    var variant: FluxModelVariant {
        .qwenImage21
    }

    /// Whether the negative prompt takes effect: mflux runs true classifier-free
    /// guidance only above guidance 1.
    var usesTrueCFG: Bool {
        guidance > 1.0
    }

    var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func applyDefaults(settings: AppSettings) {
        // Restore the last-used form across launches when present; otherwise fall
        // back to the model defaults from Settings → Models.
        if let s = settings.lastQwenImage {
            prompt = s.prompt
            negativePrompt = s.negativePrompt
            width = s.width
            height = s.height
            steps = s.steps
            guidance = s.guidance
            quantize = s.quantize
            imagePath = s.imagePath
            imageStrength = s.imageStrength
            board = s.board
            seed = -1
            return
        }
        let d = settings.resolvedDefaults(for: variant)
        steps = d.steps
        guidance = d.guidance
        quantize = d.quantize
        width = d.width
        height = d.height
        board = settings.defaultBoard
        seed = -1
    }

    /// Captures the current form for cross-launch persistence (seed excluded).
    func snapshot() -> QwenImageFormState {
        var s = QwenImageFormState()
        s.prompt = prompt
        s.negativePrompt = negativePrompt
        s.width = width
        s.height = height
        s.steps = steps
        s.guidance = guidance
        s.quantize = quantize
        s.imagePath = imagePath
        s.imageStrength = imageStrength
        s.board = board
        return s
    }

    /// Adopts a generated candidate's resolved prompt when it becomes the
    /// img2img reference and the prompt box still holds wildcards, so
    /// refinement varies the exact base instead of re-sampling.
    func adoptResolvedPromptForImg2Img(at path: String) {
        guard WildcardExpander.containsWildcards(prompt),
              let meta = MetadataSidecar.readQwenImage(for: path) else { return }
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
    }

    /// Replays a completed generation's settings back into the form.
    /// `newSeed == true` (Remix) resets the seed to random; otherwise the original
    /// seed is restored.
    func apply(metadata meta: QwenImageMetadata, newSeed: Bool) {
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        quantize = meta.quantize
        imagePath = meta.imagePath ?? ""
        imageStrength = meta.imageStrength ?? 0.75
        board = meta.board ?? ""
        batchSeeds = []
        seed = newSeed ? -1 : meta.seed
    }

    /// Builds a job. `resolvedPrompt` supplies fully-resolved prompt text for
    /// wildcard batches; when nil, any wildcards collapse to a single sample.
    /// `customModelRepo` carries the picker's `Custom…` entry when a custom
    /// checkpoint is being loaded through the Qwen-Image pipeline; empty otherwise.
    func makeJob(
        count: Int = 1,
        customModelRepo: String = "",
        resolvedPrompt: (positive: String, negative: String)? = nil
    ) -> QwenImageJob {
        let finalPrompt = resolvedPrompt?.positive
            ?? WildcardExpander.expandVariants(prompt, count: 1).first ?? prompt
        let finalNegative = resolvedPrompt?.negative
            ?? WildcardExpander.expandVariants(negativePrompt, count: 1).first ?? negativePrompt
        let job = QwenImageJob(
            customModelRepo: customModelRepo,
            prompt: finalPrompt,
            negativePrompt: finalNegative,
            width: width,
            height: height,
            seed: seed,
            steps: steps,
            guidance: guidance,
            quantize: quantize,
            imagePath: imagePath,
            imageStrength: imageStrength,
            board: board
        )
        if count > 1 {
            // Matches Flux.2's batch button: auto-generate N random seeds into one
            // job (single mflux process, model loaded once).
            job.seeds = (0 ..< count).map { _ in Int(UInt32.random(in: 0 ..< UInt32.max)) }
        } else if !batchSeeds.isEmpty {
            job.seeds = batchSeeds
        }
        return job
    }

    func isReadyToGenerate(settings _: AppSettings) -> Bool {
        canGenerate
    }
}
