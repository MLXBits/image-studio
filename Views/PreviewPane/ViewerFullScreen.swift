import AppKit
import SwiftUI

// MARK: - Real full-screen for the image viewer

/// Takes the window into real macOS full-screen for as long as the full-size
/// viewer is up, and puts it back afterwards.
///
/// The viewer only ever painted over the window's *content*, so the titlebar,
/// the menu bar and the Dock all survived it — full-screen in name only. Handing
/// the window to AppKit's full-screen instead gets all three for free, and a
/// full-screen window can't be moved, so the titlebar drag that wedges the app
/// isn't reachable.
///
/// The ~0.5s Space transition each way is the price, and it's not avoidable:
/// Reduce Motion only swaps the zoom for a cross-fade, and covering the screen
/// with this window instead doesn't work — AppKit's `constrainFrameRect` won't
/// let a `.titled` window over the menu bar, leaving a strip of desktop at the
/// top. Escaping that needs a window we own outright.
///
/// Toggling full-screen while AppKit is mid-transition wedges the window on its
/// own, so a request that lands during a transition is held and applied when the
/// transition finishes.
@MainActor
final class ViewerFullScreenController {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// True only when *we* took the window full-screen. A window the user already
    /// had full-screen is left that way when the viewer closes.
    private var didEnter = false
    private var isTransitioning = false
    /// Set when a request lands mid-transition; applied once it finishes.
    private var pendingActive: Bool?

    /// Binds to the window hosting this `ContentView`. Each window in the group
    /// drives its own, so this never reaches for `NSApp.keyWindow`.
    func attach(to window: NSWindow) {
        guard window !== self.window else { return }
        removeObservers()
        self.window = window

        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.transitionFinished() }
            })
        }
    }

    /// Drives the window to match the viewer: full-screen while it's up, back to
    /// how the user had it when it closes.
    func setActive(_ active: Bool) {
        guard let window else { return }
        if isTransitioning {
            pendingActive = active
            return
        }
        pendingActive = nil

        let isFullScreen = window.styleMask.contains(.fullScreen)
        if active {
            guard !isFullScreen else { return } // already the user's own full-screen
            didEnter = true
        } else {
            // Nothing to undo if we never entered, or if the user left full-screen
            // themselves while the viewer was up.
            guard didEnter, isFullScreen else {
                didEnter = false
                return
            }
            didEnter = false
        }
        isTransitioning = true
        window.toggleFullScreen(nil)
    }

    private func transitionFinished() {
        isTransitioning = false
        if let pending = pendingActive {
            pendingActive = nil
            setActive(pending)
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit {
        let observers = observers
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

// MARK: - Window accessor

/// Hands the hosting `NSWindow` back once the view is planted in one.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = ResolvingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class ResolvingView: NSView {
    var onResolve: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onResolve?(window) }
    }

    /// Invisible plumbing — never take a click off the view it backs.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
