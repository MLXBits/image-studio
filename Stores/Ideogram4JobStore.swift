import Foundation

/// Persists and manages the Ideogram 4 generation queue.
@Observable
@MainActor
final class Ideogram4JobStore {
    private static let appSupportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MLXBits Image Studio", isDirectory: true)
    }()

    private static let jobsURL: URL = appSupportURL.appendingPathComponent("ideogram4-jobs.json")
    private static let maxJobs = 100

    var jobs: [Ideogram4Job] = []
    var isRunning: Bool = false

    @ObservationIgnored private let saveDebouncer = Debouncer()

    var pendingJobs: [Ideogram4Job] {
        jobs.filter { $0.status == .pending }
    }

    init() {
        load()
    }

    // MARK: - Queue management

    func add(_ job: Ideogram4Job) {
        jobs.insert(job, at: 0)
        pruneIfNeeded()
        save()
    }

    func addBatch(_ jobs: [Ideogram4Job]) {
        for job in jobs.reversed() {
            self.jobs.insert(job, at: 0)
        }
        pruneIfNeeded()
        save()
    }

    func expandBatchJob(_ batchJob: Ideogram4Job) {
        guard let idx = jobs.firstIndex(where: { $0.id == batchJob.id }) else { return }
        let expanded = zip(batchJob.seeds, batchJob.outputPaths).enumerated().map { i, pair in
            let (seed, path) = pair
            let job = Ideogram4Job(
                preset: batchJob.preset,
                caption: batchJob.caption,
                usePlainPrompt: batchJob.usePlainPrompt,
                plainPrompt: batchJob.plainPrompt,
                width: batchJob.width,
                height: batchJob.height,
                seed: seed,
                quantize: batchJob.quantize,
                lowRam: batchJob.lowRam,
                strictValidation: batchJob.strictValidation,
                board: batchJob.board,
                createdAt: batchJob.createdAt
            )
            job.status = .completed
            job.resolvedSeed = seed
            job.outputPath = path
            job.thumbnailData = batchJob.outputThumbnails.indices.contains(i) ? batchJob.outputThumbnails[i] : nil
            job.log = batchJob.log
            job.currentStep = batchJob.preset.stepCount
            job.totalSteps = batchJob.preset.stepCount
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
        jobs.removeAll { $0.id == job.id }
        jobs.insert(job, at: 0)
        save()
    }

    // MARK: - Persistence

    private func pruneIfNeeded() {
        guard jobs.count > Self.maxJobs else { return }
        var result = jobs
        while result.count > Self.maxJobs {
            if let idx = result.indices.reversed().first(where: { result[$0].status.isTerminal }) {
                result.remove(at: idx)
            } else {
                break
            }
        }
        jobs = result
    }

    /// Debounced: encoding up to 100 jobs (logs + thumbnails) after every mutation is
    /// too heavy to do per call. The Debouncer flushes pending work at app termination.
    func save() {
        saveDebouncer.schedule { [weak self] in self?.saveNow() }
    }

    private func saveNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(jobs.prefix(Self.maxJobs))) {
            try? FileManager.default.createDirectory(at: Self.appSupportURL, withIntermediateDirectories: true)
            try? data.write(to: Self.jobsURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.jobsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([Ideogram4Job].self, from: data) else { return }
        for job in loaded where job.status == .running {
            job.status = .failed("Interrupted — app was quit during generation")
        }
        jobs = loaded
    }
}
