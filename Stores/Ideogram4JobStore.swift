import Foundation

/// Persists the Ideogram 4 generation queue. Queue operations come from the
/// ``QueueListedJob`` store extension.
@Observable
@MainActor
final class Ideogram4JobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "ideogram4-jobs.json", directory: nil)

    var jobs: [Ideogram4Job] = []
    var isRunning: Bool = false
}
