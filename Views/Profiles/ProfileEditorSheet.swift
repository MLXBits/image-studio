import SwiftUI

/// New Profile (name + library folder) and Rename (name only).
struct ProfileEditorSheet: View {
    enum Mode: Identifiable {
        case create
        case rename(Profile)

        var id: String {
            switch self {
            case .create: "create"
            case let .rename(profile): "rename-\(profile.id)"
            }
        }
    }

    let mode: Mode
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var libraryPath = ""
    @State private var submitError: String?

    private var isCreate: Bool {
        if case .create = mode {
            return true
        }
        return false
    }

    private var editingID: UUID? {
        if case let .rename(profile) = mode {
            return profile.id
        }
        return nil
    }

    private var nameProblem: String? {
        ProfileRules.nameProblem(name, profiles: profiles.profiles, excluding: editingID)?.message
    }

    private var libraryProblem: String? {
        isCreate ? profiles.libraryProblem(for: libraryPath, excluding: nil) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isCreate ? "New Profile" : "Rename Profile")
                .font(.headline)

            if isCreate {
                Text("A profile has its own library folder, notepad, prompt history, templates and queue. "
                    + "Models and LoRAs are shared.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Name") {
                TextField("e.g. Work", text: $name)
                    .textFieldStyle(.roundedBorder)
                // An untouched empty field isn't an error yet; Create stays disabled.
                problem(name.isEmpty ? nil : nameProblem)
            }

            if isCreate {
                field("Library folder") {
                    PathField(
                        placeholder: BuildFlavor.isAppStore ? "No folder chosen" : "/path/to/folder",
                        path: $libraryPath
                    ) { browse() }
                    problem(libraryPath.isEmpty ? nil : libraryProblem)
                }
                if let reason = profiles.switchBlockReason {
                    Text("You can switch to it once the queue is empty. \(reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            problem(submitError)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreate ? "Create" : "Rename") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem != nil || libraryProblem != nil)
            }
        }
        .padding()
        .frame(width: 460)
    }

    init(mode: Mode) {
        self.mode = mode
        if case let .rename(profile) = mode {
            _name = State(initialValue: profile.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func problem(_ message: String?) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func browse() {
        if let path = LibraryFolderPanel.choose(
            title: "Choose Library Folder",
            message: "Images for this profile will be saved here. Pick or create an empty folder.",
            near: profiles.activeProfile?.libraryPath,
            access: profiles.fileAccess
        ) {
            libraryPath = path
        }
    }

    private func submit() {
        switch mode {
        case .create:
            switch profiles.createProfile(name: name, libraryPath: libraryPath) {
            case let .success(id):
                let canSwitch = profiles.switchBlockReason == nil
                dismiss()
                if canSwitch {
                    // After the sheet is gone: the switch rebuilds the window.
                    Task { @MainActor in profiles.requestSwitch(to: id) }
                }
            case let .failure(error):
                submitError = error.message
            }
        case let .rename(profile):
            if let error = profiles.renameProfile(profile.id, to: name) {
                submitError = error.message
            } else {
                dismiss()
            }
        }
    }
}
