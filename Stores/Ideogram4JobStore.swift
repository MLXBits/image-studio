import Foundation

/// Persists and manages the Ideogram 4 generation queue.
@Observable
@MainActor
final class Ideogram4JobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "ideogram4-jobs.json", directory: nil)

    var jobs: [Ideogram4Job] = []
    var isRunning: Bool = false

    var pendingJobs: [Ideogram4Job] {
        jobs.filter { $0.status == .pending }
    }

    // MARK: - Queue management

    func add(_ job: Ideogram4Job) {
        jobs.insert(job, at: 0)
        pruneIfNeeded()
        save()
    }

    func cancelJob(_ job: Ideogram4Job) {
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

    func restart(_ job: Ideogram4Job) {
        job.status = .pending
        job.log = ""
        job.outputPath = nil
        job.resolvedSeed = nil
        job.thumbnailData = nil
        job.currentStep = 0
        job.totalSteps = job.preset.stepCount
        job.startedAt = nil
        job.completedAt = nil
        job.latestStepwisePath = nil
        placeNext(job)
        save()
    }
}
