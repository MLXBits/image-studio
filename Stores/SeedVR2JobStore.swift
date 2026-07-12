import Foundation

/// Persists and manages the SeedVR2 upscale queue.
///
/// Mirrors ``Krea2JobStore`` but single-output only — there is no multi-seed
/// fan-out, so ``expandBatchJob(_:)`` is a no-op (the shared ``JobRunner`` engine
/// only calls it for jobs with a non-empty `seeds`, which SeedVR2 never has).
@Observable
@MainActor
final class SeedVR2JobStore {
    private static let appSupportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MLXBits Image Studio", isDirectory: true)
    }()

    private static let jobsURL: URL = appSupportURL.appendingPathComponent("seedvr2-jobs.json")
    private static let maxJobs = 100

    var jobs: [SeedVR2Job] = []
    var isRunning: Bool = false

    @ObservationIgnored private let saveDebouncer = Debouncer()

    var pendingJobs: [SeedVR2Job] {
        jobs.filter { $0.status == .pending }
    }

    init() {
        load()
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
        guard let loaded = try? decoder.decode([SeedVR2Job].self, from: data) else { return }
        for job in loaded where job.status == .running {
            job.status = .failed("Interrupted — app was quit during upscale")
        }
        jobs = loaded
    }
}
