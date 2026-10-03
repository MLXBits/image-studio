import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers the on-disk profile registry (`profiles.json`) and the switch gate.
struct ProfileRegistryTests {
    private let workID = UUID()
    private let homeID = UUID()

    @Test func decodesARegistryWrittenByAFutureBuildWithExtraKeys() throws {
        let json = """
        {
          "activeProfileID": "22222222-2222-2222-2222-222222222222",
          "schema": 7,
          "profiles": [
            {"id": "11111111-1111-1111-1111-111111111111", "name": "Work", "libraryPath": "/w", "color": "red"},
            {"id": "22222222-2222-2222-2222-222222222222", "name": "Home", "libraryPath": "/h"}
          ]
        }
        """
        let registry = try JSONDecoder().decode(ProfileRegistry.self, from: Data(json.utf8))
        #expect(registry.activeProfile?.name == "Home")
        #expect(registry.profiles.map(\.libraryPath) == ["/w", "/h"])
    }

    /// A stale active ID (e.g. the active profile's entry was hand-deleted)
    /// must still leave the app with a usable profile rather than none.
    @Test func staleActiveIDFallsBackToFirstProfile() {
        let registry = ProfileRegistry(
            activeProfileID: UUID(),
            profiles: [
                Profile(id: workID, name: "Work", libraryPath: "/w"),
                Profile(id: homeID, name: "Home", libraryPath: "/h"),
            ]
        )
        #expect(registry.activeProfile?.id == workID)
    }

    @Test func emptyRegistryHasNoActiveProfile() {
        #expect(ProfileRegistry(activeProfileID: workID, profiles: []).activeProfile == nil)
    }

    // MARK: - Switch gate

    @Test func idleQueueAllowsSwitching() {
        #expect(ProfileSwitchGate.blockReason(isGenerating: false, queuedCount: 0) == nil)
    }

    @Test func runningGenerationBlocksSwitching() {
        #expect(ProfileSwitchGate.blockReason(isGenerating: true, queuedCount: 0) != nil)
    }

    /// Pending jobs saved by a previous session never auto-start, so the reason
    /// must tell the user how many are sitting in the queue.
    @Test func queuedJobsBlockSwitchingAndAreCounted() throws {
        let reason = try #require(ProfileSwitchGate.blockReason(isGenerating: false, queuedCount: 3))
        #expect(reason.contains("3"))
    }
}
