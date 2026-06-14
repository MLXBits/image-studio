import AppKit
import SwiftUI

/// A numeric text field that never becomes first responder via tab or programmatic
/// responder search — only responds to direct mouse clicks. Prevents accidental
/// focus capture when nearby plain-style buttons are clicked.
struct PassiveTextField<F: ParseableFormatStyle>: NSViewRepresentable
    where F.FormatOutput == String {
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PassiveTextField
        init(_ parent: PassiveTextField) {
            self.parent = parent
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if let parsed = try? parent.format.parseStrategy.parse(field.stringValue) {
                parent.value = parsed
            } else {
                // revert to current value on bad input
                field.stringValue = parent.format.format(parent.value)
            }
            parent.onSubmit?()
        }
    }

    @Binding var value: F.FormatInput
    let format: F
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> PassiveNSTextField {
        let field = PassiveNSTextField()
        field.delegate = context.coordinator
        field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.focusRingType = .none
        return field
    }

    func updateNSView(_ field: PassiveNSTextField, context _: Context) {
        let formatted = format.format(value)
        if field.stringValue != formatted, !field.isEditing {
            field.stringValue = formatted
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}

final class PassiveNSTextField: NSTextField {
    var isEditing: Bool = false

    override var acceptsFirstResponder: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        // Allow click-to-edit by manually becoming first responder on click
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func textDidBeginEditing(_ notification: Notification) {
        isEditing = true
        super.textDidBeginEditing(notification)
    }

    override func textDidEndEditing(_ notification: Notification) {
        isEditing = false
        super.textDidEndEditing(notification)
    }
}
