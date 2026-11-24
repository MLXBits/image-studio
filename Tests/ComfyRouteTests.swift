import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// ``AppSettings/runsOnComfy(_:)`` matches the runner: the model button and the ComfyUI pill
/// say "ComfyUI" only when a job would actually run there.
struct ComfyRouteTests {
    private func settings(routed: [ModelFamily], url: String = "http://comfy-host:8188") -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.comfyURL = url
        // `AppSettings()` may load ambient settings: start with no server files.
        settings.comfyUNet = [:]
        settings.comfyClip = [:]
        settings.comfyVae = [:]
        settings.comfyBackendEnabled = Dictionary(uniqueKeysWithValues: ModelFamily.allCases.map {
            ($0.id, routed.contains($0))
        })
        return settings
    }

    private func setFiles(_ settings: AppSettings, key: String) {
        settings.comfyUNet[key] = "unet.safetensors"
        settings.comfyClip[key] = "clip.safetensors"
        settings.comfyVae[key] = "vae.safetensors"
    }

    @Test func flux3RunsLocallyEvenWithTheBackendSetToComfyUI() {
        let s = settings(routed: [.flux])
        setFiles(s, key: FluxModelVariant.flux3Klein.rawValue)
        #expect(!s.runsOnComfy(.flux3Klein))
        #expect(!s.runsOnComfy(.flux3KleinBase))
    }

    @Test func flux2RunsOnComfyUIOnlyWithAllThreeFilesForItsVariant() {
        let s = settings(routed: [.flux])
        #expect(!s.runsOnComfy(.flux2Klein4B))
        setFiles(s, key: FluxModelVariant.flux2Klein4B.rawValue)
        #expect(s.runsOnComfy(.flux2Klein4B))
        #expect(!s.runsOnComfy(.flux2Klein9B))
        s.comfyVae[FluxModelVariant.flux2Klein4B.rawValue] = ""
        #expect(!s.runsOnComfy(.flux2Klein4B))
    }

    @Test func familyFilesRouteKrea2AndQwen() {
        let s = settings(routed: [.krea2, .qwen21])
        #expect(!s.runsOnComfy(.krea2))
        setFiles(s, key: ModelFamily.krea2.id)
        setFiles(s, key: ModelFamily.qwen21.id)
        #expect(s.runsOnComfy(.krea2))
        #expect(s.runsOnComfy(.qwen21Turbo))
    }

    @Test func theBackendSegmentAndAURLAreBothNeeded() {
        let off = settings(routed: [])
        setFiles(off, key: ModelFamily.krea2.id)
        #expect(!off.runsOnComfy(.krea2))
        let noURL = settings(routed: [.krea2], url: "  ")
        setFiles(noURL, key: ModelFamily.krea2.id)
        #expect(!noURL.runsOnComfy(.krea2))
    }

    @Test func familiesWithoutARemoteGraphRunLocally() {
        let s = settings(routed: [.zimage, .ideogram4])
        #expect(!s.runsOnComfy(.zimageTurbo))
        #expect(!s.runsOnComfy(.ideogram4))
    }
}
