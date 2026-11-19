import AppKit
import UserNotifications

/// How a job ended, as a runner reports it to ``BackgroundSignals``.
struct JobFinish: Equatable {
    enum Outcome: Equatable {
        case completed(images: Int)
        /// The one-line cause (``FailureSummary/line(message:log:)``).
        case failed(summary: String)
    }

    let family: ModelFamily
    let outcome: Outcome
}

/// Signals that reach the user while the app is in the background: a
/// notification when a job finishes or fails, a dock bounce on a failure, and
/// the images still to make on the dock icon.
enum BackgroundSignals {
    /// The notification's title and body for a finished job.
    static func content(for finish: JobFinish) -> (title: String, body: String) {
        let family = finish.family.rawValue
        switch finish.outcome {
        case let .completed(images):
            let body = switch images {
            case 0: "The job finished."
            case 1: "1 image saved."
            default: "\(images) images saved."
            }
            return ("\(family) finished", body)
        case let .failed(summary):
            return ("\(family) failed", summary)
        }
    }

    /// The images a job has still to make: one per batch seed (one for a
    /// single-seed job), less those that have landed.
    static func imagesLeft(seedCount: Int, landed: Int) -> Int {
        max(max(seedCount, 1) - landed, 0)
    }

    /// The images one family's queue has still to make: each pending job's
    /// batch, plus what the running job has yet to land.
    static func imagesLeft<Job: GeneratedJob>(pending: [Job], running: Job?) -> Int {
        let waiting = pending.reduce(0) { total, job in
            total + imagesLeft(seedCount: job.seeds.count, landed: 0)
        }
        guard let running else { return waiting }
        return waiting + imagesLeft(seedCount: running.seeds.count, landed: running.completedSeedsInBatch)
    }

    /// The dock badge for the images still to make across the queue: none when empty.
    static func badgeLabel(imagesLeft: Int) -> String? {
        imagesLeft > 0 ? String(imagesLeft) : nil
    }

    static func showImagesLeft(_ count: Int) {
        NSApp.dockTile.badgeLabel = badgeLabel(imagesLeft: count)
    }

    /// Posts a notification when the app is not frontmost, and bounces the dock
    /// icon once when the job failed. In front, the window already shows it.
    static func jobFinished(_ finish: JobFinish) {
        guard !NSApp.isActive else { return }
        if case .failed = finish.outcome {
            NSApp.requestUserAttention(.informationalRequest)
        }
        post(content(for: finish))
    }

    private static func post(_ text: (title: String, body: String)) {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            // Every post waits for permission. Only the first ask prompts; after
            // that the system returns the saved answer. A refusal drops the post.
            // `.badge` too: once the app asks for notifications, macOS shows the
            // dock badge (the queue count) only when badges are allowed.
            guard await (try? center.requestAuthorization(options: [.alert, .sound, .badge])) == true
            else { return }
            try? await center.add(request)
        }
    }
}

/// Keeps the dock badge on the images still to make. Owned by the app, not a
/// window: jobs keep running with the main window closed, and the badge keeps
/// counting them down.
final class DockBadge {
    private let imagesLeft: () -> Int

    /// `imagesLeft` reads observable queue state; the badge follows its changes.
    init(imagesLeft: @escaping () -> Int) {
        self.imagesLeft = imagesLeft
        update()
    }

    private func update() {
        let count = withObservationTracking {
            imagesLeft()
        } onChange: { [weak self] in
            // Fires once, before the change lands: read it on the next turn, then track again.
            Task { @MainActor in self?.update() }
        }
        BackgroundSignals.showImagesLeft(count)
    }
}
