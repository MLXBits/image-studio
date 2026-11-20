import Foundation

/// Persists the FLUX generation queue. Queue operations come from the
/// ``QueueListedJob`` store extension; ``FluxJobRunner`` runs the jobs.
@Observable
@MainActor
final class JobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "jobs.json", directory: nil)

    var jobs: [FluxJob] = []
    var isRunning: Bool = false
}
