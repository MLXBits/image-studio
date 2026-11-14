import Foundation

/// Persists and manages the Krea 2 Turbo generation queue. Queue operations
/// come from the ``QueueListedJob`` store extension.
@Observable
@MainActor
final class Krea2JobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "krea2-jobs.json", directory: nil)

    var jobs: [Krea2Job] = []
    var isRunning: Bool = false

    func expandBatchJob(_ batchJob: Krea2Job) {
        guard let idx = jobs.firstIndex(where: { $0.id == batchJob.id }) else { return }
        let expanded = zip(batchJob.seeds, batchJob.outputPaths).enumerated().map { i, pair in
            let (seed, path) = pair
            let job = Krea2Job(
                prompt: batchJob.prompt,
                negativePrompt: batchJob.negativePrompt,
                width: batchJob.width,
                height: batchJob.height,
                seed: seed,
                steps: batchJob.steps,
                guidance: batchJob.guidance,
                quantize: batchJob.quantize,
                lowRam: batchJob.lowRam,
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
