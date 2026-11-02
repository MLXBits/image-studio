import Foundation
@testable import MLXBits_Image_Studio
import Testing

// MARK: - insertLoras missing-node guard

/// The ``ComfyTemplate/render(map:params:loras:)`` → `insertLoras` guard must fail loudly when LoRAs are
/// requested but the template has no UNETLoader or KSampler to chain them between. Silently returning here
/// would run the job without the user's LoRAs and show no error — the silent-wrong-graph failure class this
/// change eliminates. With no LoRAs the missing nodes are irrelevant, so render still succeeds.
@Suite("ComfyTemplate insertLoras missing-node guard")
struct ComfyInsertLorasMissingNodeTests {
    private static let emptyMap = ComfyParamMap(params: [:])
    private static let oneLora = [ComfyLora(name: "krea2/a.safetensors", strength: 0.8)]

    /// A graph with a KSampler but NO UNETLoader — the guard's `unet` lookup fails.
    private static func makeTemplateMissingUnet() -> ComfyTemplate {
        ComfyTemplate(nodes: [
            "1": ComfyNode(classType: "KSampler", inputs: [
                "steps": .scalar(.int(20)),
                "model": .scalar(.string("unwired")),
            ]),
        ])
    }

    /// A graph with a UNETLoader but NO KSampler — the guard's `ks` lookup fails.
    private static func makeTemplateMissingKSampler() -> ComfyTemplate {
        ComfyTemplate(nodes: [
            "10": ComfyNode(classType: "UNETLoader", inputs: [
                "unet_name": .scalar(.string("krea2.safetensors")),
            ]),
        ])
    }

