import Foundation

/// Persists and manages the Z-Image generation queue. Queue operations come
/// from the ``QueueListedJob`` store extension.
@Observable
@MainActor
final class ZImageJobStore: @MainActor ProfileScopedJobStore {
    @ObservationIgnored let history = JobHistoryFile(fileName: "zimage-jobs.json", directory: nil)

    var jobs: [ZImageJob] = []
    var isRunning: Bool = false
}
