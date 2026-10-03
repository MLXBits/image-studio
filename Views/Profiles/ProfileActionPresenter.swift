import SwiftUI

/// Presents what the profile menu asks for: the New / Rename sheet, the Remove
/// confirmation, and profile-list save errors. A modifier so ContentView's
/// long modifier chains gain one line.
struct ProfileActionPresenter: ViewModifier {
    @Environment(ProfileStore.self) private var profiles
    @Binding var action: ProfileAction?

    private var editor: Binding<ProfileEditorSheet.Mode?> {
        Binding(
            get: {
                switch action {
                case .create: .create
                case let .rename(profile): .rename(profile)
                default: nil
                }
            },
            set: {
                if $0 == nil {
                    action = nil
                }
            }
        )
    }

    private var removing: Profile? {
        if case let .remove(profile) = action {
            return profile
        }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: editor) { mode in
                ProfileEditorSheet(mode: mode)
                    .environment(profiles)
            }
            .confirmationDialog(
                "Remove “\(removing?.name ?? "")”?",
                isPresented: Binding(get: { removing != nil }, set: {
                    if !$0 {
                        action = nil
                    }
                }),
                titleVisibility: .visible,
                presenting: removing
            ) { profile in
                Button("Remove Profile", role: .destructive) { profiles.removeProfile(profile.id) }
                Button("Cancel", role: .cancel) {}
            } message: { profile in
                Text(removalMessage(for: profile))
            }
            .alert("Profile error", isPresented: Binding(
                get: { profiles.lastError != nil },
                set: {
                    if !$0 {
                        profiles.lastError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(profiles.lastError ?? "")
            }
    }

    private func removalMessage(for profile: Profile) -> String {
        let removed = "Its notepad, prompt history, templates, drafts and job history will be deleted."
        guard !profile.libraryPath.isEmpty else { return removed }
        return removed + " The library folder and all its generated images stay on disk at:\n\(profile.libraryPath)"
    }
}
