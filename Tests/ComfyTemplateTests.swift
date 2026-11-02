import Foundation
@testable import MLXBits_Image_Studio
import Testing

// MARK: - ComfyTemplate decode

/// Decodes the raw `/prompt` wire form `{nodeID: {class_type, inputs}}` directly into ``ComfyTemplate/nodes``.
/// A scalar input decodes to a ``ComfyScalar``; a `[nodeID, outputIndex]` array decodes to a ref. Whole-number
/// JSON numbers decode as `.int` (so `steps: 20` stays an Int on the wire); `_meta` is ignored.
@Suite("ComfyTemplate decode")
struct ComfyTemplateDecodeTests {
    private static let fixture = """
    {
      "1": {"class_type": "KSampler", "_meta": {"title": "K"}, "inputs": {"steps": 20, "cfg": 7.0, "cond": ["2", 0]}},
      "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "a cat", "clip": ["3", 1]}}
    }
    """

    @Test func decodesNodesClassTypeAndInputs() throws {
        let t = try JSONDecoder().decode(ComfyTemplate.self, from: #require(Self.fixture.data(using: .utf8)))
        #expect(t.nodes.count == 2)
        #expect(t.nodes["1"]?.classType == "KSampler")
        #expect(t.nodes["2"]?.classType == "CLIPTextEncode")
        #expect(t.nodes["1"]?.inputs["steps"] == .scalar(.int(20)))
        #expect(t.nodes["2"]?.inputs["text"] == .scalar(.string("a cat")))
        #expect(t.nodes["1"]?.inputs["cond"] == .ref(nodeID: "2", outputIndex: 0))
        #expect(t.nodes["2"]?.inputs["clip"] == .ref(nodeID: "3", outputIndex: 1))
    }

    @Test func ignoresMetaKey() throws {
        let t = try JSONDecoder().decode(ComfyTemplate.self, from: #require(Self.fixture.data(using: .utf8)))
        #expect(t.nodes["1"]?.inputs["_meta"] == nil)
    }
}

// MARK: - ComfyParamMap decode

/// The param-map sidecar is the raw `{param: {node, input}}` form, decoded into ``ComfyParamMap/params``.
@Suite("ComfyParamMap decode")
struct ComfyParamMapDecodeTests {
    private static let fixture = """
    {"prompt": {"node": "2", "input": "text"}, "steps": {"node": "1", "input": "steps"}}
    """

    @Test func decodesTargets() throws {
        let m = try JSONDecoder().decode(ComfyParamMap.self, from: #require(Self.fixture.data(using: .utf8)))
        #expect(m.params["prompt"] == ParamTarget(node: "2", input: "text"))
        #expect(m.params["steps"] == ParamTarget(node: "1", input: "steps"))
    }
}

// MARK: - render (param injection + dynamic LoRA insertion)

/// Exercises the canonical ``ComfyTemplate/render(map:params:loras:)`` path: it fills each mapped scalar input
/// from `params` (throwing on a stale param map — a target whose node or input is missing) and dynamically
/// inserts `LoraLoaderModelOnly` nodes chained between the UNETLoader and the KSampler.model. The Swift
/// counterpart of `scripts/comfy_dry_run.py`'s `inject()` + `insert_loras()`.
@Suite("ComfyTemplate render")
struct ComfyRenderTests {
    /// A minimal graph: a KSampler ("1"), a CLIPTextEncode ("2"), and a UNETLoader ("10"). The KSampler's
    /// `model` starts wired to the UNET, which `insertLoras` rewires when LoRAs are present.
    private static func makeTemplate() -> ComfyTemplate {
        ComfyTemplate(nodes: [
            "1": ComfyNode(classType: "KSampler", inputs: [
                "steps": .scalar(.int(20)),
                "cfg": .scalar(.double(7.0)),
                "seed": .scalar(.int(0)),
                "model": .ref(nodeID: "10", outputIndex: 0),
            ]),
            "2": ComfyNode(classType: "CLIPTextEncode", inputs: [
                "text": .scalar(.string("old prompt")),
            ]),
            "10": ComfyNode(classType: "UNETLoader", inputs: [
                "unet_name": .scalar(.string("krea2.safetensors")),
            ]),
        ])
    }

    private static func makeParamMap() -> ComfyParamMap {
        ComfyParamMap(params: [
            "prompt": ParamTarget(node: "2", input: "text"),
            "steps": ParamTarget(node: "1", input: "steps"),
            "cfg": ParamTarget(node: "1", input: "cfg"),
        ])
    }

    // MARK: wire-form accessors

    private static func inputs(_ graph: [String: Any], _ nodeID: String) -> [String: Any] {
        guard let node = graph[nodeID] as? [String: Any], let inputs = node["inputs"] as? [String: Any] else {
            return [:]
        }
        return inputs
    }

    private static func classType(_ graph: [String: Any], _ nodeID: String) -> String? {
        (graph[nodeID] as? [String: Any])?["class_type"] as? String
    }

    private static func value(_ graph: [String: Any], _ nodeID: String, _ input: String) -> Any? {
        inputs(graph, nodeID)[input]
    }

    /// A node's `model` input as a `(nodeID, outputIndex)` ref, or nil if it is not a well-formed ref.
    private static func modelRef(_ graph: [String: Any], _ nodeID: String) -> (String, Int)? {
        let model = inputs(graph, nodeID)["model"] as? [Any]
        guard let model, model.count == 2, let n = model[0] as? String, let idx = model[1] as? Int else {
            return nil
        }
        return (n, idx)
    }

    /// Asserts a node's `model` input is the well-formed ref `(nodeID, outputIndex)`.
    private static func expectModel(_ graph: [String: Any], _ nodeID: String, _ ref: (String, Int)) {
        let model = modelRef(graph, nodeID)
        #expect(model?.0 == ref.0, "model node for \(nodeID): \(String(describing: model))")
        #expect(model?.1 == ref.1, "model output for \(nodeID): \(String(describing: model))")
    }

    // MARK: tests

    /// (a) With no LoRAs the KSampler is wired straight to the UNET.
    @Test func zeroLorasWiresKSamplerStraightToUnet() throws {
        let graph = try Self.makeTemplate().render(map: Self.makeParamMap(), params: [:], loras: [])
        Self.expectModel(graph, "1", ("10", 0))
    }

    /// (b) N LoRAs become a chain of N `LoraLoaderModelOnly` nodes (`lora_ins_<i>`) feeding the KSampler, in
    /// order, each carrying the right `lora_name` / `strength_model`.
    @Test func lorasAreChainedBetweenUnetAndKSampler() throws {
        let loras = [
            ComfyLora(name: "krea2/a.safetensors", strength: 0.8),
            ComfyLora(name: "krea2/b.safetensors", strength: 0.5),
        ]
        let graph = try Self.makeTemplate().render(map: Self.makeParamMap(), params: [:], loras: loras)

        // First LoRA takes the UNET's output.
        #expect(Self.classType(graph, "lora_ins_0") == "LoraLoaderModelOnly")
        #expect(Self.value(graph, "lora_ins_0", "lora_name") as? String == "krea2/a.safetensors")
        #expect(Self.value(graph, "lora_ins_0", "strength_model") as? Double == 0.8)
        Self.expectModel(graph, "lora_ins_0", ("10", 0))

        // Second LoRA takes the first LoRA's output.
        #expect(Self.classType(graph, "lora_ins_1") == "LoraLoaderModelOnly")
        #expect(Self.value(graph, "lora_ins_1", "lora_name") as? String == "krea2/b.safetensors")
        #expect(Self.value(graph, "lora_ins_1", "strength_model") as? Double == 0.5)
        Self.expectModel(graph, "lora_ins_1", ("lora_ins_0", 0))

        // The KSampler is rewired to the last LoRA in the chain.
        Self.expectModel(graph, "1", ("lora_ins_1", 0))
    }

    /// (c) render fills each mapped scalar input from `params`; a param absent from `params` stays at the
    /// template's baked value.
    @Test func renderFillsMappedScalarInputs() throws {
        let graph = try Self.makeTemplate().render(
            map: Self.makeParamMap(),
            params: ["prompt": "a cat", "steps": 30, "cfg": 5.0],
            loras: []
        )
        #expect(Self.value(graph, "2", "text") as? String == "a cat")
        #expect(Self.value(graph, "1", "steps") as? Int == 30)
        #expect(Self.value(graph, "1", "cfg") as? Double == 5.0)
        // `seed` is not in the param map, so its baked value (0) is left untouched.
        #expect(Self.value(graph, "1", "seed") as? Int == 0)
    }

    /// (d) A stale param map whose target node is missing from the template throws (never emits a wrong graph).
    @Test func staleParamMapMissingNodeThrows() {
        let map = ComfyParamMap(params: ["prompt": ParamTarget(node: "999", input: "text")])
        do {
            _ = try Self.makeTemplate().render(map: map, params: ["prompt": "a cat"], loras: [])
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("999"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// (d) A stale param map whose target input is missing from the node throws — it must not silently add the
    /// input (the #69 failure class).
    @Test func staleParamMapMissingInputThrows() {
        let map = ComfyParamMap(params: ["prompt": ParamTarget(node: "2", input: "bogus_input")])
        do {
            _ = try Self.makeTemplate().render(map: map, params: ["prompt": "a cat"], loras: [])
            Issue.record("expected missingInput")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingInput(node: "2", input: "bogus_input"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
