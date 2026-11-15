import Foundation

/// Persists and manages the Z-Image generation queue. Queue operations come
/// from the ``QueueListedJob`` store extension.
@Observable
@MainActor
final class ZImageJobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "zimage-jobs.json", directory: nil)

    var jobs: [ZImageJob] = []
    var isRunning: Bool = false

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
            job.markExpanded(from: batchJob, seed: seed, path: path, index: i)
            return job
        }
        jobs.replaceSubrange(idx ... idx, with: expanded)
    }
}
