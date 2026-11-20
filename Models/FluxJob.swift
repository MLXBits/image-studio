import AppKit
import Foundation

/// A single image generation request managed by ``JobStore``.
///
/// `FluxJob` holds both the *input parameters* submitted by the user and the
/// *runtime state* updated while the job executes. All properties are observable;
/// views bind to them directly.
///
/// Jobs are persisted to disk via ``JobStore/save()`` and survive app restarts.
@Observable
final class FluxJob: Identifiable {
    let id: UUID
    var model: FluxModelVariant
    var customModelRepo: String
    var customBaseModel: FluxModelVariant
    var prompt: String
    var negativePrompt: String
    var width: Int
    var height: Int
    /// Requested seed. Use `-1` to let the runner pick a random seed at execution time.
    var seed: Int
    var steps: Int
    var guidance: Double
    var loras: [LoraEntry]
    var quantize: Int
    /// When `true`, transformer blocks are streamed from disk to keep peak Metal memory low.
    var lowRam: Bool
    /// Absolute path to the conditioning image, or empty string for text-to-image.
    var imagePath: String
    var imageStrength: Double
    var isEditMode: Bool
    var editImagePaths: [String]
    /// Output subfolder within the global output directory. Empty string = root.
    var board: String
    /// Decode with PiD's pixel-diffusion decoder instead of the VAE, emitting an
    /// image 4x the generation size. Only offered when the installed mflux has it
    /// (see ``MfluxProbes/supportsPidDecode(python:)``).
    var pidDecode: Bool
    /// Noise added to the latent before PiD conditions on it (0.0-0.8). Higher values
    /// make PiD lean less on the latent's high-frequency content and more on its own
    /// prior — the knob for when PiD over-textures. Ignored unless `pidDecode`.
    var pidDegradeSigma: Double
    /// Multiple seeds for batch generation. Empty array = single-seed run.
    var seeds: [Int]

    var status: JobStatus
    /// Raw stdout/stderr from the generation process. Appended in real time during a run.
    var log: String
    /// Absolute path to the finished image file. Set when the run succeeds.
    var outputPath: String?
    var outputPaths: [String] = [] // transient — multi-seed outputs, not persisted
    var outputThumbnails: [Data] = [] // transient — thumbnails for fan-out, not persisted
    var completedSeedsInBatch: Int = 0 // transient — incremented as each seed's image lands
    /// The seed that was actually used. Differs from ``seed`` when ``seed`` is `-1`.
    var resolvedSeed: Int?
    /// JPEG thumbnail cached in memory and persisted with the job.
    var thumbnailData: Data?
    var currentStep: Int
    var totalSteps: Int
    var latestStepwisePath: String?
    var statusLine: String = "" // transient: live CLI status for display during load/download
    var stepTiming: String? // transient: "1:23 elapsed · 0:05 left" from tqdm
    var isDenoising: Bool = false // transient: true once the denoising loop emits its first 0/N line
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    var progressFraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStep) / Double(totalSteps)
    }

    var displayName: String {
        let w = "\(width)×\(height)"
        let m = model == .custom ? customModelRepo.split(separator: "/").last.map(String.init) ?? "custom" : model.displayName
        return "\(m) · \(w) · \(steps) steps"
    }

    init(
        id: UUID = UUID(),
        model: FluxModelVariant = .flux2Klein9B,
        customModelRepo: String = "",
        customBaseModel: FluxModelVariant = .flux2Klein9B,
        prompt: String = "",
        negativePrompt: String = "",
        width: Int = 1024,
        height: Int = 1024,
        seed: Int = -1,
        seeds: [Int] = [],
        steps: Int = 4,
        guidance: Double = 1.0,
        loras: [LoraEntry] = [],
        quantize: Int = 8,
        lowRam: Bool = false,
        imagePath: String = "",
        imageStrength: Double = 0.75,
        isEditMode: Bool = false,
        editImagePaths: [String] = [],
        board: String = "Default",
        pidDecode: Bool = false,
        pidDegradeSigma: Double = 0.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.model = model
        self.customModelRepo = customModelRepo
        self.customBaseModel = customBaseModel
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.seed = seed
        self.seeds = seeds
        self.steps = steps
        self.guidance = guidance
        self.loras = loras
        self.quantize = quantize
        self.lowRam = lowRam
        self.imagePath = imagePath
        self.imageStrength = imageStrength
        self.isEditMode = isEditMode
        self.editImagePaths = editImagePaths
        self.board = board
        self.pidDecode = pidDecode
        self.pidDegradeSigma = pidDegradeSigma
        self.status = .pending
        self.log = ""
        self.currentStep = 0
        self.totalSteps = steps
        self.createdAt = createdAt
    }

    /// A fresh pending job with a new id, running only `seed`, and every
    /// user-settable field of this one. Used to split a multi-seed batch.
    func copy(seed: Int) -> FluxJob {
        FluxJob(
            model: model,
            customModelRepo: customModelRepo,
            customBaseModel: customBaseModel,
            prompt: prompt,
            negativePrompt: negativePrompt,
            width: width,
            height: height,
            seed: seed,
            steps: steps,
            guidance: guidance,
            loras: loras,
            quantize: quantize,
            lowRam: lowRam,
            imagePath: imagePath,
            imageStrength: imageStrength,
            isEditMode: isEditMode,
            editImagePaths: editImagePaths,
            board: board,
            pidDecode: pidDecode,
            pidDegradeSigma: pidDegradeSigma,
            createdAt: createdAt
        )
    }
}

