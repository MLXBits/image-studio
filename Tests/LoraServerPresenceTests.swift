@testable import MLXBits_Image_Studio
import Testing

/// A server LoRA becomes removable only when the configured server's discovery pass no longer lists it.
struct LoraServerPresenceTests {
    private let server = LibraryLora(name: "Style", path: "qwen/style.safetensors", isServerLoRA: true)
    private let serverA = "http://a:8188"

    private func inventory(_ names: Set<String>, at url: String = "http://a:8188") -> LoraLibraryStore.ServerLoraInventory {
        .init(baseURL: url, names: names)
    }

    private func gone(_ entry: LibraryLora, _ inventory: LoraLibraryStore.ServerLoraInventory?, configured: String) -> Bool {
        LoraLibraryStore.isGoneFromServer(entry, inventory: inventory, configuredURL: configured)
    }

    @Test func noDiscoveryYetMeansNothingIsGone() {
        #expect(!gone(server, nil, configured: serverA))
    }

    @Test func listedServerLoraIsNotGone() {
        #expect(!gone(server, inventory(["qwen/style.safetensors"]), configured: serverA))
    }

    @Test func unlistedServerLoraIsGone() {
        #expect(gone(server, inventory(["qwen21/style.safetensors"]), configured: serverA))
        #expect(gone(server, inventory([]), configured: serverA))
    }

    @Test func localLoraIsNeverGone() {
        let local = LibraryLora(name: "Local", path: "/loras/local.safetensors")
        #expect(!gone(local, inventory([]), configured: serverA))
    }

    /// After the URL moves from A to B, A's list says nothing about B until B's own discovery succeeds.
    @Test func anotherServersInventoryIsIgnored() {
        #expect(!gone(server, inventory([]), configured: "http://b:8188"))
    }

    @Test func clearedURLIgnoresTheInventory() {
        #expect(!gone(server, inventory([]), configured: ""))
    }
}
