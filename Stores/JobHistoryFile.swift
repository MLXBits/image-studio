import Foundation

/// One family's queue history on disk: `<directory>/<fileName>`, written as
/// ISO-8601 JSON. The directory is the active profile's data folder and moves
/// with it (see ``ProfileScopedJobStore/activate(profileDirectory:)``).
@MainActor
final class JobHistoryFile {
    /// Jobs kept per family; older finished ones are pruned first.
    static let maxJobs = 100

    let fileName: String
    private(set) var directory: URL?
    private let debouncer = Debouncer()

    private var url: URL? {
        directory?.appendingPathComponent(fileName)
    }

    init(fileName: String, directory: URL?) {
        self.fileName = fileName
        self.directory = directory
    }

    /// Debounced: encoding up to 100 jobs (logs + thumbnails) after every
    /// mutation is too heavy to do per call. The Debouncer flushes pending work
    /// at app termination.
    func schedule(_ write: @escaping () -> Void) {
        debouncer.schedule(write)
    }

    /// Writes any pending save to the current directory, then points at `dir`.
    /// Flushing first keeps an edit made just before a profile switch in the
    /// profile it was made in.
    func retarget(to dir: URL?) {
        debouncer.flush()
        directory = dir
    }

    func write(_ value: some Encodable) {
        guard let directory, let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// `nil` when there is no directory, no file yet, or it doesn't decode (then
    /// the file is moved aside, see ``StoredJSON/load(_:from:decoder:)``).
    func read<T: Decodable>(_: T.Type) -> T? {
        guard let url else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return StoredJSON.load(T.self, from: url, decoder: decoder)
    }
}

/// A job store whose queue history belongs to the active profile. The five
/// family stores share this persistence; each supplies only its file and the
/// message for a job cut off mid-run.
@MainActor
protocol ProfileScopedJobStore: AnyObject {
    associatedtype PersistedJob: GeneratedJob & Codable

    /// Failure text for a job that was running when the app last quit.
    static var interruptedMessage: String { get }

    var jobs: [PersistedJob] { get set }
    var isRunning: Bool { get set }
    var history: JobHistoryFile { get }
}

extension ProfileScopedJobStore {
    static var interruptedMessage: String {
        "Interrupted — app was quit during generation"
    }

    /// Running or queued work would resolve its output path after a switch and
    /// land in the next profile's library.
    var blocksProfileSwitch: Bool {
        isRunning || jobs.contains { $0.status == .pending || $0.status == .running }
    }

    var queuedCount: Int {
        jobs.count { $0.status == .pending }
    }

    func save() {
        history.schedule { [weak self] in
            guard let self else { return }
            // Not capped here: pruneIfNeeded bounds finished jobs, and pending ones must all survive.
            history.write(jobs)
        }
    }

    /// Re-points the store at a profile's data folder: pending saves go to the
    /// old folder first, then the new folder's history loads (empty if none).
    func activate(profileDirectory: URL?) {
        history.retarget(to: profileDirectory)
        jobs = loadJobs()
    }

    func loadJobs() -> [PersistedJob] {
        guard let loaded = history.read([PersistedJob].self) else { return [] }
        for job in loaded where job.status == .running {
            job.status = .failed(Self.interruptedMessage)
        }
        return loaded
    }

    func pruneIfNeeded() {
        guard jobs.count > JobHistoryFile.maxJobs else { return }
        var result = jobs
        while result.count > JobHistoryFile.maxJobs {
            if let idx = result.indices.reversed().first(where: { result[$0].status.isTerminal }) {
                result.remove(at: idx)
            } else {
                break
            }
        }
        jobs = result
    }
}

/// A job the generic queue drawer can list and the shared queue operations can
/// re-queue (``Krea2Job``, ``Qwen21Job``).
@MainActor
protocol QueueListedJob: GeneratedJob {
    var prompt: String { get }
    var displayName: String { get }
    var steps: Int { get }
}

/// Queue operations shared by the stores whose jobs are ``QueueListedJob``s.
extension ProfileScopedJobStore where PersistedJob: QueueListedJob {
    var pendingJobs: [PersistedJob] {
        jobs.filter { $0.status == .pending }
    }

    func add(_ job: PersistedJob) {
        jobs.insert(job, at: 0)
        pruneIfNeeded()
        save()
    }

    func cancelJob(_ job: PersistedJob) {
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

    func restart(_ job: PersistedJob) {
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

extension GeneratedJob {
    /// Turns a fresh copy of `batch` into its `index`-th finished image when a
    /// multi-seed job is fanned out into one queue row per seed.
    func markExpanded(from batch: some GeneratedJob, seed: Int, path: String, index: Int) {
        status = .completed
        resolvedSeed = seed
        outputPath = path
        thumbnailData = batch.outputThumbnails.indices.contains(index) ? batch.outputThumbnails[index] : nil
        log = batch.log
        currentStep = totalSteps
        startedAt = batch.startedAt
        completedAt = batch.completedAt
    }
}
