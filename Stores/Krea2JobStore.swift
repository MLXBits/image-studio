import Foundation

/// Persists and manages the Krea 2 Turbo generation queue. Queue operations
/// come from the ``QueueListedJob`` store extension.
@Observable
@MainActor
final class Krea2JobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "krea2-jobs.json", directory: nil)

    var jobs: [Krea2Job] = []
    var isRunning: Bool = false
}
