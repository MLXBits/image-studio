import AppKit
import SwiftUI

/// A text editor backed directly by NSTextView, with explicit content insets
/// so cursor, entered text, and placeholder can all start at the same x/y position.
///
/// Pass `ghostSuffix` to show template-contributed text after the user's editable content.
/// The ghost text is styled in tertiaryLabelColor and cannot be edited.
struct InsetTextEditor: NSViewRepresentable {
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InsetTextEditor

        init(_ parent: InsetTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = userText(from: tv.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let ghostLen = parent.ghostSuffix.utf16.count
            guard ghostLen > 0 else { return }

            // Derive userLen from the live text view string rather than parent.text,
            // because textViewDidChangeSelection can fire before textDidChange — if it
            // does, parent.text is still the pre-keystroke value (e.g. "" when the
            // user types the first character), which would clamp the cursor to 0.
            let userLen = max(0, tv.string.utf16.count - ghostLen)
            let sel = tv.selectedRange()

            // Clamp selection to user-text range. Preserves selection length (e.g. Cmd+A
            // selects all user text, not the ghost). Re-triggers textViewDidChangeSelection,
            // but the clamped range satisfies the guard below, ending the recursion.
            if NSMaxRange(sel) > userLen {
                let clampedLoc = min(sel.location, userLen)
                tv.setSelectedRange(NSRange(location: clampedLoc, length: userLen - clampedLoc))
            }

            // Always keep typing attributes at normal color so new chars aren't styled as ghost.
            tv.typingAttributes = InsetTextEditor.userAttrs
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let ghostLen = parent.ghostSuffix.utf16.count
            guard ghostLen > 0 else { return true }

            let userLen = parent.text.utf16.count

            // Edit is entirely within user range: allow normally.
            if affectedCharRange.upperBound <= userLen { return true }

            // Edit is entirely within ghost range: block.
            if affectedCharRange.location >= userLen { return false }

            // Edit straddles the boundary (e.g. Cmd+A then type): clamp to user range
            // and perform the edit manually so the ghost text is preserved.
            let clampedRange = NSRange(
                location: affectedCharRange.location,
                length: userLen - affectedCharRange.location
            )
            let delegate = textView.delegate
            textView.delegate = nil
            textView.insertText(replacementString ?? "", replacementRange: clampedRange)
            textView.delegate = delegate
            parent.text = userText(from: textView.string)
            return false
        }

        /// Strips the ghost suffix from the full NSTextView string to recover user text.
        private func userText(from full: String) -> String {
            let ghostLen = parent.ghostSuffix.utf16.count
            guard ghostLen > 0 else { return full }
            let utf16 = full.utf16
            guard utf16.count >= ghostLen else { return full }
            let endIdx = utf16.index(utf16.endIndex, offsetBy: -ghostLen)
            return String(full[..<endIdx])
        }
    }

    static let userAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.labelColor,
    ]
    static let ghostAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.tertiaryLabelColor,
    ]

    @Binding var text: String
    var insets = NSSize(width: 5, height: 8)
    var ghostSuffix: String = ""

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = insets
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.typingAttributes = Self.userAttrs
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        let expected = text + ghostSuffix
        guard textView.string != expected else { return }

        let sel = textView.selectedRanges
        // Suppress delegate during programmatic changes to avoid binding feedback loop.
        let delegate = textView.delegate
        textView.delegate = nil

        if ghostSuffix.isEmpty {
            textView.string = text
        } else {
            let combined = NSMutableAttributedString(string: text, attributes: Self.userAttrs)
            combined.append(NSAttributedString(string: ghostSuffix, attributes: Self.ghostAttrs))
            textView.textStorage?.setAttributedString(combined)
        }

        textView.delegate = delegate
        textView.typingAttributes = Self.userAttrs

        // Clamp selection to user-text range so cursor never lands in ghost text.
        let userLen = text.utf16.count
        let clamped = sel.map { v -> NSValue in
            let r = v.rangeValue
            let loc = min(r.location, userLen)
            let len = min(r.length, max(0, userLen - loc))
            return NSValue(range: NSRange(location: loc, length: len))
        }
        textView.selectedRanges = clamped
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}
