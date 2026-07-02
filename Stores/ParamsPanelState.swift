import Foundation

/// Mutable, observable state backing the FLUX params panel — the live form values
/// the user edits before queueing a job. Knows how to seed itself from saved
/// defaults, replay a gallery item's metadata, and mint a ``FluxJob``.
@Observable
final class ParamsPanelState {
    var model: FluxModelVariant = .flux2Klein9B
    var customModelRepo: String = ""
    var customBaseModel: FluxModelVariant = .flux2Klein9B
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var seed: Int = -1
    var steps: Int = 4
    var guidance: Double = 1.0
    var quantize: Int = 8
    var lowRam: Bool = false
    var loras: [LoraEntry] = []
    var imagePath: String = ""
    var imageStrength: Double = 0.75
    var isEditMode: Bool = false
    var editImagePaths: [String] = []
    var board: String = ""

    var modelFamily: ModelFamily {
        switch model {
        case .ideogram4: .ideogram4
        case .krea2: .krea2
        default: .flux
        }
    }

    func applyDefaults(from settings: AppSettings) {
        let m = settings.lastModel
        let d = settings.resolvedDefaults(for: m)
        model = m
        quantize = settings.lastQuantize
        board = settings.defaultBoard
        width = settings.lastWidth
        height = settings.lastHeight
        steps = d.steps
        guidance = d.guidance
        seed = -1
        lowRam = d.lowRam
        negativePrompt = d.negativePrompt
        // Build last-run lookup (safe against duplicate paths). Only include FLUX LoRAs —
        // global defaults may contain Ideogram entries that the Flux runner must not receive.
        let fluxDefaultLoras = settings.defaultLoras.filter { $0.modelFamily == .flux }
        let fluxLastLoras = settings.lastLoras.filter { $0.modelFamily == .flux }
        let lastByPath = Dictionary(
            fluxLastLoras.map { ($0.path, $0) }
        ) { first, _ in first }
        let defaultPaths = Set(fluxDefaultLoras.map(\.path))
        // Global defaults with enabled/strength restored from last run (notes stay from defaults).
        var loraResult = fluxDefaultLoras.map { global -> LoraEntry in
            guard let last = lastByPath[global.path] else { return global }
            var e = global; e.enabled = last.enabled; e.strength = last.strength; return e
        }
        // Session-only loras (added during a run but not in global defaults) persist across launches.
        loraResult += fluxLastLoras.filter { !defaultPaths.contains($0.path) }
        loras = loraResult
        prompt = settings.lastPrompt
    }

    func apply(metadata meta: GenerationMetadata, newSeed: Bool) {
        model = meta.model
        customModelRepo = meta.customModelRepo
        customBaseModel = meta.customBaseModel
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        quantize = meta.quantize
        lowRam = meta.lowRam
        imagePath = meta.imagePath
        imageStrength = meta.imageStrength
        loras = meta.loras
        board = meta.board ?? ""
        seed = newSeed ? -1 : meta.seed
    }

    /// Prompt + negative with the active templates chained on, before
    /// wildcard resolution. Wildcards resolve after templates so template
    /// text can carry {a|b} groups too.
    private func templatedPrompts(templates: [PromptTemplate]) -> (positive: String, negative: String) {
        var finalPrompt = prompt
        var finalNegative = negativePrompt
        for template in templates {
            let applied = template.apply(
                to: finalPrompt,
                negativePrompt: finalNegative,
                supportsNegativePrompt: model.supportsNegativePrompt
            )
            finalPrompt = applied.positive
            finalNegative = applied.negative
        }
        return (finalPrompt, finalNegative)
    }

    /// How many jobs the current prompt naturally expands to (largest
    /// wildcard group across prompt + negative, templates applied); 1 when
    /// there are no wildcards. Uncapped — the caller applies the batch cap.
    func wildcardVariantCount(templates: [PromptTemplate]) -> Int {
        let (positive, negative) = templatedPrompts(templates: templates)
        return max(WildcardExpander.variantCount(positive), WildcardExpander.variantCount(negative))
    }

    func makeJob(count: Int = 1, templates: [PromptTemplate] = [], wildcardVariant: Int = 0) -> FluxJob {
        let seeds: [Int] = count > 1
            ? (0 ..< count).map { _ in Int(UInt32.random(in: 0 ..< UInt32.max)) }
            : []
        let templated = templatedPrompts(templates: templates)
        let finalPrompt = WildcardExpander.expandVariant(templated.positive, index: wildcardVariant)
        let finalNegative = WildcardExpander.expandVariant(templated.negative, index: wildcardVariant)
        return FluxJob(
            model: model,
            customModelRepo: customModelRepo,
            customBaseModel: customBaseModel,
            prompt: finalPrompt,
            negativePrompt: finalNegative,
            width: width,
            height: height,
            seed: seed,
            seeds: seeds,
            steps: steps,
            guidance: guidance,
            loras: loras,
            quantize: quantize,
            lowRam: lowRam,
            imagePath: imagePath,
            imageStrength: imageStrength,
            isEditMode: isEditMode,
            editImagePaths: editImagePaths,
            board: board
        )
    }
}
