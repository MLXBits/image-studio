import AppKit

/// Coalesces bursts of save() calls into a single deferred disk write.
///
/// Persistence here is didSet-driven — every settings change or queue mutation
/// triggers a full JSON re-encode and write. Bursty callers (the notepad saves per
/// keystroke) turn that into one write per event. `schedule(_:)` (re)arms a short
/// window and only the last action within it runs.
///
/// Any pending action is flushed synchronously when the app terminates, so quitting
/// right after an edit cannot lose state.
final class Debouncer {
    private var task: Task<Void, Never>?
    private var pending: (() -> Void)?
    private let delay: Duration
    private var terminateObserver: NSObjectProtocol?

    init(delay: Duration = .milliseconds(500)) {
        self.delay = delay
        // willTerminate posts on the main thread and no further tasks run after it,
        // so the flush must happen synchronously inside the observer.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Schedules `action` to run after the debounce window, replacing any pending action.
    func schedule(_ action: @escaping () -> Void) {
        pending = action
        task?.cancel()
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Runs the pending action immediately. No-op when nothing is pending.
    func flush() {
        task?.cancel()
        task = nil
        let action = pending
        pending = nil
        action?()
    }
}
