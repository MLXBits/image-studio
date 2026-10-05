@testable import MLXBits_Image_Studio
import Testing

/// Locate… on a LoRA whose file was lost points its library entry at the new
/// file, and every saved stack that used the old path follows it.
struct LoraRelocateTests {
    @Test func locatingMovesTheEntryAndTheStacksThatUseIt() {
        let entry = LibraryLora(name: "Style", path: "/old/style.safetensors")
        let other = LibraryLora(name: "Other", path: "/old/other.safetensors")
        let stack = LoraStack(
            name: "Combo",
            loras: [LoraEntry(path: "/old/style.safetensors"), LoraEntry(path: "/old/other.safetensors")]
        )

        let next = LoraLibraryStore.relocating(
            entry.id, to: "/new/style.safetensors", library: [entry, other], stacks: [stack]
        )

        #expect(next.library.map(\.path) == ["/new/style.safetensors", "/old/other.safetensors"])
        #expect(next.stacks[0].loras.map(\.path) == ["/new/style.safetensors", "/old/other.safetensors"])
    }
}
