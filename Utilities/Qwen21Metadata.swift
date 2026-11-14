import Foundation

/// The sidecar written beside each Qwen-Image 2.1 image.
nonisolated struct Qwen21Metadata: Codable {
    @MainActor static func from(job: Qwen21Job) -> Self {
        Self(
            isEditMode: job.isEditMode,
            editImagePaths: job.isEditMode ? job.editImagePaths : nil,
            matchReferenceSize: job.isEditMode ? job.matchReferenceSize : nil,
            prompt: job.prompt,
            customModelRepo: job.customModelRepo.isEmpty ? nil : job.customModelRepo,
            steps: job.steps,
            quantize: job.quantize,
            width: job.width,
            height: job.height,
            seed: job.resolvedSeed ?? job.seed,
            loras: job.loras.isEmpty ? nil : job.loras,
            lowRam: job.lowRam ? true : nil,
            board: job.board.isEmpty ? nil : job.board,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log
        )
    }

    var isEditMode: Bool
    var editImagePaths: [String]?
    var matchReferenceSize: Bool?
    var prompt: String
    var customModelRepo: String?
    var steps: Int
    var quantize: Int
    /// The form's size. For an edit that followed its references, the file's
    /// own pixel size is the real output size.
    var width: Int
    var height: Int
    var seed: Int
    var loras: [LoraEntry]?
    var lowRam: Bool?
    var board: String?
    var generatedAt: Date
    var startedAt: Date?
    var log: String?
}
