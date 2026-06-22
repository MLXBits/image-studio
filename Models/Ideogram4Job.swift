import AppKit
import Foundation

/// A single Ideogram 4 generation request managed by ``Ideogram4JobStore``.
///
/// `Ideogram4Job` holds both the *input parameters* submitted by the user and the
/// *runtime state* updated while the job executes. All properties are observable;
/// views bind to them directly.
@Observable
final class Ideogram4Job: Identifiable {
    let id: UUID
    var preset: Ideogram4Preset
    var caption: IdeogramCaption
    var usePlainPrompt: Bool
    var plainPrompt: String
    var width: Int
    var height: Int
    var seed: Int
    var seeds: [Int]
    var quantize: Int
    var lowRam: Bool
    var strictValidation: Bool
    var loras: [LoraEntry]
    var board: String

    var status: JobStatus
    var log: String
    var outputPath: String?
    var outputPaths: [String] = []
    var outputThumbnails: [Data] = []
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

    var progressFraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStep) / Double(totalSteps)
    }

    var displayName: String {
        "\(preset.displayName) · \(width)×\(height)"
    }

    init(
        id: UUID = UUID(),
        preset: Ideogram4Preset = .normal,
        caption: IdeogramCaption = .empty(),
        usePlainPrompt: Bool = false,
        plainPrompt: String = "",
        width: Int = 1024,
        height: Int = 1024,
        seed: Int = -1,
        seeds: [Int] = [],
        quantize: Int = 0,
        lowRam: Bool = false,
        strictValidation: Bool = false,
        loras: [LoraEntry] = [],
        board: String = "Default",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.preset = preset
        self.caption = caption
        self.usePlainPrompt = usePlainPrompt
        self.plainPrompt = plainPrompt
        self.width = width
        self.height = height
        self.seed = seed
        self.seeds = seeds
        self.quantize = quantize
        self.lowRam = lowRam
        self.strictValidation = strictValidation
        self.loras = loras
        self.board = board
        self.status = .pending
        self.log = ""
        self.currentStep = 0
        self.totalSteps = preset.stepCount
        self.createdAt = createdAt
    }
}

extension Ideogram4Job: Codable {
    enum CodingKeys: String, CodingKey {
        case id, preset, caption, usePlainPrompt, plainPrompt
        case width, height, seed, seeds, quantize, lowRam, strictValidation, loras, board
        case status, log, outputPath, resolvedSeed, thumbnailData
        case currentStep, totalSteps, createdAt, startedAt, completedAt
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            preset: (try? c.decode(Ideogram4Preset.self, forKey: .preset)) ?? .normal,
            caption: (try? c.decode(IdeogramCaption.self, forKey: .caption)) ?? .empty(),
            usePlainPrompt: (try? c.decode(Bool.self, forKey: .usePlainPrompt)) ?? false,
            plainPrompt: (try? c.decode(String.self, forKey: .plainPrompt)) ?? "",
            width: (try? c.decode(Int.self, forKey: .width)) ?? 1024,
            height: (try? c.decode(Int.self, forKey: .height)) ?? 1024,
            seed: (try? c.decode(Int.self, forKey: .seed)) ?? -1,
            seeds: (try? c.decode([Int].self, forKey: .seeds)) ?? [],
            quantize: (try? c.decode(Int.self, forKey: .quantize)) ?? 0,
            lowRam: (try? c.decode(Bool.self, forKey: .lowRam)) ?? false,
            strictValidation: (try? c.decode(Bool.self, forKey: .strictValidation)) ?? false,
            loras: (try? c.decode([LoraEntry].self, forKey: .loras)) ?? [],
            board: (try? c.decode(String.self, forKey: .board)) ?? "Default",
            createdAt: (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        )
        status = (try? c.decode(JobStatus.self, forKey: .status)) ?? .pending
        log = (try? c.decode(String.self, forKey: .log)) ?? ""
        outputPath = try? c.decode(String.self, forKey: .outputPath)
        resolvedSeed = try? c.decode(Int.self, forKey: .resolvedSeed)
        thumbnailData = try? c.decode(Data.self, forKey: .thumbnailData)
        currentStep = (try? c.decode(Int.self, forKey: .currentStep)) ?? 0
        totalSteps = (try? c.decode(Int.self, forKey: .totalSteps)) ?? preset.stepCount
        startedAt = try? c.decode(Date.self, forKey: .startedAt)
        completedAt = try? c.decode(Date.self, forKey: .completedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(preset, forKey: .preset)
        try c.encode(caption, forKey: .caption)
        try c.encode(usePlainPrompt, forKey: .usePlainPrompt)
        try c.encode(plainPrompt, forKey: .plainPrompt)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(seed, forKey: .seed)
        try c.encode(seeds, forKey: .seeds)
        try c.encode(quantize, forKey: .quantize)
        try c.encode(lowRam, forKey: .lowRam)
        try c.encode(strictValidation, forKey: .strictValidation)
        try c.encode(loras, forKey: .loras)
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
