import SwiftUI

/// The DMG's donation links: Ko-fi, and GitHub Sponsors once approved.
struct DonationLinksSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SupportLinks.visible(
                isAppStore: BuildFlavor.isAppStore,
                gitHubSponsorsApproved: SupportLinks.gitHubSponsorsApproved
            )) { link in
                Button(link.title) { openURL(link.url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
