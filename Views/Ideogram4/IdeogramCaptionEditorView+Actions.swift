import AppKit
import SwiftUI

/// Caption mutation and JSON-copy/reset actions for `IdeogramCaptionEditorView`.
/// Only methods that touch the (non-private) `@Binding` caption state live here;
/// actions that mutate the view's private `@State` stay in the main file, since
/// Swift `private` is file-scoped.
extension IdeogramCaptionEditorView {
    // MARK: - Style mutation

    func enterPhotoMode() {
        if caption.styleDescription == nil { caption.styleDescription = IdeogramCaptionStyle() }
        caption.styleDescription?.artStyle = nil
        if caption.styleDescription?.photo == nil { caption.styleDescription?.photo = "" }
        if (caption.styleDescription?.medium ?? "").isEmpty { caption.styleDescription?.medium = "photograph" }
    }

    func enterArtStyleMode() {
        if caption.styleDescription == nil { caption.styleDescription = IdeogramCaptionStyle() }
        caption.styleDescription?.photo = nil
    }

    func setStyle(_ kp: WritableKeyPath<IdeogramCaptionStyle, String?>, _ value: String) {
        if caption.styleDescription == nil {
            caption.styleDescription = IdeogramCaptionStyle()
        }
        caption.styleDescription?[keyPath: kp] = value.isEmpty ? nil : value
    }

    // MARK: - Clipboard / reset

    /// Copies the exact caption payload (the JSON handed to mflux) to the clipboard.
    /// In plain-text mode there is no structured payload, so the prompt text is copied.
    func copyJSON() {
        let payload = usePlainPrompt ? plainPrompt : (caption.toPrettyJSON() ?? "")
        guard !payload.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    func resetCaption() {
        caption.highLevelDescription = ""
        caption.styleDescription = nil
        caption.compositionalDeconstruction.background = ""
        caption.compositionalDeconstruction.elements = []
        plainPrompt = ""
    }
}
