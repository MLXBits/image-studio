import AppKit
import SwiftUI

/// A text editor backed directly by NSTextView, with explicit content insets
/// so cursor, entered text, and placeholder can all start at the same x/y position.
///
/// Pass `ghostSuffix` to show template-contributed text after the user's editable content.
/// The ghost text is styled in tertiaryLabelColor and cannot be edited.
struct InsetTextEditor: NSViewRepresentable {
    /// NSTextView that reports when it becomes first responder (clicked / tabbed
    /// into) so callers can react to focus — e.g. selecting the owning element.
    final class FocusReportingTextView: NSTextView {
        var onFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?() }
            return ok
        }
    }

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
    /// Called when the text view gains first-responder focus.
    var onFocus: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // Manual scrollable-text-view assembly (mirrors NSTextView.scrollableTextView())
        // so we can inject a first-responder-reporting subclass.
        let contentSize = scrollView.contentSize
        let textView = FocusReportingTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.onFocus = onFocus
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
        textView.isAutomaticSpellingCorrectionEnabled = false // no silent auto-replace
        textView.isContinuousSpellCheckingEnabled = true // red squiggles on typos
        textView.isGrammarCheckingEnabled = true
        textView.typingAttributes = Self.userAttrs
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        (textView as? FocusReportingTextView)?.onFocus = onFocus

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

/// Auto-growing, bordered prompt text field used across the params panels.
///
/// An invisible `Text` drives the height: it grows with content (`fixedSize`
/// vertical), and the `InsetTextEditor` overlays it exactly. When `ghostSuffix`
/// is non-empty (template-contributed text), it is shown after the editable
/// content in tertiary color and the border switches to accent.
struct GrowingPromptField: View {
    @Binding var text: String
    var placeholder: String
    var label: String
    var hint: String
    var ghostSuffix: String = ""
    var minHeight: CGFloat = 60
    /// Estimated-token soft cap. When set, a live token counter is shown beneath the
    /// field, and an info icon explaining backend truncation appears once exceeded.
    var tokenSoftCap: Int?
    /// Called when the underlying editor gains first-responder focus.
    var onFocus: (() -> Void)?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            editor
            if let cap = tokenSoftCap {
                tokenCounter(cap: cap)
            }
        }
    }

    private var editor: some View {
        let displayText = text + ghostSuffix
        return Text(displayText.isEmpty ? " " : displayText)
            .font(.body)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: minHeight)
            .opacity(0)
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                InsetTextEditor(
                    text: $text, insets: NSSize(width: 5, height: 8),
                    ghostSuffix: ghostSuffix, onFocus: onFocus
                )
            }
            .overlay(alignment: .topLeading) {
                // Hide placeholder when ghost text is present — ghost is more informative.
                if text.isEmpty && ghostSuffix.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .font(.body)
                        .padding(.leading, 5)
                        .padding(.trailing, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        ghostSuffix.isEmpty ? Color.secondary.opacity(0.25) : Color.accentColor.opacity(0.4),
                        lineWidth: 1
                    )
            )
            .accessibilityLabel(label)
            .accessibilityHint(hint)
    }

    /// Live token estimate with a soft cap. Counts the combined user + ghost (template)
    /// text since both are sent to the encoder. The info icon stays hidden until the
    /// estimate exceeds the cap, then explains what truncation does to a submitted prompt.
    @ViewBuilder
    private func tokenCounter(cap: Int) -> some View {
        let count = PromptTokenEstimator.estimate(text + ghostSuffix)
        let over = count > cap
        let near = Double(count) >= Double(cap) * 0.9
        HStack(spacing: 4) {
            if over {
                InfoButton(
                    title: "Prompt may be truncated",
                    description: "This model encodes prompts up to about \(cap) tokens. Text beyond "
                        + "that is dropped before it reaches the model, so trailing details may be "
                        + "ignored if you submit as-is. The encoder also reads tokens in order — put "
                        + "the most important content first. This is an estimate; the actual tokenizer "
                        + "may differ slightly."
                )
            }
            Text("~\(count) / \(cap) tokens")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(over ? Color.red : (near ? Color.orange : Color.secondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Estimated \(count) of \(cap) tokens" + (over ? ", over the limit — prompt may be truncated" : "")
        )
    }
}

// MARK: - Spell-checked single-line field

/// A single-line text field that shows spell/grammar squiggles.
///
/// SwiftUI's macOS `TextField` (an `NSTextField`) borrows the window's shared
/// field editor, which has continuous spell checking off here — and there's no
/// SwiftUI modifier to flip it. This wraps an `NSTextField` that enables spell
/// + grammar checking on its field editor whenever it gains focus. Styled to
/// match `.textFieldStyle(.roundedBorder)`.
struct SpellCheckingTextField: NSViewRepresentable {
    final class Field: NSTextField {
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if let editor = currentEditor() as? NSTextView {
                editor.isContinuousSpellCheckingEnabled = true
                editor.isGrammarCheckingEnabled = true
            }
            return ok
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SpellCheckingTextField

        init(_ parent: SpellCheckingTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }

    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.delegate = context.coordinator
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.font = .preferredFont(forTextStyle: .callout)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}
