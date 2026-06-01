import Foundation

struct LoraEntry: Identifiable, Equatable {
    var id: UUID
    var path: String
    var strength: Double
    var enabled: Bool
    var notes: String

    init(id: UUID = UUID(), path: String = "", strength: Double = 1.0, enabled: Bool = true, notes: String = "") {
        self.id = id
        self.path = path
        self.strength = strength
        self.enabled = enabled
        self.notes = notes
    }

    var displayName: String {
        path.hasPrefix("/")
            ? (URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent)
            : path
    }
}

extension LoraEntry: Codable {
    private enum CodingKeys: String, CodingKey { case id, path, strength, enabled, notes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id       = try container.decode(UUID.self, forKey: .id)
        path     = try container.decode(String.self, forKey: .path)
        strength = try container.decode(Double.self, forKey: .strength)
        enabled  = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notes    = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(strength, forKey: .strength)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(notes, forKey: .notes)
    }
}

struct AdditionalImageEntry: Identifiable, Equatable {
    var id: UUID
    var path: String
    var frameIdx: Int
    var strength: Double

    init(id: UUID = UUID(), path: String = "", frameIdx: Int = 0, strength: Double = 1.0) {
        self.id = id
        self.path = path
        self.frameIdx = frameIdx
        self.strength = strength
    }
}

extension AdditionalImageEntry: Codable {
    private enum CodingKeys: String, CodingKey { case id, path, frameIdx, strength }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self, forKey: .id)
        path     = try c.decode(String.self, forKey: .path)
        frameIdx = try c.decode(Int.self, forKey: .frameIdx)
        strength = try c.decode(Double.self, forKey: .strength)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(frameIdx, forKey: .frameIdx)
        try c.encode(strength, forKey: .strength)
    }
}

struct ModelEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String = ""

    var displayName: String {
        path.hasPrefix("/") ? (URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent) : path
    }
}

@Observable
final class VideoJob: Identifiable, Job {
    let id: UUID
    var name: String
    var prompt: String
    var imagePath: String
    var width: Int
    var height: Int
    var durationSeconds: Double
    var frameRate: Int
    var seed: Int
    var mode: GenerationMode
    var lowRam: Bool
    var imageStrength: Double
    var enableTeacache: Bool
    var teacacheThresh: Double
    var loras: [LoraEntry]
    var additionalImages: [AdditionalImageEntry]
    var modelPath: String
    var steps: Int
    var stage1Steps: Int
    var stage2Steps: Int
    var folder: String

    var status: JobStatus
    var log: String
    var outputPath: String?
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var resolvedSeed: Int?
    var thumbnailData: Data?

    let jobKind: JobKind = .video

    var frames: Int {
        let raw = Int(durationSeconds * Double(frameRate))
        return (raw / 8) * 8 + 1
    }

    var progressSummary: String? { parseJobProgressSummary(log: log, status: status) }

    init(
        id: UUID = UUID(),
        name: String = "",
        prompt: String = "",
        imagePath: String = "",
        width: Int = 768,
        height: Int = 512,
        durationSeconds: Double = 5.0,
        frameRate: Int = 25,
        seed: Int = -1,
        mode: GenerationMode = .distilled,
        lowRam: Bool = true,
        imageStrength: Double = 0.95,
        enableTeacache: Bool = false,
        teacacheThresh: Double = 0.5,
        loras: [LoraEntry] = [],
        additionalImages: [AdditionalImageEntry] = [],
        modelPath: String = "",
        steps: Int = 8,
        stage1Steps: Int = 30,
        stage2Steps: Int = 3,
        folder: String = "",
        createdAt: Date = Date()
    ) {
        self.id              = id
        self.name            = name.isEmpty ? "New Job" : name
        self.prompt          = prompt
        self.imagePath       = imagePath
        self.width           = width
        self.height          = height
        self.durationSeconds = durationSeconds
        self.frameRate       = frameRate
        self.seed            = seed
        self.mode            = mode
        self.lowRam          = lowRam
        self.imageStrength   = imageStrength
        self.enableTeacache  = enableTeacache
        self.teacacheThresh  = teacacheThresh
        self.loras            = loras
        self.additionalImages = additionalImages
        self.modelPath        = modelPath
        self.steps           = steps
        self.stage1Steps     = stage1Steps
        self.stage2Steps     = stage2Steps
        self.folder          = folder
        self.status          = .pending
        self.log             = ""
        self.createdAt       = createdAt
    }
}

