import AppKit
import Foundation

/// A single SeedVR2 upscale request managed by ``SeedVR2JobStore``.
///
/// SeedVR2 is a diffusion super-resolution model applied to an *existing* image
/// (a just-generated result or a browsed gallery item) — it has no prompt and no
/// model-picker slot. `SeedVR2Job` holds the upscale inputs submitted from the
/// Upscale sheet plus the runtime state the shared ``JobRunner`` engine updates
/// while the CLI runs. Single-output only (`seeds` is always empty).
///
/// `width`/`height` carry the *output* dimensions (source × ``scale``) so the
/// preview, metadata sidecar, and learned-timing model all read sensibly.
@Observable
final class SeedVR2Job: Identifiable {
    let id: UUID
    /// Absolute path to the source image being upscaled.
    var sourcePath: String
    /// Integer scale factor (2, 3, 4) — passed to the CLI as `--resolution Nx`.
    var scale: Int
    /// Detail-restoration strength, 0.0 (off) … 1.0 (max). CLI `--softness`.
    var softness: Double
    /// false = seedvr2-3b (fast, default), true = seedvr2-7b (quality).
    var is7B: Bool
    var quantize: Int
    /// Requested seed. `-1` lets the runner pick a random seed at execution time.
    var seed: Int
    /// Output subfolder within the global output directory (the source's board).
    var board: String

    /// Output dimensions (source dims × ``scale``). Populated at job creation.
    var width: Int
    var height: Int

    var status: JobStatus
    var log: String
    var outputPath: String?
    var outputPaths: [String] = [] // unused (single-output) — GeneratedJob conformance
    var outputThumbnails: [Data] = [] // unused (single-output)
    var completedSeedsInBatch: Int = 0
    var resolvedSeed: Int?
    var thumbnailData: Data?
    var currentStep: Int
    var totalSteps: Int
    var latestStepwisePath: String?
    var statusLine: String = ""
    var stepTiming: String?
    var isDenoising: Bool = false
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    /// Single-output upscale: never a multi-seed batch.
    var seeds: [Int] {
        []
    }

    var progressFraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStep) / Double(totalSteps)
    }

    var modelLabel: String {
        is7B ? "SeedVR2 7B" : "SeedVR2 3B"
    }

    var displayName: String {
        "\(modelLabel) · \(scale)× · softness \(String(format: "%.2f", softness))"
    }

    init(
        id: UUID = UUID(),
        sourcePath: String,
        scale: Int = 2,
        softness: Double = 0.0,
        is7B: Bool = false,
        quantize: Int = 8,
        seed: Int = -1,
        board: String = "Default",
        width: Int = 0,
        height: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.scale = scale
        self.softness = softness
        self.is7B = is7B
        self.quantize = quantize
        self.seed = seed
        self.board = board
        self.width = width
        self.height = height
        status = .pending
        log = ""
        currentStep = 0
        totalSteps = 0
        self.createdAt = createdAt
    }
}

extension SeedVR2Job: Codable {
    enum CodingKeys: String, CodingKey {
        case id, sourcePath, scale, softness, is7B, quantize, seed, board, width, height
        case status, log, outputPath, resolvedSeed, thumbnailData
        case currentStep, totalSteps, createdAt, startedAt, completedAt
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            sourcePath: (try? c.decode(String.self, forKey: .sourcePath)) ?? "",
            scale: (try? c.decode(Int.self, forKey: .scale)) ?? 2,
            softness: (try? c.decode(Double.self, forKey: .softness)) ?? 0.0,
            is7B: (try? c.decode(Bool.self, forKey: .is7B)) ?? false,
            quantize: (try? c.decode(Int.self, forKey: .quantize)) ?? 8,
            seed: (try? c.decode(Int.self, forKey: .seed)) ?? -1,
            board: (try? c.decode(String.self, forKey: .board)) ?? "Default",
            width: (try? c.decode(Int.self, forKey: .width)) ?? 0,
            height: (try? c.decode(Int.self, forKey: .height)) ?? 0,
            createdAt: (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        )
        status = (try? c.decode(JobStatus.self, forKey: .status)) ?? .pending
        log = (try? c.decode(String.self, forKey: .log)) ?? ""
        outputPath = try? c.decode(String.self, forKey: .outputPath)
        resolvedSeed = try? c.decode(Int.self, forKey: .resolvedSeed)
        thumbnailData = try? c.decode(Data.self, forKey: .thumbnailData)
        currentStep = (try? c.decode(Int.self, forKey: .currentStep)) ?? 0
        totalSteps = (try? c.decode(Int.self, forKey: .totalSteps)) ?? 0
        startedAt = try? c.decode(Date.self, forKey: .startedAt)
        completedAt = try? c.decode(Date.self, forKey: .completedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourcePath, forKey: .sourcePath)
        try c.encode(scale, forKey: .scale)
        try c.encode(softness, forKey: .softness)
        try c.encode(is7B, forKey: .is7B)
        try c.encode(quantize, forKey: .quantize)
        try c.encode(seed, forKey: .seed)
        try c.encode(board, forKey: .board)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
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
