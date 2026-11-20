import Foundation

nonisolated extension KeyedDecodingContainer {
    /// The value at `key`, or nil when it is missing or does not decode as `T`.
    /// A job history record from another build then still loads, and the field
    /// takes its default instead of failing the whole job.
    func lenient<T: Decodable>(_ key: Key, as _: T.Type = T.self) -> T? {
        try? decode(T.self, forKey: key)
    }
}

/// The history keys of the run-state fields every job type persists. Each
/// family's own `CodingKeys` holds only its parameters (and `id`, `createdAt`).
nonisolated enum RunStateKeys: String, CodingKey {
    case status, log, outputPath, resolvedSeed, thumbnailData
    case currentStep, totalSteps, startedAt, completedAt
}

extension GeneratedJob {
    /// Restores the run state from a history record, leniently. A record from
    /// before `totalSteps` was saved takes `defaultTotalSteps`.
    func decodeRunState(from decoder: Decoder, defaultTotalSteps: Int) throws {
        let c = try decoder.container(keyedBy: RunStateKeys.self)
        status = c.lenient(.status) ?? .pending
        log = c.lenient(.log) ?? ""
        outputPath = c.lenient(.outputPath)
        resolvedSeed = c.lenient(.resolvedSeed)
        thumbnailData = c.lenient(.thumbnailData)
        currentStep = c.lenient(.currentStep) ?? 0
        totalSteps = c.lenient(.totalSteps) ?? defaultTotalSteps
        startedAt = c.lenient(.startedAt)
        completedAt = c.lenient(.completedAt)
    }

    /// Writes the run state into the same JSON object as the family's own fields.
    func encodeRunState(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: RunStateKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(log, forKey: .log)
        try c.encode(currentStep, forKey: .currentStep)
        try c.encode(totalSteps, forKey: .totalSteps)
        try c.encodeIfPresent(outputPath, forKey: .outputPath)
        try c.encodeIfPresent(resolvedSeed, forKey: .resolvedSeed)
        try c.encodeIfPresent(thumbnailData, forKey: .thumbnailData)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}
