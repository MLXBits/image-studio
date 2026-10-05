import SwiftUI

/// The Support window (spec §5), opened from the app menu, Settings and the
/// nudge. Opening it retires the nudge.
struct SupportView: View {
    static let windowID = "support"
    static let intro = "Every feature is free. Tips don't unlock anything; they just help keep the project going."

    @Environment(SupportStore.self) private var support

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.pink)
            Text("Support MLXBits Image Studio")
                .font(.title3.bold())
            Text(Self.intro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if BuildFlavor.isAppStore {
                TipJarSection()
            } else {
                DonationLinksSection()
            }
        }
        .padding(28)
        .frame(width: 400)
        .onAppear { support.noteWindowOpened() }
    }
}
