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
        #expect(resolverServerLoraName("/Users/paul/Downloads/krea2-realism-V2.safetensors") == "krea2-realism-V2.safetensors")
    }

    @Test func absoluteLocalPathWithSubfolderStillReducesToBasename() {
        // Even a local path with subdirectories yields only the final component, matching how mflux named it.
        #expect(resolverServerLoraName("/Users/paul/Loras/krea2/Krea2-realism-V2.safetensors") == "Krea2-realism-V2.safetensors")
    }

    @Test func emptyStringPassesThrough() {
        // Defensive: an empty path is invalid but must not crash the resolver.
        #expect(resolverServerLoraName("") == "")
    }
}

/// Tests for ``ComfyUIClient/buildKrea2Workflow(_:)`` — the node topology of the remote Krea 2 graph. The decisive
/// contract here is that LoRAs form a connected *series*: each LoraLoader consumes the previous node's model/clip/vae and
/// re-emits all three, so with two-plus LoRAs no intermediate node may be left dangling — otherwise ComfyUI rejects the
/// prompt ("node not connected"). Single-LoRA graphs hide this bug because the one lora reads straight from the base loaders.
@Suite("buildKrea2Workflow topology")
struct ComfyKrea2WorkflowTopologyTests {
    /// A minimal valid input exercising `loras.count` entries (the only variable under test).
    private static func makeInput(loras: [String]) -> ComfyUIClient.WorkflowInput {
        var input = ComfyUIClient.WorkflowInput(
            prompt: "test", negativePrompt: nil, width: 1024, height: 576, steps: 8, cfg: 1.0, seed: -1,
            unetName: "krea2_turbo_fp8_scaled.safetensors", clipName: "qwen_image_fp8.safetensors", vaeName: "kl-f8-anime3.safetensors"
        )
        input.loras = loras.map { ComfyLora(name: $0, strength: 1.0) }
        return input
    }

    /// Extracts a node's `inputs` dictionary from the built graph by class_type-independent node id.
    private static func inputs(of payload: [String: [String: Any]], _ id: String) -> [String: Any] {
        (payload[id]?["inputs"] as? [String: Any]) ?? [:]
    }

    /// Reads a link input `[nodeID, slot]`; returns `nil` if the field isn't present or isn't a two-element array.
    private static func link(_ inputs: [String: Any], _ key: String) -> (id: String, slot: Int)? {
        guard let raw = inputs[key] as? [Any], raw.count == 2,
              let nodeID = raw[0] as? String, let slot = raw[1] as? Int else { return nil }
        return (nodeID, slot)
    }

    /// Asserts a link input points to `(nodeID, slot)`. Tuple `==` does not compose with optionals, so compare element-wise; a missing or
    /// malformed field fails the expect with what was actually parsed.
    private static func expectLink(_ inputs: [String: Any], key: String, nodeID: String, slot: Int) {
        let link = Self.link(inputs, key)
        let actual = link.map { "\($0.id), \($0.slot)" } ?? "missing"
        #expect(link?.id == nodeID && link?.slot == slot, "expected \(key) -> (\(nodeID), \(slot)); got \(actual)")
    }

