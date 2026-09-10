import AppKit

/// Publishes whether the system pasteboard currently holds an image, so SwiftUI
/// paste affordances can enable/disable live.
///
/// macOS provides no pasteboard-change notification, and `NSPasteboard` reads are
/// only re-evaluated when a view redraws, so a copy never reaches a purely
/// computed check until some unrelated in-app state change forces a redraw.
/// Two things can change the pasteboard under us:
///
/// - A copy in *another* app, which requires that app to be frontmost and so
///   deactivates us. `didBecomeActiveNotification` covers it the instant we
///   regain focus, with no polling while we sit in the background.
/// - A copy in *this* app — the "Copy Image" context-menu items in the gallery,
///   the preview panes and the metadata panel. No activation change happens
///   there, so it needs a poll.
///
/// The poll therefore runs only while we are the active app, and each tick reads
/// `NSPasteboard.changeCount` (a cheap integer) before doing any real pasteboard
/// decoding.
@MainActor
final class ClipboardImageMonitor: ObservableObject {
    /// Fast enough that the paste button is lit by the time the hand travels from
    /// the context menu to it, slow enough to be free.
    private static let pollInterval: TimeInterval = 0.5

    @Published private(set) var hasImage = false

    private let imageExtensions: Set<String>
    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var lastChangeCount: Int?

    init(imageExtensions: Set<String>) {
        self.imageExtensions = imageExtensions
    }

    func start() {
        refresh()
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.startPolling()
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPolling() }
        }
        if NSApp?.isActive ?? false {
            startPolling()
        }
    }

    func stop() {
        stopPolling()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // .common so ticks keep landing while a menu is open or a list is scrolling.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        let pb = NSPasteboard.general
        // Nothing has been written since the last look — skip the decode.
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let value = pb.canReadObject(forClasses: [NSImage.self], options: nil)
            || pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .compactMap { $0 as? URL }
            .first { imageExtensions.contains($0.pathExtension.lowercased()) } != nil
        if value != hasImage {
            hasImage = value
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }
}
