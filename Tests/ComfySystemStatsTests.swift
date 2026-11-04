import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// ``ComfyUIClient/parseSystemStats(_:)`` against `/system_stats` bodies shaped like ComfyUI's
/// `server.py`: a `system` object and a `devices` list with the primary device first.
@Suite("ComfyUIClient.parseSystemStats")
struct ComfySystemStatsTests {
    private func parse(_ body: String) throws -> ComfyUIClient.SystemStats {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        return ComfyUIClient.parseSystemStats(json)
    }

    @Test func readsVersionAndOSFromSystem() throws {
        let stats = try parse(#"{"system": {"comfyui_version": "0.3.60", "os": "linux"}, "devices": []}"#)
        #expect(stats.serverVersion == "0.3.60")
        #expect(stats.os == "linux")
    }

    @Test func vramComesFromThePrimaryDeviceOnly() throws {
        let stats = try parse(#"""
        {"system": {}, "devices": [
            {"name": "cuda:0 RTX 5090", "vram_total": 34359738368, "vram_free": 8589934592},
            {"name": "cuda:1 RTX 3060", "vram_total": 12884901888, "vram_free": 12000000000}
        ]}
        """#)
        #expect(stats.gpuNames == ["cuda:0 RTX 5090", "cuda:1 RTX 3060"])
        #expect(stats.vramTotalBytes == 34_359_738_368)
        #expect(stats.vramFreeBytes == 8_589_934_592)
        #expect(stats.vramTotalGb == 32)
    }

    @Test func aFieldMissingOnThePrimaryIsNotTakenFromAnotherDevice() throws {
        let stats = try parse(#"""
        {"system": {}, "devices": [
            {"name": "cuda:0", "vram_total": 34359738368},
            {"name": "cuda:1", "vram_total": 12884901888, "vram_free": 12000000000}
        ]}
        """#)
        #expect(stats.vramTotalBytes == 34_359_738_368)
        #expect(stats.vramFreeBytes == nil)
    }

    @Test func fallsBackToTorchFreeOnThePrimary() throws {
        let stats = try parse(#"{"devices": [{"name": "mps", "vram_total": 100, "torch_vram_free": 40}]}"#)
        #expect(stats.vramFreeBytes == 40)
    }

    @Test func noDevicesLeavesVRAMUnset() throws {
        let stats = try parse(#"{"system": {"os": "darwin"}}"#)
        #expect(stats.gpuNames.isEmpty)
        #expect(stats.vramTotalBytes == nil)
        #expect(stats.vramFreeBytes == nil)
    }
}

/// ``ComfyUIClient/Config`` normalizes its base URL for every caller, not only the ones that
/// remember to call ``ComfyUIClient/Config/normalize(_:)`` first.
@Suite("ComfyUIClient.Config")
struct ComfyConfigTests {
    @Test func trailingSlashesAndWhitespaceAreStripped() {
        #expect(ComfyUIClient.Config(baseURL: " http://host:8188/ ").baseURL == "http://host:8188")
        #expect(ComfyUIClient.Config(baseURL: "http://host/comfy//").baseURL == "http://host/comfy")
        #expect(ComfyUIClient.Config(baseURL: "http://host:8188").baseURL == "http://host:8188")
    }
}
