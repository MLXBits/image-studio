import SwiftUI

/// The gallery's failure and refusal alerts — delete, protected image, move and
/// metadata strip — each shown while its message on ``GalleryStore`` is set and
/// cleared when dismissed. Kept out of ``GenerationGalleryView``'s body, whose
/// modifier chain is already near the type checker's limit.
struct GalleryErrorAlerts: ViewModifier {
    @Environment(GalleryStore.self) private var gallery

    func body(content: Content) -> some View {
        @Bindable var gallery = gallery
        content
            .errorAlert("Could not delete", message: $gallery.deleteError)
            .errorAlert("Image protected", message: $gallery.lockError)
            .errorAlert("Could not move", message: $gallery.moveError)
            .errorAlert("Could not strip metadata", message: $gallery.stripError)
    }
}

private extension View {
    /// An OK-only alert shown while `message` is non-nil; dismissing it clears `message`.
    func errorAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: {
                if !$0 {
                    message.wrappedValue = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
