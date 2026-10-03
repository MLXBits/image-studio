import Foundation

/// Persists and manages the image generation queue.
///
/// `JobStore` owns the authoritative list of ``FluxJob`` objects, serializes them to disk after
/// every mutation, and exposes helpers for adding, cancelling, restarting, and pruning jobs.
/// It does not execute jobs — that is handled by ``FluxJobRunner``.
@Observable
@MainActor
final class JobStore: ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "jobs.json", directory: nil)

    var jobs: [FluxJob] = []
    var isRunning: Bool = false

    var pendingJobs: [FluxJob] {
        jobs.filter { $0.status == .pending }
    }

    var runningJob: FluxJob? {
        jobs.first { $0.status == .running }
    }

    // MARK: - Queue management

    func add(_ job: FluxJob) {
        jobs.insert(job, at: 0)
        pruneIfNeeded()
        save()
    }

    func addBatch(_ jobs: [FluxJob]) {
        for job in jobs.reversed() {
            self.jobs.insert(job, at: 0)
        }
        pruneIfNeeded()
        save()
    }

    func expandBatchJob(_ batchJob: FluxJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == batchJob.id }) else { return }
        let expanded = zip(batchJob.seeds, batchJob.outputPaths).enumerated().map { i, pair in
            let (seed, path) = pair
            let job = FluxJob(
                model: batchJob.model,
                customModelRepo: batchJob.customModelRepo,
                customBaseModel: batchJob.customBaseModel,
                prompt: batchJob.prompt,
                negativePrompt: batchJob.negativePrompt,
                width: batchJob.width,
                height: batchJob.height,
                seed: seed,
                steps: batchJob.steps,
                guidance: batchJob.guidance,
                loras: batchJob.loras,
                quantize: batchJob.quantize,
                lowRam: batchJob.lowRam,
                imagePath: batchJob.imagePath,
                imageStrength: batchJob.imageStrength,
                isEditMode: batchJob.isEditMode,
                editImagePaths: batchJob.editImagePaths,
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

    func remove(ids: Set<UUID>, deleteFiles: Bool = false) {
        if deleteFiles {
            for id in ids {
                if let job = jobs.first(where: { $0.id == id }),
                   let path = job.outputPath {
                    try? FileManager.default.removeItem(atPath: path)
                    let sidecar = MetadataSidecar.sidecarURL(for: path)
                    try? FileManager.default.removeItem(at: sidecar)
                }
            }
        }
        jobs.removeAll { ids.contains($0.id) }
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
        // Move to front so it runs next
        jobs.removeAll { $0.id == job.id }
        jobs.insert(job, at: 0)
        save()
    }
}
