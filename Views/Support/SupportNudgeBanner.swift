import SwiftUI

/// The one-time support nudge under the top bar (spec §5). Either button
/// retires it for good.
struct SupportNudgeBanner: View {
    @Environment(SupportStore.self) private var support
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if support.showsNudge {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.caption)
                Text(SupportNudge.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("No Thanks") { support.retireNudge() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button("Leave a Tip…") {
                    support.retireNudge()
                    openWindow(id: SupportView.windowID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
