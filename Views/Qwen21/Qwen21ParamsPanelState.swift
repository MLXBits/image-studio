import Foundation

/// The Qwen-Image 2.1 form as remembered across launches. Every field is
/// optional so a snapshot from an older build still decodes; seed is left out,
/// so each launch starts on a random seed.
struct Qwen21FormState: Codable {
    var prompt: String?
    var isEditMode: Bool?
    var editImagePaths: [String]?
    var matchReferenceSize: Bool?
    var width: Int?
    var height: Int?
    var steps: Int?
    var quantize: Int?
    var loras: [LoraEntry]?
    var board: String?
}

/// Observable form state for the Qwen-Image 2.1 Turbo params panel.
@Observable
@MainActor
final class Qwen21ParamsPanelState {
    private static let model = FluxModelVariant.qwen21Turbo

    var prompt: String = ""
    var isEditMode: Bool = false
    var editImagePaths: [String] = []
    /// Edit mode: size the output from the references instead of width × height.
    var matchReferenceSize: Bool = true
    var width: Int = 1024
    var height: Int = 1024
    var steps: Int = 8
    var seed: Int = -1
    var batchSeeds: [Int] = []
    var quantize: Int = 8
    /// Lives in Settings → Models; ContentView pulls it at submit.
    var lowRam: Bool = false
    var loras: [LoraEntry] = []
    var board: String = ""

    var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty && (!isEditMode || !editImagePaths.isEmpty)
    }

    /// Restores the last-used form, else the Settings → Models defaults.
    func applyDefaults(settings: AppSettings, library: LoraLibraryStore) {
        let d = settings.resolvedDefaults(for: Self.model)
        let s = settings.lastQwen21 ?? Qwen21FormState()
        prompt = s.prompt ?? ""
        isEditMode = s.isEditMode ?? false
        editImagePaths = s.editImagePaths ?? []
        matchReferenceSize = s.matchReferenceSize ?? true
        width = s.width ?? d.width
        height = s.height ?? d.height
        steps = Self.model.clampedSteps(s.steps ?? d.steps)
        quantize = s.quantize ?? d.quantize
        board = s.board ?? settings.defaultBoard
        loras = (s.loras ?? []).isEmpty ? library.defaultLoras(for: .qwen21) : s.loras ?? []
        seed = -1
    }

    func snapshot() -> Qwen21FormState {
        Qwen21FormState(
            prompt: prompt, isEditMode: isEditMode, editImagePaths: editImagePaths,
            matchReferenceSize: matchReferenceSize, width: width, height: height,
            steps: steps, quantize: quantize, loras: loras, board: board
        )
    }

    /// Replays a finished image's settings. `newSeed` (Remix) goes back to a random seed.
    func apply(metadata meta: Qwen21Metadata, newSeed: Bool) {
        prompt = meta.prompt
        isEditMode = meta.isEditMode
        editImagePaths = meta.editImagePaths ?? []
        matchReferenceSize = meta.matchReferenceSize ?? true
        width = meta.width
        height = meta.height
        steps = meta.steps
        quantize = meta.quantize
        if let saved = meta.loras {
            loras = saved
        }
        board = meta.board ?? ""
        batchSeeds = []
        seed = newSeed ? -1 : meta.seed
    }

    /// Builds a job. `resolvedPrompt` is the fully resolved text of one wildcard
    /// variant; when nil, any wildcards collapse to a single sample. `size`
    /// overrides the panel's width and height for this job only.
    func makeJob(
        count: Int = 1,
        customModelRepo: String = "",
        resolvedPrompt: String? = nil,
        size: (width: Int, height: Int)? = nil
    ) -> Qwen21Job {
        let job = Qwen21Job(
            isEditMode: isEditMode,
            editImagePaths: isEditMode ? editImagePaths : [],
            matchReferenceSize: matchReferenceSize,
            prompt: resolvedPrompt ?? WildcardExpander.expandVariants(prompt, count: 1).first ?? prompt,
            customModelRepo: customModelRepo,
            steps: Self.model.clampedSteps(steps),
            quantize: quantize,
            width: size?.width ?? width,
            height: size?.height ?? height,
            seed: seed,
            loras: loras,
            lowRam: lowRam,
            board: board
        )
        if count > 1 {
            // One process, model loaded once, N random seeds.
            job.seeds = (0 ..< count).map { _ in Int(UInt32.random(in: 0 ..< UInt32.max)) }
        } else if !batchSeeds.isEmpty {
            job.seeds = batchSeeds
        }
        return job
    }
}
