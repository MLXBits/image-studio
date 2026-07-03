import AppKit
import SwiftUI

/// NSTextView-backed log viewer.
///
/// SwiftUI `Text` + `textSelection` (and the old whole-string `NSTextView.string = text`
/// approach) re-lay the entire document on every append. With LoRAs the log grows a line
/// per layer, so opening or streaming such a log beachballs. This view instead:
///   - enables non-contiguous layout, so opening a large log lays out lazily on scroll
///     rather than all at once, and
///   - applies only the changed suffix on update (common-prefix diff), so a tqdm line
///     rewrite or a few appended lines touch a tiny range instead of the whole document.
/// Auto-scroll follows the tail only when the user is already near the bottom, so scrolling
/// up to read (e.g. the per-layer LoRA lines) isn't yanked back down.
struct LogTextView: NSViewRepresentable {
    final class Coordinator {
        var fontSize: CGFloat
        init(fontSize: CGFloat) {
            self.fontSize = fontSize
        }
    }

    let text: String
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(fontSize: fontSize)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        // swiftlint:disable:next force_cast
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.textStorage?.setAttributedString(attributed(text))
        textView.scrollToEndOfDocument(nil)
        context.coordinator.fontSize = fontSize
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        // A font-size change re-attributes everything; nothing else can be incremental.
        if context.coordinator.fontSize != fontSize {
            context.coordinator.fontSize = fontSize
            storage.setAttributedString(attributed(text))
            textView.scrollToEndOfDocument(nil)
            return
        }

        let current = storage.string as NSString
        let next = text as NSString
        if current.isEqual(to: text) { return }

        let stickToBottom = isNearBottom(scrollView)

        // Reuse the font already in the storage so a manual zoom (Format ▸ Font ▸
        // Bigger/Smaller, ⌘+/⌘−) survives appended lines instead of snapping back to the
        // settings size. An explicit settings change is handled by the reset path above.
        let font = currentFont(in: storage)

        // Replace only the differing suffix. For a pure append the common prefix is the
        // whole current string (range length 0); for a tqdm rewrite it's everything up to
        // the last line.
        let maxPrefix = min(current.length, next.length)
        var i = 0
        while i < maxPrefix, current.character(at: i) == next.character(at: i) {
            i += 1
        }
        let replaceRange = NSRange(location: i, length: current.length - i)
        storage.replaceCharacters(in: replaceRange, with: attributed(next.substring(from: i), font: font))

        if stickToBottom { textView.scrollToEndOfDocument(nil) }
    }

    private func attributed(_ string: String, font: NSFont? = nil) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: font ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// The font of the existing text (honoring a manual ⌘+/⌘− zoom), or the settings size
    /// when the storage is empty.
    private func currentFont(in storage: NSTextStorage) -> NSFont {
        guard storage.length > 0,
              let font = storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont
        else { return .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        return font
    }

    /// True when the last line is (nearly) visible, so we should keep following the tail.
    private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        return visibleMaxY >= documentView.bounds.maxY - 24
    }
}
