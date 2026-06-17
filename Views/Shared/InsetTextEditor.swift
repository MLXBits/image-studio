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
        textView.isAutomaticSpellingCorrectionEnabled = false // no silent auto-replace
        textView.isContinuousSpellCheckingEnabled = true // red squiggles on typos
        textView.isGrammarCheckingEnabled = true
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

    var body: some View {
        let displayText = text + ghostSuffix
        Text(displayText.isEmpty ? " " : displayText)
            .font(.body)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: minHeight)
            .opacity(0)
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                InsetTextEditor(text: $text, insets: NSSize(width: 5, height: 8), ghostSuffix: ghostSuffix)
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
}

// MARK: - Color palette editor

/// Inline hex-color palette editor: each entry is a circular swatch (click to
/// open the system color picker) with its hex shown alongside. "Add color"
/// appends a new entry and opens the picker for it.
struct ColorPaletteEditor: View {
    @Binding var colors: [String]

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 6, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !colors.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { idx, hex in
                        chip(idx: idx, hex: hex)
                    }
                }
            }
            Button {
                let idx = colors.count
                colors.append("#808080")
                editColor(at: idx)
            } label: {
                Label("Add color", systemImage: "plus.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a color")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(idx: Int, hex: String) -> some View {
        HStack(spacing: 4) {
            Button {
                editColor(at: idx)
            } label: {
                Circle()
                    .fill(Color(hexString: hex) ?? .black)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Edit color")
            Text(hex.uppercased().replacingOccurrences(of: "#", with: ""))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Button {
                guard colors.indices.contains(idx) else { return }
                colors.remove(at: idx)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove color")
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
        .help(hex.uppercased())
    }

    /// Opens the shared system color panel seeded with the entry at `idx`,
    /// writing each live change back into the palette.
    private func editColor(at idx: Int) {
        guard colors.indices.contains(idx) else { return }
        ColorPanelController.shared.present(initial: Color(hexString: colors[idx]) ?? .black) { picked in
            if colors.indices.contains(idx) { colors[idx] = picked.hexString }
        }
    }
}

// MARK: - Color panel controller

/// Bridges the shared `NSColorPanel` to a SwiftUI callback so a custom swatch
/// button can present the native picker. Re-targeting on each present means
/// only the most recently opened swatch receives updates.
@MainActor
final class ColorPanelController: NSObject {
    static let shared = ColorPanelController()

    private var onChange: ((Color) -> Void)?

    func present(initial: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color))
    }
}

// MARK: - Hex <-> Color

extension Color {
    /// Renders as `#RRGGBB` in sRGB.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parses `#RRGGBB` (with or without the leading `#`). Returns nil on bad input.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
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
