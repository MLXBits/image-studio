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

// MARK: - Krea 2 runner graph (template mechanism)

/// The Krea 2 runner's remote graph after the template migration: the params dict
/// ``Krea2RunnerSpec/krea2Params(job:settings:familyID:)`` builds, the rendered `/prompt` graph against the
/// real bundled templates (read from the repo until Task 7 ships them into the app bundle), and — once the
/// bundle has the templates — the full ``Krea2RunnerSpec/comfyGraph(job:settings:client:)`` path.
struct Krea2ComfyGraphTests {
    /// True once Task 7 bundles `comfy_templates` into the app: ``Krea2RunnerSpec/comfyGraph(job:settings:client:)``
    /// loads the real templates from `Bundle.main`, so the full-runner test below is skipped until then. The
    /// render-path tests above cover the same code against the repo files in the meantime.
    nonisolated private static var templatesBundled: Bool {
        (try? ComfyTemplate.load(familyFlowKey: "krea2/t2i")) != nil
    }

    /// The repo's `Resources/comfy_templates/krea2` dir, resolved from this file's location.
    private static var templateDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/comfy_templates/krea2")
    }

    /// The same decode path as ``ComfyTemplate/load(familyFlowKey:)``, pointed at the repo file instead of the
    /// app bundle. Filenames match the loader's bundle layout (`comfy_templates/krea2/t2i.json`).
    private static func loadTemplate(_ flow: String) throws -> ComfyTemplate {
        try JSONDecoder().decode(
            ComfyTemplate.self,
            from: Data(contentsOf: templateDir.appendingPathComponent("\(flow).json"))
        )
    }

    private static func loadParamMap(_ flow: String) throws -> ComfyParamMap {
        try JSONDecoder().decode(
            ComfyParamMap.self,
            from: Data(contentsOf: templateDir.appendingPathComponent("\(flow).parammap.json"))
        )
    }

    private static func krea2Settings() -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.comfyUNet = ["krea2": "krea2_turbo_fp8_scaled.safetensors"]
        settings.comfyClip = ["krea2": "qwen3vl_4b_fp8_scaled.safetensors"]
        settings.comfyVae = ["krea2": "qwen_image_vae.safetensors"]
        return settings
    }

    /// The rendered graph as node-id → node dict.
    private static func nodes(_ graph: Any) throws -> [String: [String: Any]] {
        let raw = try #require(graph as? [String: Any])
        var out: [String: [String: Any]] = [:]
        for (id, value) in raw {
            if let node = value as? [String: Any] {
                out[id] = node
            }
        }
        return out
    }

    /// A node's `inputs` value by key.
    private static func input(_ node: [String: Any], _ key: String) throws -> Any? {
        try #require(node["inputs"] as? [String: Any])[key]
    }

    /// True when `value` is a wire ref `[nodeID, slot]` pointing at `(node, slot)`.
    private static func isRef(_ value: Any?, to node: String, slot: Int) -> Bool {
        guard let ref = value as? [Any], ref.count == 2 else { return false }
        return ref[0] as? String == node && ref[1] as? Int == slot
    }

    @Test func comfyGraphIsNilWithoutModelFiles() async throws {
        // No family model files configured → the job stays on local mflux (nil graph), before any template load.
        // Clear the fields explicitly: `AppSettings()` may load ambient settings that already have krea2 set.
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.comfyUNet = [:]
        settings.comfyClip = [:]
        settings.comfyVae = [:]
        let job = Krea2Job(prompt: "a panda")
        let client = ComfyUIClient(config: .init(baseURL: "http://127.0.0.1:1"))
        let graph = try await Krea2RunnerSpec.comfyGraph(job: job, settings: settings, client: client)
        #expect(graph == nil)
    }

    @Test func t2iParamsCarryJobValuesAndModelFiles() {
        let job = Krea2Job(prompt: "a panda", width: 512, height: 768, steps: 20, guidance: 1.0)
        let params = Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2")
        #expect(params["prompt"] as? String == "a panda")
        #expect(params["seed"] as? Int == 0)
        #expect(params["steps"] as? Int == 20)
        #expect(params["cfg"] as? Double == 1.0)
        #expect(params["sampler"] as? String == "euler")
        #expect(params["scheduler"] as? String == "simple")
        #expect(params["denoise"] as? Double == 1.0)
        #expect(params["width"] as? Int == 512)
        #expect(params["height"] as? Int == 768)
        #expect(params["unet_name"] as? String == "krea2_turbo_fp8_scaled.safetensors")
        #expect(params["clip_name"] as? String == "qwen3vl_4b_fp8_scaled.safetensors")
        #expect(params["vae_name"] as? String == "qwen_image_vae.safetensors")
        #expect(params["save_subfolder"] as? String == "mlxbits/krea2")
    }

    @Test func i2iParamsInvertImageStrengthForDenoiseAndOmitSize() {
        // The i2i template has no size node: denoise is the INVERSE of image strength (high strength =
        // keep the source = low denoise, matching the mflux CLI), and width/height stay out of the params
        // (injecting them would throw `unknownParam`).
        let job = Krea2Job(prompt: "a panda", imagePath: "/tmp/source.png", imageStrength: 0.75)
        let params = Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2")
        #expect(params["denoise"] as? Double == 0.25) // 1.0 - imageStrength (0.75)
        #expect(params["width"] == nil)
        #expect(params["height"] == nil)
    }

    @Test func t2iRenderInjectsPromptStepsAndModelFiles() throws {
        let template = try Self.loadTemplate("t2i")
        let map = try Self.loadParamMap("t2i")
        let job = Krea2Job(prompt: "a panda", width: 512, height: 768, steps: 20, guidance: 1.0)
        let graph = try template.render(
            map: map,
            params: Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2"),
            loras: []
        )
        let nodes = try Self.nodes(graph)
        #expect(try Self.input(#require(nodes["30:19"]), "value") as? String == "a panda")
        let ks = try #require(nodes["30:3"])
        #expect(try Self.input(ks, "steps") as? Int == 20)
        #expect(try Self.input(ks, "cfg") as? Double == 1.0)
        #expect(try Self.input(ks, "sampler_name") as? String == "euler")
        #expect(try Self.input(ks, "scheduler") as? String == "simple")
        #expect(try Self.input(ks, "denoise") as? Double == 1.0)
        #expect(try Self.input(ks, "seed") as? Int == 0)
        #expect(try Self.input(#require(nodes["30:10"]), "unet_name") as? String == "krea2_turbo_fp8_scaled.safetensors")
        #expect(try Self.input(#require(nodes["30:11"]), "clip_name") as? String == "qwen3vl_4b_fp8_scaled.safetensors")
        #expect(try Self.input(#require(nodes["30:12"]), "vae_name") as? String == "qwen_image_vae.safetensors")
        #expect(try Self.input(#require(nodes["30:5"]), "width") as? Int == 512)
        #expect(try Self.input(#require(nodes["30:5"]), "height") as? Int == 768)
        #expect(try Self.input(#require(nodes["29"]), "filename_prefix") as? String == "mlxbits/krea2")
        // No LoRAs: the KSampler reads the UNETLoader straight.
        #expect(try Self.isRef(Self.input(ks, "model"), to: "30:10", slot: 0))
    }

    @Test func i2iRenderInjectsSourceAndStrength() throws {
        let template = try Self.loadTemplate("i2i")
        let map = try Self.loadParamMap("i2i")
        let job = Krea2Job(prompt: "a panda", imagePath: "/tmp/source.png", imageStrength: 0.75)
        var params = Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2")
        // The server filename `uploadImage` returns; the runner sets it from the actual upload.
        params["source_image"] = "source.png"
        let graph = try template.render(map: map, params: params, loras: [])
        let nodes = try Self.nodes(graph)
        #expect(try Self.input(#require(nodes["30:70"]), "image") as? String == "source.png")
        let ks = try #require(nodes["30:3"])
        #expect(try Self.input(ks, "denoise") as? Double == 0.25) // 1.0 - imageStrength (0.75)
        #expect(try Self.input(#require(nodes["30:19"]), "value") as? String == "a panda")
        // The latent comes from the VAE-encoded source, not an empty latent.
        #expect(try Self.isRef(Self.input(ks, "latent_image"), to: "30:71", slot: 0))
    }

    @Test func t2iRenderChainsEnabledLoras() throws {
        let template = try Self.loadTemplate("t2i")
        let map = try Self.loadParamMap("t2i")
        let job = Krea2Job(prompt: "a panda")
        let loras = [
            ComfyLora(name: "krea2/styleA.safetensors", strength: 0.8),
            ComfyLora(name: "styleB.safetensors", strength: 0.6),
        ]
        let graph = try template.render(
            map: map,
            params: Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2"),
            loras: loras
        )
        let nodes = try Self.nodes(graph)
        #expect(nodes.count == template.nodes.count + loras.count)
        // Model-only chain: lora_ins_0 ← UNETLoader, lora_ins_1 ← lora_ins_0, KSampler ← lora_ins_1.
        let lora0 = try #require(nodes["lora_ins_0"])
        let lora1 = try #require(nodes["lora_ins_1"])
        #expect(lora0["class_type"] as? String == "LoraLoaderModelOnly")
        #expect(try Self.input(lora0, "lora_name") as? String == "krea2/styleA.safetensors")
        #expect(try Self.input(lora0, "strength_model") as? Double == 0.8)
        #expect(try Self.isRef(Self.input(lora0, "model"), to: "30:10", slot: 0))
        #expect(try Self.input(lora1, "lora_name") as? String == "styleB.safetensors")
        #expect(try Self.input(lora1, "strength_model") as? Double == 0.6)
        #expect(try Self.isRef(Self.input(lora1, "model"), to: "lora_ins_0", slot: 0))
        let ks = try #require(nodes["30:3"])
        #expect(try Self.isRef(Self.input(ks, "model"), to: "lora_ins_1", slot: 0))
    }

    /// Pins the real t2i template topology: the rendered graph (no LoRAs) has exactly the bundled template's
    /// 10 class_types — prompt primitive, CLIP encode + zero-out pair, loaders, sampler, decode, save. A
    /// re-export that drops or adds a node (e.g. a stray LoadImage on t2i) fails this. With a LoRA, the only
    /// added class is LoraLoaderModelOnly (the chain wiring itself is pinned by `t2iRenderChainsEnabledLoras`).
    @Test func t2iRenderedGraphPinsTheRealNodeSet() throws {
        let template = try Self.loadTemplate("t2i")
        let map = try Self.loadParamMap("t2i")
        let job = Krea2Job(prompt: "a panda")
        let params = Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2")
        let graph = try template.render(map: map, params: params, loras: [])
        let classes = try Set(Self.nodes(graph).values.compactMap { $0["class_type"] as? String })
        let expected: Set = [
            "EmptyLatentImage", "UNETLoader", "CLIPLoader", "VAELoader", "KSampler",
            "VAEDecode", "SaveImage", "CLIPTextEncode", "ConditioningZeroOut", "PrimitiveStringMultiline",
        ]
        #expect(classes == expected, "t2i class_types: \(classes.sorted())")
        #expect(try Self.nodes(graph).count == expected.count, "t2i node count")
        // With a LoRA, the only added class is LoraLoaderModelOnly.
        let loraGraph = try template.render(
            map: map,
            params: params,
            loras: [ComfyLora(name: "krea2/styleA.safetensors", strength: 0.8)]
        )
        let loraClasses = try Set(Self.nodes(loraGraph).values.compactMap { $0["class_type"] as? String })
        #expect(loraClasses == expected.union(["LoraLoaderModelOnly"]), "t2i+LoRA class_types: \(loraClasses.sorted())")
    }

    /// Pins the real i2i template topology: the rendered graph (no LoRAs) is the t2i class set minus
    /// EmptyLatentImage, plus LoadImage + VAEEncode (11 nodes) — the denoise-based img2img path.
    @Test func i2iRenderedGraphPinsTheRealNodeSet() throws {
        let template = try Self.loadTemplate("i2i")
        let map = try Self.loadParamMap("i2i")
        let job = Krea2Job(prompt: "a panda", imagePath: "/tmp/source.png", imageStrength: 0.75)
        var params = Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2")
        params["source_image"] = "source.png"
        let graph = try template.render(map: map, params: params, loras: [])
        let nodes = try Self.nodes(graph)
        let classes = Set(nodes.values.compactMap { $0["class_type"] as? String })
        let expected: Set = [
            "UNETLoader", "CLIPLoader", "VAELoader", "KSampler", "VAEDecode", "SaveImage",
            "CLIPTextEncode", "ConditioningZeroOut", "PrimitiveStringMultiline", "LoadImage", "VAEEncode",
        ]
        #expect(classes == expected, "i2i class_types: \(classes.sorted())")
        #expect(nodes.count == expected.count, "i2i node count")
    }

    /// Review Focus #5: a flow/param-map mismatch is caught at render time. The t2i param map targets node
    /// `30:5` (EmptyLatentImage), which the i2i template lacks, and the t2i params carry `width`/`height` —
    /// render throws `missingNode` instead of silently emitting a graph with unfilled sizes.
    @Test func i2iTemplateWithT2iParamMapThrowsAtRender() throws {
        let template = try Self.loadTemplate("i2i")
        let map = try Self.loadParamMap("t2i")
        let job = Krea2Job(prompt: "a panda", width: 512, height: 768, steps: 20, guidance: 1.0)
        let params = Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2")
        do {
            _ = try template.render(map: map, params: params, loras: [])
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("30:5"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// Review Focus #5 (reverse flow): the i2i param map targets node `30:70` (LoadImage), which the t2i
    /// template lacks, and the i2i params carry `source_image` — render throws `missingNode`.
    @Test func t2iTemplateWithI2iParamMapThrowsAtRender() throws {
        let template = try Self.loadTemplate("t2i")
        let map = try Self.loadParamMap("i2i")
        let job = Krea2Job(prompt: "a panda", imagePath: "/tmp/source.png", imageStrength: 0.75)
        var params = Krea2RunnerSpec.krea2Params(job: job, settings: Self.krea2Settings(), familyID: "krea2")
        params["source_image"] = "source.png"
        do {
            _ = try template.render(map: map, params: params, loras: [])
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("30:70"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(.enabled(if: Self.templatesBundled))
    func t2iJobYieldsAComfyGraphWhoseRenderInjectsJobParams() async throws {
        let job = Krea2Job(prompt: "a panda", width: 512, height: 768, steps: 20, guidance: 1.0)
        let client = ComfyUIClient(config: .init(baseURL: "http://127.0.0.1:1"))
        let maybeGraph = try await Krea2RunnerSpec.comfyGraph(job: job, settings: Self.krea2Settings(), client: client)
        let graph = try #require(maybeGraph)
        #expect(graph.totalNodes == 10) // the 10-node t2i template, no LoRAs
        #expect(graph.totalSteps == 20)
        let rendered = try Self.nodes(graph.build(42))
        let ks = try #require(rendered["30:3"])
        #expect(try Self.input(#require(rendered["30:19"]), "value") as? String == "a panda")
        #expect(try Self.input(ks, "steps") as? Int == 20)
        #expect(try Self.input(ks, "cfg") as? Double == 1.0)
        #expect(try Self.input(ks, "seed") as? Int == 42)
    }
}