extension FluxJob: @MainActor SeedSplittableJob {}

extension FluxJob: Codable {
    enum CodingKeys: String, CodingKey {
        case id, model, customModelRepo, customBaseModel, prompt, negativePrompt
        case width, height, seed, seeds, steps, guidance, loras, quantize, lowRam
        case imagePath, imageStrength, isEditMode, editImagePaths, board
        case pidDecode, pidDegradeSigma
        case createdAt
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            model: c.lenient(.model) ?? .flux2Klein9B,
            customModelRepo: c.lenient(.customModelRepo) ?? "",
            customBaseModel: c.lenient(.customBaseModel) ?? .flux2Klein9B,
            prompt: c.lenient(.prompt) ?? "",
            negativePrompt: c.lenient(.negativePrompt) ?? "",
            width: c.lenient(.width) ?? 1024,
            height: c.lenient(.height) ?? 1024,
            seed: c.lenient(.seed) ?? -1,
            seeds: c.lenient(.seeds) ?? [],
            steps: c.lenient(.steps) ?? 4,
            guidance: c.lenient(.guidance) ?? 1.0,
            loras: c.lenient(.loras) ?? [],
            quantize: c.lenient(.quantize) ?? 8,
            lowRam: c.lenient(.lowRam) ?? false,
            imagePath: c.lenient(.imagePath) ?? "",
            imageStrength: c.lenient(.imageStrength) ?? 0.75,
            isEditMode: c.lenient(.isEditMode) ?? false,
            editImagePaths: c.lenient(.editImagePaths) ?? [],
            board: c.lenient(.board) ?? "Default",
            pidDecode: c.lenient(.pidDecode) ?? false,
            pidDegradeSigma: c.lenient(.pidDegradeSigma) ?? 0.0,
            createdAt: c.lenient(.createdAt) ?? Date()
        )
        try decodeRunState(from: decoder, defaultTotalSteps: steps)
        // latestStepwisePath is not persisted — it's transient
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(model, forKey: .model)
        try c.encode(customModelRepo, forKey: .customModelRepo)
        try c.encode(customBaseModel, forKey: .customBaseModel)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(negativePrompt, forKey: .negativePrompt)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(seed, forKey: .seed)
        try c.encode(seeds, forKey: .seeds)
        try c.encode(steps, forKey: .steps)
        try c.encode(guidance, forKey: .guidance)
        try c.encode(loras, forKey: .loras)
        try c.encode(quantize, forKey: .quantize)
        try c.encode(lowRam, forKey: .lowRam)
        try c.encode(imagePath, forKey: .imagePath)
        try c.encode(imageStrength, forKey: .imageStrength)
        try c.encode(isEditMode, forKey: .isEditMode)
        try c.encode(editImagePaths, forKey: .editImagePaths)
        try c.encode(board, forKey: .board)
        try c.encode(pidDecode, forKey: .pidDecode)
        try c.encode(pidDegradeSigma, forKey: .pidDegradeSigma)
        try c.encode(createdAt, forKey: .createdAt)
        try encodeRunState(to: encoder)
    }
}
