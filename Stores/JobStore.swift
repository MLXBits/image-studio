import Foundation

@Observable
@MainActor
final class JobStore {
    static let appSupportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MLXBits Image Studio", isDirectory: true)
    }()

    private static let jobsURL: URL = appSupportURL.appendingPathComponent("jobs.json")

    var jobs: [FluxJob] = []
    var isRunning: Bool = false

    init() { load() }

    // MARK: - Queue management

    func add(_ job: FluxJob) {
        jobs.insert(job, at: 0)
        save()
    }

    func addBatch(_ jobs: [FluxJob]) {
        for job in jobs.reversed() { self.jobs.insert(job, at: 0) }
        save()
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

    var pendingJobs: [FluxJob] { jobs.filter { $0.status == .pending } }
    var runningJob: FluxJob? { jobs.first { $0.status == .running } }

    // MARK: - Persistence

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(jobs.prefix(200))) {
            try? FileManager.default.createDirectory(at: Self.appSupportURL, withIntermediateDirectories: true)
            try? data.write(to: Self.jobsURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.jobsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([FluxJob].self, from: data) else { return }
        for job in loaded where job.status == .running {
            job.status = .failed("Interrupted — app was quit during generation")
        }
        jobs = loaded
    }
}
