import Foundation

/// The DMG's donation links (spec §5). The App Store build shows none: outside
/// the US storefront, links to other payment methods break Apple's rules.
nonisolated enum SupportLinks {
    struct Link: Identifiable, Equatable {
        let title: String
        let url: URL

        var id: String {
            url.absoluteString
        }
    }

    /// Flip once GitHub approves the MLXBits Sponsors profile.
    static let gitHubSponsorsApproved = false

    static let koFi = Link(title: "Support on Ko-fi", url: URL(string: "https://ko-fi.com/mlxbits")!)
    static let gitHubSponsors = Link(title: "Sponsor on GitHub", url: URL(string: "https://github.com/sponsors/MLXBits")!)

    static func visible(isAppStore: Bool, gitHubSponsorsApproved: Bool) -> [Link] {
        guard !isAppStore else { return [] }
        return gitHubSponsorsApproved ? [koFi, gitHubSponsors] : [koFi]
    }
}
