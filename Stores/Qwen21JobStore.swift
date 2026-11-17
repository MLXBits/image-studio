import Foundation

/// Persists and manages the Qwen-Image 2.1 Turbo generation queue. Queue
/// operations come from the ``QueueListedJob`` store extension.
@Observable
@MainActor
final class Qwen21JobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "qwen21-jobs.json", directory: nil)

    var jobs: [Qwen21Job] = []
    var isRunning: Bool = false
}
