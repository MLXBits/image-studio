import SwiftUI

/// A queue row's right-click menu, shared by every family's drawer: Duplicate,
/// Retry, Run Next and Retry All Failed. Only waiting rows can be dragged to
/// reorder (the drawer's `.onMove` calls ``ProfileScopedJobStore/movePending(fromOffsets:toOffset:)``).
private struct QueueRowActions<Store: ProfileScopedJobStore>: ViewModifier {
    private static func isFailed(_ status: JobStatus) -> Bool {
        if case .failed = status {
            return true
        }
        return false
    }

    let job: Store.PersistedJob
    let store: Store
    /// Nil for a family whose jobs cannot be copied (SeedVR2 upscales).
    let duplicate: (() -> Void)?
    /// Starts the next job when the runner is idle.
    let start: () -> Void

    func body(content: Content) -> some View {
        content
            .moveDisabled(job.status != .pending)
            .contextMenu {
                if let duplicate {
                    Button("Duplicate") {
                        duplicate()
                        start()
                    }
                }
                switch job.status {
                case .failed, .cancelled:
                    Button("Retry") {
                        store.restart(job)
                        start()
                    }
                case .pending:
                    Button("Run Next") {
                        store.moveToFront(job)
                        start()
                    }
                default:
                    EmptyView()
                }
                if store.jobs.contains(where: { Self.isFailed($0.status) }) {
                    Divider()
                    Button("Retry All Failed") {
                        store.retryAllFailed()
                        start()
                    }
                }
            }
    }
}

extension View {
    /// The queue row menu, with Duplicate.
    func queueRowActions<Store: ProfileScopedJobStore>(
        _ job: Store.PersistedJob,
        in store: Store,
        start: @escaping () -> Void
    ) -> some View where Store.PersistedJob: SeedSplittableJob {
        modifier(QueueRowActions(job: job, store: store, duplicate: { store.duplicate(job) }, start: start))
    }

    /// The queue row menu for a family whose jobs cannot be copied (SeedVR2).
    /// A separate name, not an overload: a generic drawer that forgot its
    /// `SeedSplittableJob` constraint would otherwise fall back here silently.
    func queueRowActionsWithoutDuplicate<Store: ProfileScopedJobStore>(
        _ job: Store.PersistedJob,
        in store: Store,
        start: @escaping () -> Void
    ) -> some View {
        modifier(QueueRowActions(job: job, store: store, duplicate: nil, start: start))
    }
}
