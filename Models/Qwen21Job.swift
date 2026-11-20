import Foundation

/// A single Qwen-Image 2.1 Turbo request managed by ``Qwen21JobStore``.
///
/// Two modes run through one CLI (`mflux-generate-qwen-2.1-edit`): Generate is
/// text-to-image; Edit conditions on an ordered list of up to ten reference
/// images (the prompt refers to them as "image 1", "image 2"). There is no
/// img2img: an edit starts from noise, and the references steer it. Turbo is
/// guidance-free, so the job carries no guidance or negative prompt.
@Observable
final class Qwen21Job: Identifiable {
    /// Most reference images the model accepts in one edit.
    static let maxReferences = 10

    let id: UUID
    var isEditMode: Bool
    /// Edit references, in prompt order. Ignored in Generate mode.
    var editImagePaths: [String]
    /// Edit mode only: leave the size to mflux, which takes the last
    /// reference's aspect ratio at about 1 MP. `width`/`height` then only
    /// describe the form's size, not the output.
    var matchReferenceSize: Bool
    var prompt: String
    /// Repo ID or local path chosen via the picker's `Custom…` entry, loaded as
    /// Qwen-Image 2.1 Turbo. Empty = the published mflux-community repo.
    var customModelRepo: String
    var steps: Int
    /// 0 = BF16, 8, or 4. Each level is its own published repo; nothing is
    /// quantized on the fly.
    var quantize: Int
    var width: Int
    var height: Int
    /// Requested seed. Use `-1` to let the runner pick a random seed at execution time.
    var seed: Int
    /// Multiple seeds for batch generation. Empty array = single-seed run.
    var seeds: [Int]
    var loras: [LoraEntry]
    /// Stream transformer blocks from disk (`--low-ram`) to cut peak memory.
    var lowRam: Bool
    /// Output subfolder within the global output directory. Empty string = root.
    var board: String
    /// Rewrite the prompt before encoding: ComfyUI's template enhancer, or locally (edits only) mflux's Qwen3-VL.
    var enhancePrompt: Bool

    var status: JobStatus
    var log: String
    var outputPath: String?
    var outputPaths: [String] = [] // transient
    var outputThumbnails: [Data] = [] // transient
    var completedSeedsInBatch: Int = 0 // transient
    var resolvedSeed: Int?
    var thumbnailData: Data?
    var currentStep: Int
    var totalSteps: Int
    var latestStepwisePath: String?
    var statusLine: String = "" // transient
    var stepTiming: String? // transient
    var isDenoising: Bool = false // transient
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    /// The edit runs at the references' size rather than `width`×`height`.
    var followsReferenceSize: Bool {
        isEditMode && matchReferenceSize && !editImagePaths.isEmpty
    }

    var displayName: String {
        let name = customModelRepo.isEmpty
            ? FluxModelVariant.qwen21Turbo.displayName
            : customModelRepo.split(separator: "/").last.map(String.init) ?? "custom"
        let size = followsReferenceSize ? "reference size" : "\(width)×\(height)"
        let mode = isEditMode ? " · edit \(editImagePaths.count) ref" : ""
        return "\(name)\(mode) · \(size) · \(steps) steps"
    }

    init(
        id: UUID = UUID(),
        isEditMode: Bool = false,
        editImagePaths: [String] = [],
        matchReferenceSize: Bool = true,
        prompt: String = "",
        customModelRepo: String = "",
        steps: Int = 8,
        quantize: Int = 8,
        width: Int = 1024,
        height: Int = 1024,
        seed: Int = -1,
        seeds: [Int] = [],
        loras: [LoraEntry] = [],
        lowRam: Bool = false,
        board: String = "Default",
        enhancePrompt: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.isEditMode = isEditMode
        self.editImagePaths = editImagePaths
        self.matchReferenceSize = matchReferenceSize
        self.prompt = prompt
        self.customModelRepo = customModelRepo
        self.steps = steps
        self.quantize = quantize
        self.width = width
        self.height = height
        self.seed = seed
        self.seeds = seeds
        self.loras = loras
        self.lowRam = lowRam
        self.board = board
        self.enhancePrompt = enhancePrompt
        status = .pending
        log = ""
        currentStep = 0
        totalSteps = steps
        self.createdAt = createdAt
    }

    /// A fresh pending job with a new id, running only `seed`, and every
    /// user-settable field of this one. Used to split a multi-seed batch.
    func copy(seed: Int) -> Qwen21Job {
        Qwen21Job(
            isEditMode: isEditMode,
            editImagePaths: editImagePaths,
            matchReferenceSize: matchReferenceSize,
            prompt: prompt,
            customModelRepo: customModelRepo,
            steps: steps,
            quantize: quantize,
            width: width,
            height: height,
            seed: seed,
            loras: loras,
            lowRam: lowRam,
            board: board,
            enhancePrompt: enhancePrompt,
            createdAt: createdAt
        )
    }
}

extension Qwen21Job: @MainActor SeedSplittableJob {}

extension Qwen21Job: Codable {
    enum CodingKeys: String, CodingKey {
        case id, isEditMode, editImagePaths, matchReferenceSize, prompt, customModelRepo
        case steps, quantize, width, height, seed, seeds, loras, lowRam, board, enhancePrompt
        case createdAt
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Qwen21Job()
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            isEditMode: c.lenient(.isEditMode) ?? false,
            editImagePaths: c.lenient(.editImagePaths) ?? [],
            matchReferenceSize: c.lenient(.matchReferenceSize) ?? true,
            prompt: c.lenient(.prompt) ?? "",
            customModelRepo: c.lenient(.customModelRepo) ?? "",
            steps: c.lenient(.steps) ?? defaults.steps,
            quantize: c.lenient(.quantize) ?? defaults.quantize,
            width: c.lenient(.width) ?? defaults.width,
            height: c.lenient(.height) ?? defaults.height,
            seed: c.lenient(.seed) ?? -1,
            seeds: c.lenient(.seeds) ?? [],
            loras: c.lenient(.loras) ?? [],
            lowRam: c.lenient(.lowRam) ?? false,
            board: c.lenient(.board) ?? "Default",
            enhancePrompt: c.lenient(.enhancePrompt) ?? false,
            createdAt: c.lenient(.createdAt) ?? Date()
        )
        try decodeRunState(from: decoder, defaultTotalSteps: steps)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(isEditMode, forKey: .isEditMode)
        try c.encode(editImagePaths, forKey: .editImagePaths)
        try c.encode(matchReferenceSize, forKey: .matchReferenceSize)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(customModelRepo, forKey: .customModelRepo)
        try c.encode(steps, forKey: .steps)
        try c.encode(quantize, forKey: .quantize)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(seed, forKey: .seed)
        try c.encode(seeds, forKey: .seeds)
        try c.encode(loras, forKey: .loras)
        try c.encode(lowRam, forKey: .lowRam)
        try c.encode(board, forKey: .board)
        try c.encode(enhancePrompt, forKey: .enhancePrompt)
        try c.encode(createdAt, forKey: .createdAt)
        try encodeRunState(to: encoder)
    }
}
