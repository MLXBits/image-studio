import AppKit
import Foundation

enum JobStatus: Equatable {
    case pending
    case running
    case completed
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .pending:      return "Pending"
        case .running:      return "Running"
        case .completed:    return "Completed"
        case .failed(let m): return "Failed: \(m)"
        case .cancelled:    return "Cancelled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

extension JobStatus: Codable {
    enum CodingKey: String, Swift.CodingKey { case type, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "pending":   self = .pending
        case "running":   self = .running
        case "completed": self = .completed
        case "cancelled": self = .cancelled

        default:
            let msg = (try? c.decode(String.self, forKey: .message)) ?? type
            self = .failed(msg)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKey.self)
        switch self {
        case .pending:       try c.encode("pending", forKey: .type)
        case .running:       try c.encode("running", forKey: .type)
        case .completed:     try c.encode("completed", forKey: .type)
        case .cancelled:     try c.encode("cancelled", forKey: .type)
        case .failed(let m): try c.encode("failed", forKey: .type); try c.encode(m, forKey: .message)
        }
    }
}

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
    var seed: Int
    var steps: Int
    var guidance: Double
    var loras: [LoraEntry]
    var quantize: Int
    var lowRam: Bool
    var imagePath: String
    var imageStrength: Double
    var isEditMode: Bool
    var editImagePaths: [String]
    var board: String

    var seeds: [Int]

    var status: JobStatus
    var log: String
    var outputPath: String?
    var outputPaths: [String] = []          // transient — multi-seed outputs, not persisted
    var outputThumbnails: [Data] = []       // transient — thumbnails for fan-out, not persisted
    var completedSeedsInBatch: Int = 0      // transient — incremented as each seed's image lands
    var resolvedSeed: Int?
    var thumbnailData: Data?
    var currentStep: Int
    var totalSteps: Int
    var latestStepwisePath: String?
    var statusLine: String = ""     // transient: live CLI status for display during load/download
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
        createdAt: Date = Date()
    ) {
        self.id              = id
        self.model           = model
        self.customModelRepo = customModelRepo
        self.customBaseModel = customBaseModel
        self.prompt          = prompt
        self.negativePrompt  = negativePrompt
        self.width           = width
        self.height          = height
        self.seed            = seed
        self.seeds           = seeds
        self.steps           = steps
        self.guidance        = guidance
        self.loras           = loras
        self.quantize        = quantize
        self.lowRam          = lowRam
        self.imagePath       = imagePath
        self.imageStrength   = imageStrength
        self.isEditMode      = isEditMode
        self.editImagePaths  = editImagePaths
        self.board           = board
        self.status          = .pending
        self.log             = ""
        self.currentStep     = 0
        self.totalSteps      = steps
        self.createdAt       = createdAt
    }
}

extension FluxJob: Codable {
    enum CodingKeys: String, CodingKey {
        case id, model, customModelRepo, customBaseModel, prompt, negativePrompt
        case width, height, seed, seeds, steps, guidance, loras, quantize, lowRam
        case imagePath, imageStrength, isEditMode, editImagePaths, board
        case status, log, outputPath, resolvedSeed, thumbnailData
        case currentStep, totalSteps, createdAt, startedAt, completedAt
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            model: (try? c.decode(FluxModelVariant.self, forKey: .model)) ?? .flux2Klein9B,
            customModelRepo: (try? c.decode(String.self, forKey: .customModelRepo)) ?? "",
            customBaseModel: (try? c.decode(FluxModelVariant.self, forKey: .customBaseModel)) ?? .flux2Klein9B,
            prompt: (try? c.decode(String.self, forKey: .prompt)) ?? "",
            negativePrompt: (try? c.decode(String.self, forKey: .negativePrompt)) ?? "",
            width: (try? c.decode(Int.self, forKey: .width)) ?? 1024,
            height: (try? c.decode(Int.self, forKey: .height)) ?? 1024,
            seed: (try? c.decode(Int.self, forKey: .seed)) ?? -1,
            seeds: (try? c.decode([Int].self, forKey: .seeds)) ?? [],
            steps: (try? c.decode(Int.self, forKey: .steps)) ?? 4,
            guidance: (try? c.decode(Double.self, forKey: .guidance)) ?? 1.0,
            loras: (try? c.decode([LoraEntry].self, forKey: .loras)) ?? [],
            quantize: (try? c.decode(Int.self, forKey: .quantize)) ?? 8,
            lowRam: (try? c.decode(Bool.self, forKey: .lowRam)) ?? false,
            imagePath: (try? c.decode(String.self, forKey: .imagePath)) ?? "",
            imageStrength: (try? c.decode(Double.self, forKey: .imageStrength)) ?? 0.75,
            isEditMode: (try? c.decode(Bool.self, forKey: .isEditMode)) ?? false,
            editImagePaths: (try? c.decode([String].self, forKey: .editImagePaths)) ?? [],
            board: (try? c.decode(String.self, forKey: .board)) ?? "Default",
            createdAt: (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        )
        status       = (try? c.decode(JobStatus.self, forKey: .status)) ?? .pending
        log          = (try? c.decode(String.self, forKey: .log)) ?? ""
        outputPath   = try? c.decode(String.self, forKey: .outputPath)
        resolvedSeed = try? c.decode(Int.self, forKey: .resolvedSeed)
        thumbnailData = try? c.decode(Data.self, forKey: .thumbnailData)
        currentStep  = (try? c.decode(Int.self, forKey: .currentStep)) ?? 0
        totalSteps   = (try? c.decode(Int.self, forKey: .totalSteps)) ?? steps
        startedAt    = try? c.decode(Date.self, forKey: .startedAt)
        completedAt  = try? c.decode(Date.self, forKey: .completedAt)
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