extension VideoJob: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, imagePath, width, height
        case durationSeconds, frameRate, seed, mode, lowRam, imageStrength, enableTeacache, teacacheThresh, loras, additionalImages, modelPath
        case steps, stage1Steps, stage2Steps, folder
        case status, log, outputPath, createdAt, startedAt, completedAt, resolvedSeed, thumbnailData
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(imagePath, forKey: .imagePath)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(seed, forKey: .seed)
        try c.encode(mode, forKey: .mode)
        try c.encode(lowRam, forKey: .lowRam)
        try c.encode(imageStrength, forKey: .imageStrength)
        try c.encode(enableTeacache, forKey: .enableTeacache)
        try c.encode(teacacheThresh, forKey: .teacacheThresh)
        try c.encode(loras, forKey: .loras)
        try c.encode(additionalImages, forKey: .additionalImages)
        try c.encode(modelPath, forKey: .modelPath)
        try c.encode(steps, forKey: .steps)
        try c.encode(stage1Steps, forKey: .stage1Steps)
        try c.encode(stage2Steps, forKey: .stage2Steps)
        try c.encode(folder, forKey: .folder)
        try c.encode(status, forKey: .status)
        try c.encode(log, forKey: .log)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(outputPath, forKey: .outputPath)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(resolvedSeed, forKey: .resolvedSeed)
        try c.encodeIfPresent(thumbnailData, forKey: .thumbnailData)
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date.distantPast
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            prompt: try c.decode(String.self, forKey: .prompt),
            imagePath: try c.decode(String.self, forKey: .imagePath),
            width: try c.decode(Int.self, forKey: .width),
            height: try c.decode(Int.self, forKey: .height),
            durationSeconds: try c.decode(Double.self, forKey: .durationSeconds),
            frameRate: try c.decode(Int.self, forKey: .frameRate),
            seed: try c.decode(Int.self, forKey: .seed),
            mode: try c.decode(GenerationMode.self, forKey: .mode),
            lowRam: try c.decode(Bool.self, forKey: .lowRam),
            imageStrength: (try? c.decode(Double.self, forKey: .imageStrength)) ?? 0.95,
            enableTeacache: (try? c.decode(Bool.self, forKey: .enableTeacache)) ?? false,
            teacacheThresh: (try? c.decode(Double.self, forKey: .teacacheThresh)) ?? 0.5,
            loras: (try? c.decode([LoraEntry].self, forKey: .loras)) ?? [],
            additionalImages: (try? c.decode([AdditionalImageEntry].self, forKey: .additionalImages)) ?? [],
            modelPath: (try? c.decode(String.self, forKey: .modelPath)) ?? "",
            steps: (try? c.decode(Int.self, forKey: .steps)) ?? 8,
            stage1Steps: (try? c.decode(Int.self, forKey: .stage1Steps)) ?? 30,
            stage2Steps: (try? c.decode(Int.self, forKey: .stage2Steps)) ?? 3,
            folder: (try? c.decode(String.self, forKey: .folder)) ?? "",
            createdAt: createdAt
        )
        status        = try c.decode(JobStatus.self, forKey: .status)
        log           = (try? c.decode(String.self, forKey: .log)) ?? ""
        outputPath    = try? c.decode(String.self, forKey: .outputPath)
        startedAt     = try? c.decode(Date.self, forKey: .startedAt)
        completedAt   = try? c.decode(Date.self, forKey: .completedAt)
        resolvedSeed  = try? c.decode(Int.self, forKey: .resolvedSeed)
        thumbnailData = try? c.decode(Data.self, forKey: .thumbnailData)
    }
}
