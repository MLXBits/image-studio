import SwiftUI

/// Shown for the moment between tearing down the outgoing profile's window
/// content and building the incoming one. Its `.task` runs only after the old
/// views are gone — so their `onDisappear` saves landed in the old profile —
/// and finishes the switch.
struct ProfileSwitchingView: View {
    @Environment(ProfileStore.self) private var profiles

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { profiles.completePendingSwitch() }
    }
}

/// Shown instead of the app when the profile list can't be read. Nothing is
/// written in this state, so fixing or moving the file aside and relaunching
/// loses nothing.
struct ProfileUnavailableView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Profiles unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([ProfilePaths.live.registry])
            }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
