import AppKit
import Foundation

/// A single Qwen-Image 2.1 generation request managed by ``QwenImageJobStore``.
///
/// `QwenImageJob` holds both the *input parameters* submitted by the user and the
/// *runtime state* updated while the job executes. All properties are observable;
/// views bind to them directly. Jobs are persisted by ``QwenImageJobStore`` and
/// survive app restarts.
///
/// Qwen-Image 2.1 is a single-stream, block-causal 7.1B DiT with a Qwen3-VL text
/// encoder, sampled guidance-free by default (guidance 1.0). A negative prompt only
/// takes effect with guidance above 1, which switches mflux to true classifier-free
/// guidance. `imagePath` empty = pure text-to-image. mflux has no LoRA support for
/// this model, so there is no LoRA stack.
@Observable
final class QwenImageJob: Identifiable {
    let id: UUID
    /// Repo ID or local path chosen via the picker's `Custom…` entry, loaded
    /// through the Qwen-Image 2.1 pipeline. Empty = the official checkpoint.
    var customModelRepo: String
    var prompt: String
    var negativePrompt: String
    var width: Int
    var height: Int
    /// Requested seed. Use `-1` to let the runner pick a random seed at execution time.
    var seed: Int
    /// Multiple seeds for batch generation. Empty array = single-seed run.
    var seeds: [Int]
    var steps: Int
    var guidance: Double
    /// 0 = BF16. 8/4 quantize the DiT in memory at load; the text encoder stays BF16.
    var quantize: Int
    /// Optional init image for img2img. Empty string = pure text-to-image.
    var imagePath: String
    /// How strongly the init image influences the output (0.05–0.95). Only used when `imagePath` is set.
    var imageStrength: Double
    /// Output subfolder within the global output directory. Empty string = root.
    var board: String

    var status: JobStatus
    /// Raw stdout/stderr from the generation process. Appended in real time during a run.
    var log: String
    /// Absolute path to the finished image file. Set when the run succeeds.
    var outputPath: String?
    var outputPaths: [String] = [] // transient: multi-seed outputs, not persisted
    var outputThumbnails: [Data] = [] // transient: thumbnails for fan-out, not persisted
    var completedSeedsInBatch: Int = 0 // transient: incremented as each seed's image lands
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

    /// The catalog entry every Qwen-Image job runs as.
    var modelVariant: FluxModelVariant {
        .qwenImage21
    }

    /// Whether this run uses true classifier-free guidance: a negative prompt only
    /// matters once guidance is above 1.
    var usesTrueCFG: Bool {
        guidance > 1.0
    }

    var progressFraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStep) / Double(totalSteps)
    }

    var displayName: String {
        let name = customModelRepo.isEmpty
            ? modelVariant.displayName
            : customModelRepo.split(separator: "/").last.map(String.init) ?? "custom"
        return "\(name) · \(width)×\(height) · \(steps) steps"
    }

    init(
        id: UUID = UUID(),
        customModelRepo: String = "",
        prompt: String = "",
        negativePrompt: String = "",
        width: Int = 1024,
        height: Int = 1024,
        seed: Int = -1,
        seeds: [Int] = [],
        steps: Int = 40,
        guidance: Double = 1.0,
        quantize: Int = 0,
        imagePath: String = "",
        imageStrength: Double = 0.75,
        board: String = "Default",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.customModelRepo = customModelRepo
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.seed = seed
        self.seeds = seeds
        self.steps = steps
        self.guidance = guidance
        self.quantize = quantize
        self.imagePath = imagePath
        self.imageStrength = imageStrength
        self.board = board
        status = .pending
        log = ""
        currentStep = 0
        totalSteps = steps
        self.createdAt = createdAt
    }
}

extension QwenImageJob: Codable {
    enum CodingKeys: String, CodingKey {
        case id, customModelRepo, prompt, negativePrompt
        case width, height, seed, seeds, steps, guidance, quantize, imagePath, imageStrength, board
        case status, log, outputPath, resolvedSeed, thumbnailData
        case currentStep, totalSteps, createdAt, startedAt, completedAt
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            customModelRepo: (try? c.decode(String.self, forKey: .customModelRepo)) ?? "",
            prompt: (try? c.decode(String.self, forKey: .prompt)) ?? "",
            negativePrompt: (try? c.decode(String.self, forKey: .negativePrompt)) ?? "",
            width: (try? c.decode(Int.self, forKey: .width)) ?? 1024,
            height: (try? c.decode(Int.self, forKey: .height)) ?? 1024,
            seed: (try? c.decode(Int.self, forKey: .seed)) ?? -1,
            seeds: (try? c.decode([Int].self, forKey: .seeds)) ?? [],
            steps: (try? c.decode(Int.self, forKey: .steps)) ?? 40,
            guidance: (try? c.decode(Double.self, forKey: .guidance)) ?? 1.0,
            quantize: (try? c.decode(Int.self, forKey: .quantize)) ?? 0,
            imagePath: (try? c.decode(String.self, forKey: .imagePath)) ?? "",
            imageStrength: (try? c.decode(Double.self, forKey: .imageStrength)) ?? 0.75,
            board: (try? c.decode(String.self, forKey: .board)) ?? "Default",
            createdAt: (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        )
        status = (try? c.decode(JobStatus.self, forKey: .status)) ?? .pending
        log = (try? c.decode(String.self, forKey: .log)) ?? ""
        outputPath = try? c.decode(String.self, forKey: .outputPath)
        resolvedSeed = try? c.decode(Int.self, forKey: .resolvedSeed)
        thumbnailData = try? c.decode(Data.self, forKey: .thumbnailData)
        currentStep = (try? c.decode(Int.self, forKey: .currentStep)) ?? 0
        totalSteps = (try? c.decode(Int.self, forKey: .totalSteps)) ?? steps
        startedAt = try? c.decode(Date.self, forKey: .startedAt)
        completedAt = try? c.decode(Date.self, forKey: .completedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(customModelRepo, forKey: .customModelRepo)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(negativePrompt, forKey: .negativePrompt)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(seed, forKey: .seed)
        try c.encode(seeds, forKey: .seeds)
        try c.encode(steps, forKey: .steps)
        try c.encode(guidance, forKey: .guidance)
        try c.encode(quantize, forKey: .quantize)
        try c.encode(imagePath, forKey: .imagePath)
        try c.encode(imageStrength, forKey: .imageStrength)
        try c.encode(board, forKey: .board)
        try c.encode(status, forKey: .status)
        try c.encode(log, forKey: .log)
        try c.encode(currentStep, forKey: .currentStep)
        try c.encode(totalSteps, forKey: .totalSteps)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(outputPath, forKey: .outputPath)
        try c.encodeIfPresent(resolvedSeed, forKey: .resolvedSeed)
        try c.encodeIfPresent(thumbnailData, forKey: .thumbnailData)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}
