@testable import MLXBits_Image_Studio
import Testing

/// Donation links (spec §5): Ko-fi in the DMG, GitHub only once approved, and
/// none at all in the App Store build.
struct SupportLinksTests {
    @Test func theAppStoreBuildShowsNoLinks() {
        #expect(SupportLinks.visible(isAppStore: true, gitHubSponsorsApproved: true).isEmpty)
        #expect(SupportLinks.visible(isAppStore: true, gitHubSponsorsApproved: false).isEmpty)
    }

    @Test func theDMGShowsKoFiAndGitHubOnceApproved() {
        #expect(SupportLinks.visible(isAppStore: false, gitHubSponsorsApproved: false).map(\.url.absoluteString)
            == ["https://ko-fi.com/mlxbits"])
        #expect(SupportLinks.visible(isAppStore: false, gitHubSponsorsApproved: true).map(\.url.absoluteString)
            == ["https://ko-fi.com/mlxbits", "https://github.com/sponsors/MLXBits"])
    }

    @Test func gitHubSponsorsStaysHiddenUntilApproved() {
        #expect(!SupportLinks.gitHubSponsorsApproved)
    }
}
