import Foundation

/// Persists the SeedVR2 upscale queue. Queue operations come from the
/// ``QueueListedJob`` store extension. Single-output only — there is no multi-seed
/// fan-out, so ``expandBatchJob(_:)`` is a no-op (the shared ``JobRunner`` engine
/// only calls it for jobs with a non-empty `seeds`, which SeedVR2 never has).
@Observable
@MainActor
final class SeedVR2JobStore: @MainActor ProfileScopedJobStore {
    static let interruptedMessage = "Interrupted — app was quit during upscale"

    @ObservationIgnored let history = JobHistoryFile(fileName: "seedvr2-jobs.json", directory: nil)

    var jobs: [SeedVR2Job] = []
    var isRunning: Bool = false

    /// No-op: SeedVR2 jobs are single-output, so the engine never fans them out.
    func expandBatchJob(_: SeedVR2Job) {}
}
