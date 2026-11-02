@testable import MLXBits_Image_Studio
import Testing

/// Tests for ``resolverServerLoraName`` — the rule that maps a LoRA's `path` to the exact value a ComfyUI
/// `LoraLoader.lora_name` node accepts. This is the contract the remote Krea 2 workflow relies on: a
/// server-cataloged entry must be submitted *verbatim* (subfolder prefix included) or the node fails with
/// "lora not found", while an absolute local file path still resolves to its top-level filename.
@Suite("resolverServerLoraName")
struct ComfyLoraNameResolutionTests {
    @Test func serverRelativeBareNamePassesVerbatim() {
        // A top-level server LoRA has no subfolder — the name is used exactly as fetched from /models/loras.
        #expect(resolverServerLoraName("krea2-realism-V2.safetensors") == "krea2-realism-V2.safetensors")
    }

    @Test func serverRelativeSubfolderPrefixIsPreserved() {
        // The decisive case: /models/loras returns a relative path with the subfolder, and LoraLoader expects it.
        #expect(resolverServerLoraName("krea2/Krea2-realism-V2.safetensors") == "krea2/Krea2-realism-V2.safetensors")
        #expect(resolverServerLoraName("deep/nested/Afterlight_v1.safetensors") == "deep/nested/Afterlight_v1.safetensors")
    }

    @Test func absoluteLocalPathReducesToBasename() {
        // A hand-entered local macOS file has no meaning on the server; its basename is the best submission value.
        #expect(resolverServerLoraName("/Users/me/Downloads/krea2-realism-V2.safetensors") == "krea2-realism-V2.safetensors")
    }

    @Test func absoluteLocalPathWithSubfolderStillReducesToBasename() {
        // Even a local path with subdirectories yields only the final component, matching how mflux named it.
        #expect(resolverServerLoraName("/Users/me/Loras/krea2/Krea2-realism-V2.safetensors") == "Krea2-realism-V2.safetensors")
    }

    @Test func emptyStringPassesThrough() {
        // Defensive: an empty path is invalid but must not crash the resolver.
        #expect(resolverServerLoraName("") == "")
    }
}
