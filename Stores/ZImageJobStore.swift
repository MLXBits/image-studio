import Foundation

/// Persists and manages the Z-Image generation queue.
@Observable
@MainActor
final class ZImageJobStore: ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "zimage-jobs.json", directory: nil)

    var jobs: [ZImageJob] = []
    var isRunning: Bool = false

    var pendingJobs: [ZImageJob] {
        jobs.filter { $0.status == .pending }
    }

    // MARK: - Queue management

    func add(_ job: ZImageJob) {
        jobs.insert(job, at: 0)
        pruneIfNeeded()
        save()
    }

    func addBatch(_ jobs: [ZImageJob]) {
        for job in jobs.reversed() {
            self.jobs.insert(job, at: 0)
        }
        pruneIfNeeded()
        save()
    }

    func expandBatchJob(_ batchJob: ZImageJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == batchJob.id }) else { return }
        let expanded = zip(batchJob.seeds, batchJob.outputPaths).enumerated().map { i, pair in
            let (seed, path) = pair
            let job = ZImageJob(
                modelVariant: batchJob.modelVariant,
                prompt: batchJob.prompt,
                negativePrompt: batchJob.negativePrompt,
                width: batchJob.width,
                height: batchJob.height,
                seed: seed,
                steps: batchJob.steps,
                guidance: batchJob.guidance,
                quantize: batchJob.quantize,
                loras: batchJob.loras,
                board: batchJob.board,
                createdAt: batchJob.createdAt
            )
            job.status = .completed
            job.resolvedSeed = seed
            job.outputPath = path
            job.thumbnailData = batchJob.outputThumbnails.indices.contains(i) ? batchJob.outputThumbnails[i] : nil
            job.log = batchJob.log
            job.currentStep = batchJob.steps
            job.totalSteps = batchJob.steps
            job.startedAt = batchJob.startedAt
            job.completedAt = batchJob.completedAt
            return job
        }
        jobs.replaceSubrange(idx ... idx, with: expanded)
    }

    func remove(ids: Set<UUID>) {
        jobs.removeAll { ids.contains($0.id) }
        save()
    }

    func cancelJob(_ job: ZImageJob) {
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

    func restart(_ job: ZImageJob) {
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
        jobs.removeAll { $0.id == job.id }
        jobs.insert(job, at: 0)
        save()
    }
}
