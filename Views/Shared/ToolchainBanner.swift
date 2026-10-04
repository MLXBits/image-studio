import SwiftUI

/// Shown under the top bar when Python can't run: a build without its runtime,
/// or a Custom Python that no longer exists. Generation fails until it's fixed.
struct ToolchainBanner: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let problem = settings.toolchain.problem {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(problem.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if case .customPythonMissing = problem {
                    Button("Open Settings") {
                        openSettings()
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .openSettingsAdvancedTab, object: nil)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
