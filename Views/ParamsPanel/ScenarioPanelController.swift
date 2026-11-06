import AppKit
import SwiftUI

/// Hosts the scenario generator in a floating utility panel rather than a popover, so
/// it stays open beside the params while you tweak and re-roll. One controller per
/// button; the panel is reused (never released) so a click toggles it, and closing it
/// frees the warm Gemma model.
@MainActor
final class ScenarioPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var session: ScenarioSession?
    // The panel is built once and reused, so the hosted view can't capture the
    // callbacks directly — it would pin the very first SwiftUI closure forever.
    // They're stored here and refreshed on every toggle instead.
    private var onSelect: (String) -> Void = { _ in }
    private var onQueue: ([String]) -> Void = { _ in }
    private var profileObserver: NSObjectProtocol?

    override init() {
        super.init()
        // A profile switch rebuilds the main window but not this panel. Cancel a
        // roll in flight (a cancelled batch never auto-queues) and close the panel,
        // so neither its prompts nor its outline edits reach the next profile.
        // Synchronous (`queue: nil`), so it runs before the switch proceeds.
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileStore.willDeactivateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func toggle(
        session: ScenarioSession,
        settings: AppSettings,
        downloads: ModelDownloadStore,
        onSelect: @escaping (String) -> Void,
        onQueue: @escaping ([String]) -> Void = { _ in }
    ) {
        self.onSelect = onSelect
        self.onQueue = onQueue
        if let panel {
            if panel.isVisible {
                panel.close()
            } else {
                attachAndShow(panel)
            }
            return
        }
        self.session = session
        let root = ScenarioGeneratorView(
            session: session,
            onSelect: { [weak self] text in
                self?.onSelect(text)
                self?.panel?.close()
            },
            // Unlike "Use", queueing leaves the panel up: the whole point is that the
            // next batch off the same outline is one more click.
            onQueue: { [weak self] prompts in self?.onQueue(prompts) },
            onClose: { [weak self] in self?.panel?.close() }
        )
        .environment(settings)
        .environment(downloads)

        // A resizable panel with a fixed default size — NOT NSHostingController's
        // `.preferredContentSize` auto-sizing, which resizes the window mid display
        // cycle and throws in `_postWindowNeedsUpdateConstraints` (hard crash).
        let hosting = NSHostingController(rootView: root)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scenario Generator"
        // Added as a child of the main app window (see attachAndShow): it stays above the
        // app's own windows but, at normal level, recedes behind other apps when you switch
        // away — unlike `.floating`, which keeps it above every app (e.g. over VS Code).
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 420)
        panel.contentViewController = hosting
        panel.delegate = self
        panel.center()
        panel.setFrameAutosaveName("ScenarioGeneratorPanel")
        self.panel = panel
        attachAndShow(panel)
    }

    /// Cancels a roll in flight and closes the panel, which frees the warm model.
    func close() {
        panel?.close()
    }

    /// Attaches the panel as a child of the app's main window so it floats above the app
    /// but not other applications, then brings it forward. Re-attaches on reopen because
    /// closing a child window detaches it from its parent.
    private func attachAndShow(_ panel: NSPanel) {
        if panel.parent == nil,
           let parent = NSApp.mainWindow ?? NSApp.keyWindow
           ?? NSApp.windows.first(where: { $0.isVisible && $0 !== panel }) {
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Fires on both the titlebar close button and programmatic `close()`, so the warm
    /// LLM is always released (kept resident across re-rolls only while the panel is up).
    func windowWillClose(_: Notification) {
        session?.task?.cancel()
        session?.generator.shutdown()
    }

    /// Block-based observers are never removed automatically.
    isolated deinit {
        if let profileObserver {
            NotificationCenter.default.removeObserver(profileObserver)
        }
    }
}
