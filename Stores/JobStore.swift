import Foundation

/// Persists and manages the image generation queue.
///
/// `JobStore` owns the authoritative list of ``FluxJob`` objects, serializes them to disk after
/// every mutation, and exposes helpers for adding, cancelling, restarting, and pruning jobs.
/// It does not execute jobs — that is handled by ``FluxJobRunner``.
@Observable
@MainActor
final class JobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "jobs.json", directory: nil)

    var jobs: [FluxJob] = []
    var isRunning: Bool = false

    var pendingJobs: [FluxJob] {
        jobs.filter { $0.status == .pending }
    }

    // MARK: - Queue management

    func add(_ job: FluxJob) {
        jobs.insert(job, at: 0)
        pruneIfNeeded()
        save()
    }

    func cancelJob(_ job: FluxJob) {
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

    func restart(_ job: FluxJob) {
        job.status = .pending
        job.log = ""
        job.outputPath = nil
        job.resolvedSeed = nil
        job.thumbnailData = nil
        job.currentStep = 0
        job.totalSteps = job.steps
        job.startedAt = nil
        job.completedAt = nil
        job.latestStepwisePath = nil
        placeNext(job)
        save()
    }
}