    @Test func noLorasConsumesBaseLoadersDirectly() throws {
        // With zero LoRAs the graph is UNET/CLIPL/VAEL -> encodes/KSampler/decode: every consumer reads a base loader.
        let payload = try #require(ComfyUIClient(config: .init(baseURL: "http://test"))
            .buildKrea2Workflow(Self.makeInput(loras: [])) as? [String: [String: Any]])
        Self.expectLink(Self.inputs(of: payload, "KSAMPLER"), key: "model", nodeID: "UNET", slot: 0)
        // Base CLIPLoader emits a single CLIP at slot 0.
        Self.expectLink(Self.inputs(of: payload, "CLIP_POS"), key: "clip", nodeID: "CLIPL", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "DECODE"), key: "vae", nodeID: "VAEL", slot: 0)
    }

    @Test func twoLorasFormAConnectedSeries() throws {
        // The regression case that ComfyUI rejected. This server's LoraLoader (per /object_info) outputs ['MODEL', 'CLIP']
        // — MODEL at slot 0, CLIP at slot 1 — and has NO vae input/output. So the chain threads model via slot 0 and clip
        // via slot 1 only; VAEDecode always reads the base VAELoader. Reading a lora's clip from its slot 0 (its MODEL) is
        // exactly what produced "Return type mismatch ... received_type(MODEL)".
        let payload = try #require(ComfyUIClient(config: .init(baseURL: "http://test")).buildKrea2Workflow(Self.makeInput(loras: [
            "a.safetensors",
            "b.safetensors",
        ])) as? [String: [String: Any]])

        // First lora sources from the base loaders (model slot 0, clip slot 0) and carries no vae input.
        Self.expectLink(Self.inputs(of: payload, "LORA_0"), key: "model", nodeID: "UNET", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "LORA_0"), key: "clip", nodeID: "CLIPL", slot: 0)
        #expect(Self.inputs(of: payload, "LORA_0")["vae"] == nil)

        // Second lora consumes the first's re-emitted outputs at the *correct* slots — this is exactly what was broken.
        Self.expectLink(Self.inputs(of: payload, "LORA_1"), key: "model", nodeID: "LORA_0", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "LORA_1"), key: "clip", nodeID: "LORA_0", slot: 1)
        #expect(Self.inputs(of: payload, "LORA_1")["vae"] == nil)

        // Every downstream consumer reads the final lora at its type-correct slot; VAE stays on the base loader.
        Self.expectLink(Self.inputs(of: payload, "KSAMPLER"), key: "model", nodeID: "LORA_1", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "CLIP_POS"), key: "clip", nodeID: "LORA_1", slot: 1)
        Self.expectLink(Self.inputs(of: payload, "DECODE"), key: "vae", nodeID: "VAEL", slot: 0)
        #expect(payload["KSAMPLER"] != nil && payload["LORA_0"] != nil && payload["LORA_1"] != nil)
    }

    @Test func threeLorasChainTransitively() throws {
        // Longer chain: each lora reads the previous at slot 0 (model) / slot 1 (clip); terminal consumers read LORA_2.
        // Guards against off-by-one in threading.
        let payload = try #require(ComfyUIClient(config: .init(baseURL: "http://test")).buildKrea2Workflow(Self.makeInput(loras: [
            "a.safetensors",
            "b.safetensors",
            "c.safetensors",
        ])) as? [String: [String: Any]])

        Self.expectLink(Self.inputs(of: payload, "LORA_0"), key: "model", nodeID: "UNET", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "LORA_1"), key: "model", nodeID: "LORA_0", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "LORA_2"), key: "clip", nodeID: "LORA_1", slot: 1)

        Self.expectLink(Self.inputs(of: payload, "KSAMPLER"), key: "model", nodeID: "LORA_2", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "CLIP_POS"), key: "clip", nodeID: "LORA_2", slot: 1)
        Self.expectLink(Self.inputs(of: payload, "DECODE"), key: "vae", nodeID: "VAEL", slot: 0)
    }

    @Test func singleLoraStillConsumesFinalLora() throws {
        // The case that worked before and must keep working: one lora reads base loaders; terminal consumers read it, VAE the base.
        let payload = try #require(ComfyUIClient(config: .init(baseURL: "http://test"))
            .buildKrea2Workflow(Self.makeInput(loras: ["only.safetensors"])) as? [String: [String: Any]])

        Self.expectLink(Self.inputs(of: payload, "LORA_0"), key: "model", nodeID: "UNET", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "KSAMPLER"), key: "model", nodeID: "LORA_0", slot: 0)
        Self.expectLink(Self.inputs(of: payload, "CLIP_POS"), key: "clip", nodeID: "LORA_0", slot: 1)
        // VAE is never re-routed through a LoRA on this server — decode always uses the base loader.
        Self.expectLink(Self.inputs(of: payload, "DECODE"), key: "vae", nodeID: "VAEL", slot: 0)
    }

    @Test func loraStrengthsAreSubmittedPerNode() throws {
        // Each LoraLoader carries its own strength_model/strength_clip, distinct per node.
        var input = Self.makeInput(loras: ["a.safetensors", "b.safetensors"])
        input.loras[0].strength = 0.8
        input.loras[1].strength = 1.2
        let payload = try #require(ComfyUIClient(config: .init(baseURL: "http://test"))
            .buildKrea2Workflow(input) as? [String: [String: Any]])

        #expect(Self.inputs(of: payload, "LORA_0")["strength_model"] as? Double == 0.8)
        #expect(Self.inputs(of: payload, "LORA_1")["strength_clip"] as? Double == 1.2)
    }
}
