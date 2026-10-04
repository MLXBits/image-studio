import SwiftUI

/// A profile action the toolbar menu asks ``ContentView`` to present.
enum ProfileAction: Identifiable {
    case create
    case rename(Profile)
    case remove(Profile)

    var id: String {
        switch self {
        case .create: "create"
        case let .rename(profile): "rename-\(profile.id)"
        case let .remove(profile): "remove-\(profile.id)"
        }
    }
}

/// The toolbar's profile switcher: the active profile's name, a one-click list
/// of profiles, and New / Rename / Remove. Rename and Remove act on the active
/// profile — you change the profile you're in.
struct ProfileMenu: View {
    @Environment(ProfileStore.self) private var profiles
    var onAction: (ProfileAction) -> Void
    var onShowQueue: () -> Void

    var body: some View {
        let blockReason = profiles.switchBlockReason
        Menu {
            // Inline Picker inside a Menu, as in ModelPickerView: native
            // checkmark on the active profile, one click to switch.
            Picker("Profile", selection: Binding(
                get: { profiles.activeProfileID },
                set: { id in
                    if let id {
                        profiles.requestSwitch(to: id)
                    }
                }
            )) {
                ForEach(profiles.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.inline)
            .disabled(blockReason != nil)
            if let blockReason {
                Text(blockReason)
                Button("Show Queue") { onShowQueue() }
            }
            Divider()
            Button("New Profile…") { onAction(.create) }
            if let active = profiles.activeProfile {
                Button("Rename “\(active.name)”…") { onAction(.rename(active)) }
                // Not for the default profile, which removal falls back to.
                Button("Remove “\(active.name)”…") { onAction(.remove(active)) }
                    .disabled(!profiles.canRemoveActiveProfile)
            }
        } label: {
            Label(profiles.activeProfile?.name ?? "Profile", systemImage: "person.crop.circle")
                .labelStyle(.titleAndIcon)
        }
        .help("Switch profile — each has its own library, notepad, prompt history and queue")
    }
}
