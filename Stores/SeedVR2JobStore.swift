import Foundation

/// Persists and manages the SeedVR2 upscale queue.
///
/// Mirrors ``Krea2JobStore`` but single-output only — there is no multi-seed
/// fan-out, so ``expandBatchJob(_:)`` is a no-op (the shared ``JobRunner`` engine
/// only calls it for jobs with a non-empty `seeds`, which SeedVR2 never has).
@Observable
@MainActor
final class SeedVR2JobStore: ProfileScopedJobStore {
    static let interruptedMessage = "Interrupted — app was quit during upscale"

    @ObservationIgnored let history = JobHistoryFile(fileName: "seedvr2-jobs.json", directory: nil)

    var jobs: [SeedVR2Job] = []
    var isRunning: Bool = false

    var pendingJobs: [SeedVR2Job] {
        jobs.filter { $0.status == .pending }
    }

    // MARK: - Queue management

    func add(_ job: SeedVR2Job) {
        jobs.insert(job, at: 0)
        pruneIfNeeded()
        save()
    }

    /// No-op: SeedVR2 jobs are single-output, so the engine never fans them out.
    func expandBatchJob(_: SeedVR2Job) {}

    func remove(ids: Set<UUID>) {
        jobs.removeAll { ids.contains($0.id) }
        save()
    }

    func cancelJob(_ job: SeedVR2Job) {
        guard case .pending = job.status else { return }
        job.status = .cancelled
        save()
    }

    func cancelAllPending() {
        for job in jobs where job.status == .pending {
            job.status = .cancelled
        }
        save()
    }

    func purgeTerminal() {
        jobs.removeAll { $0.status.isTerminal }
        save()
    }

    func restart(_ job: SeedVR2Job) {
        job.status = .pending
        job.log = ""
        job.outputPath = nil
        job.resolvedSeed = nil
        job.thumbnailData = nil
        job.currentStep = 0
        job.totalSteps = 0
        job.startedAt = nil
        job.completedAt = nil
        job.latestStepwisePath = nil
        jobs.removeAll { $0.id == job.id }
        jobs.insert(job, at: 0)
        save()
    }
}
