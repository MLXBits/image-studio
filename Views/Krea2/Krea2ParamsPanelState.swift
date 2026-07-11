import Foundation

/// Persistable snapshot of the Krea 2 form, remembered across app launches.
/// Decoded defensively (every field `decodeIfPresent ?? default`) so adding a
/// field never silently wipes a saved snapshot. Seed is intentionally not stored
/// — generation defaults to a fresh random seed on launch, matching Flux.
struct Krea2FormState: Codable {
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var steps: Int = 8
    var guidance: Double = 1.0
    var quantize: Int = 8
    var loras: [LoraEntry] = []
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
        steps = (try? c.decode(Int.self, forKey: .steps)) ?? 8
        guidance = (try? c.decode(Double.self, forKey: .guidance)) ?? 1.0
        quantize = (try? c.decode(Int.self, forKey: .quantize)) ?? 8
        loras = (try? c.decode([LoraEntry].self, forKey: .loras)) ?? []
        imagePath = (try? c.decode(String.self, forKey: .imagePath)) ?? ""
        imageStrength = (try? c.decode(Double.self, forKey: .imageStrength)) ?? 0.75
        board = (try? c.decode(String.self, forKey: .board)) ?? ""
    }
}

/// Observable form state for the Krea 2 Turbo params panel.
@Observable
@MainActor
final class Krea2ParamsPanelState {
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var steps: Int = 8
    var guidance: Double = 1.0
    var seed: Int = -1
    var batchSeeds: [Int] = []
    var quantize: Int = 8
    var loras: [LoraEntry] = []
    var imagePath: String = ""
    var imageStrength: Double = 0.75
    var board: String = ""

    var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func applyDefaults(settings: AppSettings, library: LoraLibraryStore) {
        // Restore the last-used form across launches when present; otherwise fall
        // back to the model defaults from Settings → Models.
        if let s = settings.lastKrea2 {
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
            loras = s.loras.isEmpty ? library.defaultLoras(for: .krea2) : s.loras
            seed = -1
            return
        }
        let d = settings.resolvedDefaults(for: .krea2)
        steps = d.steps
        guidance = d.guidance
        quantize = d.quantize
        width = d.width
        height = d.height
        board = settings.defaultBoard
        seed = -1
        loras = library.defaultLoras(for: .krea2)
    }

    /// Captures the current form for cross-launch persistence (seed excluded).
    func snapshot() -> Krea2FormState {
        var s = Krea2FormState()
        s.prompt = prompt
        s.negativePrompt = negativePrompt
        s.width = width
        s.height = height
        s.steps = steps
        s.guidance = guidance
        s.quantize = quantize
        s.loras = loras
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
              let meta = MetadataSidecar.readKrea2(for: path) else { return }
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
    }

    /// Replays a completed generation's settings back into the form.
    /// `newSeed == true` (Remix) resets the seed to random; otherwise the original
    /// seed is restored. LoRAs are restored when present in the sidecar.
    func apply(metadata meta: Krea2Metadata, newSeed: Bool) {
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        quantize = meta.quantize
        if let savedLoras = meta.loras { loras = savedLoras }
        imagePath = meta.imagePath ?? ""
        imageStrength = meta.imageStrength ?? 0.75
        board = meta.board ?? ""
        batchSeeds = []
        seed = newSeed ? -1 : meta.seed
    }

    /// Builds a job. `resolvedPrompt` supplies fully-resolved prompt text for
    /// wildcard batches; when nil, any wildcards collapse to a single sample.
    func makeJob(count: Int = 1, resolvedPrompt: (positive: String, negative: String)? = nil) -> Krea2Job {
        let finalPrompt = resolvedPrompt?.positive
            ?? WildcardExpander.expandVariants(prompt, count: 1).first ?? prompt
        let finalNegative = resolvedPrompt?.negative
            ?? WildcardExpander.expandVariants(negativePrompt, count: 1).first ?? negativePrompt
        let job = Krea2Job(
            prompt: finalPrompt,
            negativePrompt: finalNegative,
            width: width,
            height: height,
            seed: seed,
            steps: steps,
            guidance: guidance,
            quantize: quantize,
            loras: loras,
            imagePath: imagePath,
            imageStrength: imageStrength,
            board: board
        )
        if count > 1 {
            // Matches Flux.2's batch button: auto-generate N random seeds into one
            // warm job (single mflux process, model loaded once).
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
