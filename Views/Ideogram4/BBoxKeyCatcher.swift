import AppKit
import SwiftUI

// MARK: - BBoxKeyCatcher

/// Zero-size AppKit responder bridged into SwiftUI. SwiftUI's `.onKeyPress` +
/// `@FocusState` does not reliably take first-responder for a gesture-driven
/// canvas embedded in a scrolling form on macOS, so deletion is driven through
/// an `NSView` that we explicitly make first responder whenever the selection
/// changes (`focusTrigger` is bumped on every tap / drag).
struct BBoxKeyCatcher: NSViewRepresentable {
    var focusTrigger: Int
    var onDelete: () -> Void
    var onEscape: () -> Void

    func makeNSView(context _: Context) -> KeyView {
        let view = KeyView()
        view.onDelete = onDelete
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyView, context _: Context) {
        nsView.onDelete = onDelete
        nsView.onEscape = onEscape
        guard nsView.lastTrigger != focusTrigger else { return }
        nsView.lastTrigger = focusTrigger
        DispatchQueue.main.async { [weak nsView] in
            nsView?.window?.makeFirstResponder(nsView)
        }
    }
}

// MARK: - BBoxKeyCatcher.KeyView

/// Accepts first responder and routes Delete / Escape key codes to closures.
final class KeyView: NSView {
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Starts at 0 to match `focusRequest`'s initial value, so the catcher
    /// does not steal focus on first appearance — only after a real selection.
    var lastTrigger: Int = 0

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?() // 51 = delete/backspace, 117 = forward delete
        case 53: onEscape?() // 53 = escape
        default: super.keyDown(with: event)
        }
    }
}
