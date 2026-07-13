import AppKit

/// Publishes whether the system pasteboard currently holds an image, so SwiftUI
/// paste affordances can enable/disable live.
///
/// macOS provides no pasteboard-change notification, and `NSPasteboard` reads are
/// only re-evaluated when a view redraws. A copy performed in another app
/// therefore never reaches a purely computed check until some unrelated in-app
/// state change forces a redraw. Copying from another app requires that app to be
/// frontmost, which deactivates us — so we re-check the instant we regain focus
/// (`didBecomeActiveNotification`), which covers the external-copy case without
/// any polling.
@MainActor
final class ClipboardImageMonitor: ObservableObject {
    @Published private(set) var hasImage = false

    private let imageExtensions: Set<String>
    private var activationObserver: NSObjectProtocol?

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
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func refresh() {
        let pb = NSPasteboard.general
        let value = pb.canReadObject(forClasses: [NSImage.self], options: nil)
            || pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .compactMap { $0 as? URL }
            .first { imageExtensions.contains($0.pathExtension.lowercased()) } != nil
        if value != hasImage { hasImage = value }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
}
