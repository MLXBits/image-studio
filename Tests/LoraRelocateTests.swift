import Foundation
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

    /// Two library entries can name one file; both follow it, as stacks do.
    @Test func everyEntryForTheLostFileFollowsIt() {
        let entry = LibraryLora(name: "Style", path: "/old/style.safetensors")
        let twin = LibraryLora(name: "Style, softer", path: "/old/style.safetensors", defaultStrength: 0.5)
        let next = LoraLibraryStore.relocating(
            entry.id, to: "/new/style.safetensors", library: [entry, twin], stacks: []
        )

        #expect(next.library.map(\.path) == ["/new/style.safetensors", "/new/style.safetensors"])
    }

    /// Deleting a library LoRA drops it from every stack, unless a twin entry still catalogs the same file.
    @Test func deletingAnEntryPrunesItFromStacks() {
        let entry = LibraryLora(name: "Style", path: "/a/style.safetensors")
        let other = LibraryLora(name: "Other", path: "/a/other.safetensors")
        let stack = LoraStack(
            name: "Combo",
            loras: [LoraEntry(path: "/a/style.safetensors"), LoraEntry(path: "/a/other.safetensors")]
        )

        let next = LoraLibraryStore.deleting(entry.id, library: [entry, other], stacks: [stack])
        #expect(next.library.map(\.path) == ["/a/other.safetensors"])
        #expect(next.stacks[0].loras.map(\.path) == ["/a/other.safetensors"])

        let twin = LibraryLora(name: "Style, softer", path: "/a/style.safetensors", defaultStrength: 0.5)
        let kept = LoraLibraryStore.deleting(entry.id, library: [entry, twin], stacks: [stack])
        #expect(kept.stacks[0].loras.count == 2)
    }

    /// A default LoRA located again in Settings moves in this generation too,
    /// rather than the new file joining the lost one.
    @Test func aLocatedDefaultMovesInThisGeneration() {
        let id = UUID()
        let active = [LoraEntry(path: "/old/style.safetensors", strength: 0.7)]
        let next = LoraLibraryStore.followingDefaults(
            active,
            from: [LoraEntry(id: id, path: "/old/style.safetensors")],
            to: [LoraEntry(id: id, path: "/new/style.safetensors")]
        )

        #expect(next.map(\.path) == ["/new/style.safetensors"])
        #expect(next.first?.strength == 0.7)
    }
}
