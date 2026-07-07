@testable import MLXBits_Image_Studio
import Testing

/// Covers the semantic version comparison that drives the update badge: numeric,
/// component-wise, and tolerant of a leading "v" and pre-release suffixes.
@MainActor
struct UpdateCheckerTests {
    @Test func newerPatchIsAnUpdate() {
        #expect(UpdateChecker.compare("v0.6.4", isNewerThan: "0.6.2"))
    }

    @Test func sameVersionIsNotAnUpdate() {
        #expect(!UpdateChecker.compare("v0.6.4", isNewerThan: "0.6.4"))
    }

    @Test func olderVersionIsNotAnUpdate() {
        #expect(!UpdateChecker.compare("0.6.2", isNewerThan: "v0.6.4"))
    }

    @Test func comparesComponentsNumericallyNotLexically() {
        #expect(UpdateChecker.compare("v0.6.10", isNewerThan: "0.6.9"))
    }

    @Test func majorAndMinorBumpsAreUpdates() {
        #expect(UpdateChecker.compare("v1.0.0", isNewerThan: "0.9.9"))
        #expect(UpdateChecker.compare("v0.7.0", isNewerThan: "0.6.9"))
    }

    @Test func ignoresPreReleaseSuffix() {
        #expect(UpdateChecker.compare("v0.6.4-rc1", isNewerThan: "0.6.3"))
    }

    @Test func missingTrailingComponentsTreatedAsZero() {
        #expect(!UpdateChecker.compare("v0.6", isNewerThan: "0.6.0"))
        #expect(UpdateChecker.compare("v0.6.1", isNewerThan: "0.6"))
    }
}
