import Foundation

/// A job a ``FamilyJobStore`` keeps: it splits by seed, lists in the queue drawer,
/// and names the profile's history file it is saved to.
protocol FamilyStoredJob: SeedSplittableJob, QueueListedJob, Codable {
    /// The file in the profile's data folder. It is on disk: never change one.
    static var historyFileName: String { get }
}

/// One family's generation queue, persisted per profile. Persistence and queue
/// operations come from the ``ProfileScopedJobStore`` extensions, so a family
/// supplies only its job type. SeedVR2, which has no seed fan-out, keeps its own.
@Observable
@MainActor
final class FamilyJobStore<Job: FamilyStoredJob>: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: Job.historyFileName, directory: nil)

    var jobs: [Job] = []
    var isRunning: Bool = false
}

extension FamilyJobStore: @MainActor GenerationJobStore {}

typealias JobStore = FamilyJobStore<FluxJob>
typealias Ideogram4JobStore = FamilyJobStore<Ideogram4Job>
typealias Krea2JobStore = FamilyJobStore<Krea2Job>
typealias ZImageJobStore = FamilyJobStore<ZImageJob>
typealias Qwen21JobStore = FamilyJobStore<Qwen21Job>

extension FluxJob: @MainActor FamilyStoredJob {
    static let historyFileName = "jobs.json"
}

extension Ideogram4Job: @MainActor FamilyStoredJob {
    static let historyFileName = "ideogram4-jobs.json"
}

extension Krea2Job: @MainActor FamilyStoredJob {
    static let historyFileName = "krea2-jobs.json"
}

extension ZImageJob: @MainActor FamilyStoredJob {
    static let historyFileName = "zimage-jobs.json"
}

extension Qwen21Job: @MainActor FamilyStoredJob {
    static let historyFileName = "qwen21-jobs.json"
}
