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

    /// `nil` when there is no directory, no file yet, or it doesn't decode.
    func read<T: Decodable>(_: T.Type) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
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
            history.write(Array(jobs.prefix(JobHistoryFile.maxJobs)))
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