    /// (a) Non-empty LoRAs + no UNETLoader → throws `missingNode` (never a silent LoRA-less graph).
    @Test func missingUnetThrowsWithLoras() {
        do {
            _ = try Self.makeTemplateMissingUnet().render(map: Self.emptyMap, params: [:], loras: Self.oneLora)
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("UNETLoader/KSampler"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// (b) Non-empty LoRAs + no KSampler → throws `missingNode`.
    @Test func missingKSamplerThrowsWithLoras() {
        do {
            _ = try Self.makeTemplateMissingKSampler().render(map: Self.emptyMap, params: [:], loras: Self.oneLora)
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("UNETLoader/KSampler"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// (c) Empty LoRAs + no UNETLoader → does NOT throw: nothing to insert, so the missing node is moot.
    @Test func missingUnetDoesNotThrowWithoutLoras() throws {
        _ = try Self.makeTemplateMissingUnet().render(map: Self.emptyMap, params: [:], loras: [])
    }
}

// MARK: - insertLoras .full (FLUX.2: LoraLoader with model + clip)

/// ``ComfyTemplate/render(map:params:loras:loraKind:)`` with ``ComfyLoraKind/full`` inserts `LoraLoader`
/// nodes (model + clip streams) chained after the UNETLoader and the CLIPLoader, in order. The model
/// consumer is found by reference-rewrite (every `[unetID, 0]` ref) — FLUX.2's advanced sampler stack
/// has no `KSampler`, the consumer is `CFGGuider.model` — and the tail clip feeds every `CLIPTextEncode`
/// (positive + negative). Swift counterpart of `scripts/comfy_dry_run.py`'s `insert_loras(kind="full")`.
@Suite("ComfyTemplate insertLoras full LoRA (FLUX.2)")
struct ComfyInsertLorasFullTests {
    private static let emptyMap = ComfyParamMap(params: [:])
    private static let twoLoras = [
        ComfyLora(name: "flux2/a.safetensors", strength: 0.8),
        ComfyLora(name: "flux2/b.safetensors", strength: 0.5),
    ]

    /// A FLUX.2-style graph with NO KSampler: UNETLoader ("10"), CLIPLoader ("11"), `CFGGuider` ("20")
    /// as the model consumer, and positive + negative `CLIPTextEncode` ("30"/"31") on the same
    /// CLIPLoader (the Base-variant topology: CFG + empty negative).
    private static func makeFluxTemplate() -> ComfyTemplate {
        ComfyTemplate(nodes: [
            "10": ComfyNode(classType: "UNETLoader", inputs: [
                "unet_name": .scalar(.string("flux2-4b.safetensors")),
            ]),
            "11": ComfyNode(classType: "CLIPLoader", inputs: [
                "clip_name": .scalar(.string("qwen3vl_4b.safetensors")),
                "type": .scalar(.string("flux2")),
            ]),
            "20": ComfyNode(classType: "CFGGuider", inputs: [
                "model": .ref(nodeID: "10", outputIndex: 0),
                "positive": .ref(nodeID: "30", outputIndex: 0),
                "negative": .ref(nodeID: "31", outputIndex: 0),
                "cfg": .scalar(.double(1.0)),
            ]),
            "30": ComfyNode(classType: "CLIPTextEncode", inputs: [
                "text": .scalar(.string("a cat")),
                "clip": .ref(nodeID: "11", outputIndex: 0),
            ]),
            "31": ComfyNode(classType: "CLIPTextEncode", inputs: [
                "text": .scalar(.string("")),
                "clip": .ref(nodeID: "11", outputIndex: 0),
            ]),
        ])
    }

    // MARK: wire-form accessors

    private static func inputs(_ graph: [String: Any], _ nodeID: String) -> [String: Any] {
        guard let node = graph[nodeID] as? [String: Any], let inputs = node["inputs"] as? [String: Any] else {
            return [:]
        }
        return inputs
    }

    private static func value(_ graph: [String: Any], _ nodeID: String, _ input: String) -> Any? {
        inputs(graph, nodeID)[input]
    }

    /// A node input as a `(nodeID, outputIndex)` ref, or nil if it is not a well-formed ref.
    private static func ref(_ graph: [String: Any], _ nodeID: String, _ input: String) -> (String, Int)? {
        guard let arr = value(graph, nodeID, input) as? [Any], arr.count == 2,
              let n = arr[0] as? String, let idx = arr[1] as? Int else {
            return nil
        }
        return (n, idx)
    }

    private static func expectRef(_ graph: [String: Any], _ nodeID: String, _ input: String, _ expected: (String, Int)) {
        let r = ref(graph, nodeID, input)
        #expect(r?.0 == expected.0, "\(nodeID).\(input) node: \(String(describing: r))")
        #expect(r?.1 == expected.1, "\(nodeID).\(input) output: \(String(describing: r))")
    }

    // MARK: tests

    /// (a) N LoRAs become a chain of N `LoraLoader` nodes (`lora_ins_<i>`) wiring BOTH streams: each node
    /// carries the right `lora_name` / `strength_model` / `strength_clip`, the model stream chains on
    /// slot 0, the clip stream on slot 1, the `CFGGuider` model consumer is rewired to the chain tail,
    /// and the tail clip feeds both encoders.
    @Test func fullLoraChainWiresModelAndClip() throws {
        let graph = try Self.makeFluxTemplate().render(map: Self.emptyMap, params: [:], loras: Self.twoLoras, loraKind: .full)

        // First LoRA takes the UNET's model output + the CLIPLoader's clip output.
        #expect((graph["lora_ins_0"] as? [String: Any])?["class_type"] as? String == "LoraLoader")
        #expect(Self.value(graph, "lora_ins_0", "lora_name") as? String == "flux2/a.safetensors")
        #expect(Self.value(graph, "lora_ins_0", "strength_model") as? Double == 0.8)
        #expect(Self.value(graph, "lora_ins_0", "strength_clip") as? Double == 0.8)
        Self.expectRef(graph, "lora_ins_0", "model", ("10", 0))
        Self.expectRef(graph, "lora_ins_0", "clip", ("11", 0))

        // Second LoRA chains on the first LoRA's model (slot 0) + clip (slot 1) outputs.
        #expect((graph["lora_ins_1"] as? [String: Any])?["class_type"] as? String == "LoraLoader")
        #expect(Self.value(graph, "lora_ins_1", "lora_name") as? String == "flux2/b.safetensors")
        #expect(Self.value(graph, "lora_ins_1", "strength_model") as? Double == 0.5)
        #expect(Self.value(graph, "lora_ins_1", "strength_clip") as? Double == 0.5)
        Self.expectRef(graph, "lora_ins_1", "model", ("lora_ins_0", 0))
        Self.expectRef(graph, "lora_ins_1", "clip", ("lora_ins_0", 1))

        // The model consumer (CFGGuider — there is no KSampler) is rewired to the model chain tail.
        Self.expectRef(graph, "20", "model", ("lora_ins_1", 0))
        // The tail clip feeds both the positive and negative encoders.
        Self.expectRef(graph, "30", "clip", ("lora_ins_1", 1))
        Self.expectRef(graph, "31", "clip", ("lora_ins_1", 1))
    }

    /// (b) The model consumer is found by reference-rewrite, not by looking for a KSampler: a graph with
    /// UNETLoader + CFGGuider and NO KSampler gets `CFGGuider.model` rewired to the chain tail.
    @Test func fullModelConsumerViaReferenceRewriteFeedsCFGGuider() throws {
        let graph = try Self.makeFluxTemplate().render(
            map: Self.emptyMap, params: [:], loras: [Self.twoLoras[0]], loraKind: .full
        )
        Self.expectRef(graph, "20", "model", ("lora_ins_0", 0))
    }

    /// (c) The tail clip feeds BOTH the positive and negative `CLIPTextEncode` nodes (a Base template
    /// references the same CLIPLoader twice — one encoder must not be left un-LoRA'd).
    @Test func fullTailClipFeedsBothEncoders() throws {
        let graph = try Self.makeFluxTemplate().render(
            map: Self.emptyMap, params: [:], loras: [Self.twoLoras[0]], loraKind: .full
        )
        Self.expectRef(graph, "30", "clip", ("lora_ins_0", 1))
        Self.expectRef(graph, "31", "clip", ("lora_ins_0", 1))
    }

    /// (d) A graph with UNETLoader + CFGGuider but NO CLIPLoader: `.full` has no clip anchor, so it must
    /// fail loudly rather than emit a graph whose clip is un-LoRA'd.
    @Test func fullMissingCLIPLoaderThrows() {
        let template = ComfyTemplate(nodes: [
            "10": ComfyNode(classType: "UNETLoader", inputs: [
                "unet_name": .scalar(.string("flux2-4b.safetensors")),
            ]),
            "20": ComfyNode(classType: "CFGGuider", inputs: [
                "model": .ref(nodeID: "10", outputIndex: 0),
                "cfg": .scalar(.double(1.0)),
            ]),
        ])
        do {
            _ = try template.render(map: Self.emptyMap, params: [:], loras: [Self.twoLoras[0]], loraKind: .full)
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("CLIPLoader"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// (e) Empty LoRAs + `.full` is a no-op: no `lora_ins_*` nodes, the CFGGuider and both encoders stay
    /// wired straight to the UNETLoader / CLIPLoader.
    @Test func fullZeroLorasIsANoOp() throws {
        let graph = try Self.makeFluxTemplate().render(map: Self.emptyMap, params: [:], loras: [], loraKind: .full)
        #expect(graph["lora_ins_0"] == nil)
        Self.expectRef(graph, "20", "model", ("10", 0))
        Self.expectRef(graph, "30", "clip", ("11", 0))
        Self.expectRef(graph, "31", "clip", ("11", 0))
    }
}

// MARK: - i2e conditioning-slot excision

/// ``exciseUnusedConditioningSlots(_:keepCount:slotOrder:)`` removes the unused FLUX.2 i2e conditioning
/// slots (the tail of `slotOrder`) and rewires the kept ReferenceLatent chains so the last kept slot feeds
/// the CFGGuider directly. A LoadImage with no image input fails at runtime, so the unused slots must be
/// excised before submission.
///
/// Note: the chain order in the template does NOT match the param-map slot order (they diverge from slot 3
/// onward), so the excision set is derived from `slotOrder` (the param-map image-assignment order) and the
/// ReferenceLatent chains are traced from the graph and rewired — which handles the non-contiguous excision.
@Suite("ComfyTemplate i2e conditioning-slot excision")
struct FluxConditioningExcisionTests {
    private static let key = "flux2/4b-i2e-base"
    private static let emptyMap = ComfyParamMap(params: [:])

    private static func loadTemplate() throws -> ComfyTemplate {
        try ComfyTemplate.load(familyFlowKey: key)
    }

    private static func loadParamMap() throws -> ComfyParamMap {
        try ComfyParamMap.load(familyFlowKey: key)
    }

    /// The base wire-form graph (no params, no LoRAs) — the excision operates on this.
    private static func baseGraph() throws -> [String: Any] {
        try loadTemplate().render(map: emptyMap, params: [:], loras: [])
    }

    // MARK: wire-form accessors

    private static func nodeIDs(ofClass cls: String, in graph: [String: Any]) -> Set<String> {
        Set(graph.compactMap { id, v in
            ((v as? [String: Any])?["class_type"] as? String) == cls ? id : nil
        })
    }

    private static func inputs(_ graph: [String: Any], _ nodeID: String) -> [String: Any] {
        (graph[nodeID] as? [String: Any])?["inputs"] as? [String: Any] ?? [:]
    }

    private static func ref(_ graph: [String: Any], _ nodeID: String, _ input: String) -> (String, Int)? {
        guard let arr = inputs(graph, nodeID)[input] as? [Any], arr.count == 2,
              let n = arr[0] as? String, let idx = arr[1] as? Int else { return nil }
        return (n, idx)
    }

    /// Every `[nodeID, outputIndex]` ref in the graph must point to an existing node.
    private static func assertNoDanglingRefs(_ graph: [String: Any]) {
        for (id, v) in graph {
            guard let node = v as? [String: Any] else { continue }
            for (name, value) in node["inputs"] as? [String: Any] ?? [:] {
                if let arr = value as? [Any], arr.count == 2, let target = arr[0] as? String {
                    #expect(graph[target] != nil, "dangling ref \(id).\(name) -> \(target)")
                }
            }
        }
    }

    private static func expectRef(
        _ graph: [String: Any],
        _ nodeID: String,
        _ input: String,
        _ expected: (String, Int)
    ) {
        let r = ref(graph, nodeID, input)
        #expect(r?.0 == expected.0, "\(nodeID).\(input) node: \(String(describing: r))")
        #expect(r?.1 == expected.1, "\(nodeID).\(input) output: \(String(describing: r))")
    }

    private static func canonicalJSON(_ graph: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys])
    }

    // MARK: tests

    /// (a) Excising the tail of `slotOrder` removes each excised slot's LoadImage / ImageScale / VAEEncode /
    /// ReferenceLatent nodes and rewires the CFGGuider to the last kept slot's ReferenceLatent (both the
    /// positive and negative chains).
    @Test func exciseUnusedSlotsRemovesNodesAndRewiresTail() throws {
        let slotOrder = try Self.loadParamMap().referenceSlotOrder
        #expect(slotOrder.count == 6)
        let original = try Self.baseGraph()
        var graph = original
        try exciseUnusedConditioningSlots(&graph, keepCount: 2, slotOrder: slotOrder)

        // Only the two kept LoadImage nodes remain; the four excised are gone.
        #expect(Self.nodeIDs(ofClass: "LoadImage", in: graph) == Set(slotOrder[0 ..< 2]))
        for id in Set(slotOrder[2...]) {
            #expect(graph[id] == nil)
        }
        // Each excised slot removes its ImageScale, VAEEncode, and two ReferenceLatent nodes.
        #expect(Self.nodeIDs(ofClass: "ImageScaleToTotalPixels", in: graph).count == 2)
        #expect(Self.nodeIDs(ofClass: "VAEEncode", in: graph).count == 2)
        #expect(Self.nodeIDs(ofClass: "ReferenceLatent", in: graph).count == 4)
        #expect(graph.count == original.count - 4 * 5)

        // The CFGGuider's positive + negative inputs now reference the last kept slot's ReferenceLatent.
        let cfgID = Self.nodeIDs(ofClass: "CFGGuider", in: graph).first ?? ""
        let rls = Self.nodeIDs(ofClass: "ReferenceLatent", in: graph)
        for input in ["positive", "negative"] {
            let r = Self.ref(graph, cfgID, input)
            #expect(r != nil, "CFGGuider.\(input) is not a ref")
            #expect(graph[r?.0 ?? ""] != nil, "CFGGuider.\(input) dangles")
            #expect(rls.contains(r?.0 ?? ""), "CFGGuider.\(input) is not a ReferenceLatent")
        }
        Self.assertNoDanglingRefs(graph)
    }

    /// (b) Excising down to a single slot keeps only the first slot's nodes; its ReferenceLatent feeds the
    /// CFGGuider directly.
    @Test func exciseAllButOneKeepsFirstSlot() throws {
        let slotOrder = try Self.loadParamMap().referenceSlotOrder
        var graph = try Self.baseGraph()
        try exciseUnusedConditioningSlots(&graph, keepCount: 1, slotOrder: slotOrder)

        #expect(Self.nodeIDs(ofClass: "LoadImage", in: graph) == Set([slotOrder[0]]))
        #expect(Self.nodeIDs(ofClass: "ImageScaleToTotalPixels", in: graph).count == 1)
        #expect(Self.nodeIDs(ofClass: "VAEEncode", in: graph).count == 1)
        #expect(Self.nodeIDs(ofClass: "ReferenceLatent", in: graph).count == 2)
        let cfgID = Self.nodeIDs(ofClass: "CFGGuider", in: graph).first ?? ""
        for input in ["positive", "negative"] {
            let r = Self.ref(graph, cfgID, input)
            #expect(graph[r?.0 ?? ""] != nil, "CFGGuider.\(input) dangles")
        }
        Self.assertNoDanglingRefs(graph)
    }

    /// (c) Excising zero slots (keepCount == slotOrder.count) is a no-op: the graph is byte-identical.
    @Test func exciseZeroSlotsIsNoop() throws {
        let slotOrder = try Self.loadParamMap().referenceSlotOrder
        let original = try Self.baseGraph()
        var graph = original
        try exciseUnusedConditioningSlots(&graph, keepCount: slotOrder.count, slotOrder: slotOrder)
        #expect(try Self.canonicalJSON(original) == Self.canonicalJSON(graph))
    }

    /// (d) Excision composes with full-LoRA insertion: the LoRA chain (model + clip) is intact and the
    /// conditioning tail is rewired, with no dangling refs.
    @Test func exciseWithLoRAsStillWorks() throws {
        let slotOrder = try Self.loadParamMap().referenceSlotOrder
        let lora = ComfyLora(name: "flux2/a.safetensors", strength: 0.8)
        var graph = try Self.loadTemplate().render(map: Self.emptyMap, params: [:], loras: [lora], loraKind: .full)
        try exciseUnusedConditioningSlots(&graph, keepCount: 2, slotOrder: slotOrder)

        // The LoRA chain is intact: lora_ins_0 wires model + clip, and the CFGGuider model consumer is rewired.
        #expect((graph["lora_ins_0"] as? [String: Any])?["class_type"] as? String == "LoraLoader")
        let unet = Self.nodeIDs(ofClass: "UNETLoader", in: graph).first ?? ""
        let clip = Self.nodeIDs(ofClass: "CLIPLoader", in: graph).first ?? ""
        Self.expectRef(graph, "lora_ins_0", "model", (unet, 0))
        Self.expectRef(graph, "lora_ins_0", "clip", (clip, 0))
        let cfgID = Self.nodeIDs(ofClass: "CFGGuider", in: graph).first ?? ""
        Self.expectRef(graph, cfgID, "model", ("lora_ins_0", 0))
        // The conditioning excision is correct: the tail is rewired to the last kept slot's ReferenceLatent.
        let rls = Self.nodeIDs(ofClass: "ReferenceLatent", in: graph)
        for input in ["positive", "negative"] {
            let r = Self.ref(graph, cfgID, input)
            #expect(graph[r?.0 ?? ""] != nil, "CFGGuider.\(input) dangles")
            #expect(rls.contains(r?.0 ?? ""), "CFGGuider.\(input) is not a ReferenceLatent")
        }
        // Only the two kept LoadImage nodes remain.
        #expect(Self.nodeIDs(ofClass: "LoadImage", in: graph) == Set(slotOrder[0 ..< 2]))
        Self.assertNoDanglingRefs(graph)
    }
}
