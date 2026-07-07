import AppKit
import SwiftUI

/// Custom About panel. Shows the running version and, on appear, checks GitHub
/// for the latest release so the user can see at a glance whether they're current.
struct AboutView: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            VStack(spacing: 4) {
                Text("MLXBits Image Studio")
                    .font(.title2.bold())
                // Debug builds carry the in-repo MARKETING_VERSION, which trails
                // the latest tag, so the number (and any update check against it)
                // would be misleading. Show a neutral "Development Build" instead.
                #if DEBUG
                    Text("Development Build")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                #else
                    Text("Version \(updates.currentVersion)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                #endif
            }

            #if !DEBUG
                Divider()
                updateStatus
            #endif

            Text("© MLXBits")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 360)
        #if !DEBUG
            .task { await updates.check() }
        #endif
    }

    @ViewBuilder
    private var updateStatus: some View {
        if updates.isChecking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if updates.isUpdateAvailable {
            VStack(spacing: 10) {
                Label("Version \(updates.latestVersion ?? "") is available", systemImage: "arrow.down.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                Button {
                    if let url = updates.releaseURL { openURL(url) }
                } label: {
                    Text("View Release")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(updates.releaseURL == nil)
            }
        } else if let error = updates.lastError {
            VStack(spacing: 8) {
                Label("Couldn't check for updates", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await updates.check() } }
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("You're up to date")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
