import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The header's ComfyUI pill and its poll follow ``AppSettings/activeComfyURL``: a configured server
/// counts only while at least one family routes to it.
struct ActiveComfyURLTests {
    private func settings(url: String, routed: [ModelFamily]) -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.comfyURL = url
        settings.comfyBackendEnabled = Dictionary(uniqueKeysWithValues: ModelFamily.allCases.map {
            ($0.id, routed.contains($0))
        })
        return settings
    }

    @Test func noFamilyRoutedMeansNoActiveServer() {
        #expect(settings(url: "http://comfy-host:8188", routed: []).activeComfyURL == nil)
    }

    @Test func oneRoutedFamilyActivatesTheServer() {
        let s = settings(url: " http://comfy-host:8188 ", routed: [.seedvr2])
        #expect(s.activeComfyURL == "http://comfy-host:8188")
    }

    @Test func routedFamilyWithoutAURLIsInactive() {
        #expect(settings(url: "  ", routed: [.krea2]).activeComfyURL == nil)
    }
}
