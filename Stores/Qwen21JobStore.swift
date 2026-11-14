import Foundation

/// Persists and manages the Qwen-Image 2.1 Turbo generation queue. Queue
/// operations come from the ``QueueListedJob`` store extension.
@Observable
@MainActor
final class Qwen21JobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "qwen21-jobs.json", directory: nil)

    var jobs: [Qwen21Job] = []
    var isRunning: Bool = false

    func expandBatchJob(_ batchJob: Qwen21Job) {
        guard let idx = jobs.firstIndex(where: { $0.id == batchJob.id }) else { return }
        let expanded = zip(batchJob.seeds, batchJob.outputPaths).enumerated().map { i, pair in
            let job = Qwen21Job(
                isEditMode: batchJob.isEditMode,
                editImagePaths: batchJob.editImagePaths,
                matchReferenceSize: batchJob.matchReferenceSize,
                prompt: batchJob.prompt,
                customModelRepo: batchJob.customModelRepo,
                steps: batchJob.steps,
                quantize: batchJob.quantize,
                width: batchJob.width,
                height: batchJob.height,
                seed: pair.0,
                loras: batchJob.loras,
                lowRam: batchJob.lowRam,
                board: batchJob.board,
                createdAt: batchJob.createdAt
            )
            job.markExpanded(from: batchJob, seed: pair.0, path: pair.1, index: i)
            return job
        }
        jobs.replaceSubrange(idx ... idx, with: expanded)
    }
}
