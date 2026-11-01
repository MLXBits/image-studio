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

// MARK: - renderGraph

@Suite("renderGraph")
struct ComfyRenderGraphTests {
    /// A small template: a KSampler (node "1"), a CLIPTextEncode (node "2"), a LoadImage (node "3"), and 10 LoRA
    /// loader slots (nodes "101"–"110"). Each LoRA slot has an `on` switch so all three ``LoraMechanism`` cases
    /// can be exercised.
    private static func makeTemplate() -> ComfyTemplate {
        var nodes: [String: ComfyNode] = [
            "1": ComfyNode(classType: "KSampler", inputs: [
                "steps": .scalar(.int(1)),
                "cfg": .scalar(.double(1)),
                "seed": .scalar(.int(0)),
            ]),
            "2": ComfyNode(classType: "CLIPTextEncode", inputs: [
                "text": .scalar(.string("")),
            ]),
            "3": ComfyNode(classType: "LoadImage", inputs: [
                "image": .scalar(.string("")),
            ]),
        ]
        for slot in 1 ... 10 {
            nodes["10\(slot)"] = ComfyNode(classType: "LoraLoader", inputs: [
                "lora_name": .scalar(.string("")),
                "strength_model": .scalar(.double(1)),
                "strength_clip": .scalar(.double(1)),
                "on": .scalar(.bool(true)),
            ])
        }
        return ComfyTemplate(nodes: nodes)
    }

    private static func makeParamMap() -> ComfyParamMap {
        var params: [String: ParamTarget] = [
            "prompt": ParamTarget(node: "2", input: "text"),
            "steps": ParamTarget(node: "1", input: "steps"),
            "cfg": ParamTarget(node: "1", input: "cfg"),
            "seed": ParamTarget(node: "1", input: "seed"),
            "source_image": ParamTarget(node: "3", input: "image"),
        ]
        for slot in 1 ... 10 {
            params["lora\(slot)_name"] = ParamTarget(node: "10\(slot)", input: "lora_name")
            params["lora\(slot)_sm"] = ParamTarget(node: "10\(slot)", input: "strength_model")
            params["lora\(slot)_sc"] = ParamTarget(node: "10\(slot)", input: "strength_clip")
            params["lora\(slot)_on"] = ParamTarget(node: "10\(slot)", input: "on")
        }
        return ComfyParamMap(params: params)
    }

    private static func makeParams(loras: [ComfyJobParams.LoraEntry] = []) -> ComfyJobParams {
        ComfyJobParams(
            prompt: "a cat",
            negativePrompt: nil,
            seed: 42,
            width: 1024,
            height: 1024,
            steps: 20,
            cfg: 7.0,
            sampler: "euler",
            scheduler: "simple",
            denoise: nil,
            unetName: nil,
            clipName: nil,
            vaeName: nil,
            sourceImageName: nil,
            loras: loras
        )
    }

    private static func findPython3() -> String? {
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathVar.split(separator: ":") {
            let candidate = "\(dir)/python3"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        for c in ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    @Test func fillsMappedScalarInputs() throws {
        let graph = try renderGraph(
            template: Self.makeTemplate(),
            paramMap: Self.makeParamMap(),
            params: Self.makeParams(),
            loraMechanism: .emptyNoOp
        )
        #expect(graph["2"]?.inputs["text"] == .scalar(.string("a cat")))
        #expect(graph["1"]?.inputs["steps"] == .scalar(.int(20)))
        #expect(graph["1"]?.inputs["cfg"] == .scalar(.double(7.0)))
        #expect(graph["1"]?.inputs["seed"] == .scalar(.int(42)))
    }

    @Test func missingMappedNodeThrows() {
        let paramMap = ComfyParamMap(params: ["prompt": ParamTarget(node: "999", input: "text")])
        do {
            _ = try renderGraph(template: Self.makeTemplate(), paramMap: paramMap, params: Self.makeParams(), loraMechanism: .emptyNoOp)
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("999"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func missingMappedInputThrows() {
        let paramMap = ComfyParamMap(params: ["prompt": ParamTarget(node: "2", input: "bogus_input")])
        do {
            _ = try renderGraph(template: Self.makeTemplate(), paramMap: paramMap, params: Self.makeParams(), loraMechanism: .emptyNoOp)
            Issue.record("expected missingInput")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingInput(node: "2", input: "bogus_input"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func moreThanTenLorasThrows() {
        let loras = (1 ... 11).map { ComfyJobParams.LoraEntry(name: "lora\($0).safetensors", strengthModel: 1, strengthClip: 1) }
        do {
            _ = try renderGraph(
                template: Self.makeTemplate(),
                paramMap: Self.makeParamMap(),
                params: Self.makeParams(loras: loras),
                loraMechanism: .emptyNoOp
            )
            Issue.record("expected tooManyLoras")
        } catch let e as ComfyTemplateError {
            #expect(e == .tooManyLoras(11))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func usedSlotsGetNameAndStrengths() throws {
        let loras = [
            ComfyJobParams.LoraEntry(name: "a.safetensors", strengthModel: 0.8, strengthClip: 0.9),
            ComfyJobParams.LoraEntry(name: "b.safetensors", strengthModel: 0.5, strengthClip: 0.5),
        ]
        let graph = try renderGraph(
            template: Self.makeTemplate(),
            paramMap: Self.makeParamMap(),
            params: Self.makeParams(loras: loras),
            loraMechanism: .emptyNoOp
        )
        #expect(graph["101"]?.inputs["lora_name"] == .scalar(.string("a.safetensors")))
        #expect(graph["101"]?.inputs["strength_model"] == .scalar(.double(0.8)))
        #expect(graph["101"]?.inputs["strength_clip"] == .scalar(.double(0.9)))
        #expect(graph["102"]?.inputs["lora_name"] == .scalar(.string("b.safetensors")))
    }

    @Test func unusedSlotsAreNeutralizedPerMechanism() throws {
        let loras = [ComfyJobParams.LoraEntry(name: "a.safetensors", strengthModel: 0.8, strengthClip: 0.8)]

        // emptyNoOp: unused slots get an empty name (switch stays on).
        let g1 = try renderGraph(
            template: Self.makeTemplate(),
            paramMap: Self.makeParamMap(),
            params: Self.makeParams(loras: loras),
            loraMechanism: .emptyNoOp
        )
        #expect(g1["102"]?.inputs["lora_name"] == .scalar(.string("")))
        #expect(g1["102"]?.inputs["on"] == .scalar(.bool(true)))

        // strengthZero: unused slots get the placeholder name + zero strengths (switch stays on).
        let g2 = try renderGraph(
            template: Self.makeTemplate(),
            paramMap: Self.makeParamMap(),
            params: Self.makeParams(loras: loras),
            loraMechanism: .strengthZero
        )
        #expect(g2["102"]?.inputs["lora_name"] == .scalar(.string("a.safetensors")))
        #expect(g2["102"]?.inputs["strength_model"] == .scalar(.double(0)))
        #expect(g2["102"]?.inputs["strength_clip"] == .scalar(.double(0)))
        #expect(g2["102"]?.inputs["on"] == .scalar(.bool(true)))

        // switchBased: unused slots are switched off (the used slot stays on).
        let g3 = try renderGraph(
            template: Self.makeTemplate(),
            paramMap: Self.makeParamMap(),
            params: Self.makeParams(loras: loras),
            loraMechanism: .switchBased
        )
        #expect(g3["101"]?.inputs["on"] == .scalar(.bool(true)))
        #expect(g3["102"]?.inputs["on"] == .scalar(.bool(false)))
        // Slot 10's node id is "1010" ("10" + "10"), not "110".
        #expect(g3["1010"]?.inputs["on"] == .scalar(.bool(false)))
    }

    @Test func allTenSlotsWiredForNUsedSlots() throws {
        let loras = (1 ... 3).map { ComfyJobParams.LoraEntry(name: "l\($0).safetensors", strengthModel: 0.7, strengthClip: 0.6) }
        let graph = try renderGraph(
            template: Self.makeTemplate(),
            paramMap: Self.makeParamMap(),
            params: Self.makeParams(loras: loras),
            loraMechanism: .emptyNoOp
        )
        for slot in 1 ... 3 {
            let id = "10\(slot)"
            #expect(graph[id]?.inputs["lora_name"] == .scalar(.string("l\(slot).safetensors")), "slot \(slot) name")
            #expect(graph[id]?.inputs["strength_model"] == .scalar(.double(0.7)), "slot \(slot) sm")
            #expect(graph[id]?.inputs["strength_clip"] == .scalar(.double(0.6)), "slot \(slot) sc")
            #expect(graph[id]?.inputs["on"] == .scalar(.bool(true)), "slot \(slot) on")
        }
        for slot in 4 ... 10 {
            let id = "10\(slot)"
            #expect(graph[id]?.inputs["lora_name"] == .scalar(.string("")), "slot \(slot) empty name")
            #expect(graph[id]?.inputs["on"] == .scalar(.bool(true)), "slot \(slot) on")
        }
    }

    @Test func i2iSetsSourceImage() throws {
        var params = Self.makeParams()
        params.sourceImageName = "mlxbits/source.png"
        let graph = try renderGraph(
            template: Self.makeTemplate(),
            paramMap: Self.makeParamMap(),
            params: params,
            loraMechanism: .emptyNoOp
        )
        #expect(graph["3"]?.inputs["image"] == .scalar(.string("mlxbits/source.png")))
    }

    @Test func t2iLeavesSourceImageUntouched() throws {
        let graph = try renderGraph(
            template: Self.makeTemplate(),
            paramMap: Self.makeParamMap(),
            params: Self.makeParams(), // sourceImageName is nil
            loraMechanism: .emptyNoOp
        )
        #expect(graph["3"]?.inputs["image"] == .scalar(.string("")))
    }

    /// Verifies renderGraph's generic injection is bit-compatible with the Task 1 Python harness `inject()`
    /// (scripts/comfy_dry_run.py) on the same inputs. The fixture has no LoRA slots or source image, so only the
    /// generic scalar-fill path (the part inject() implements) is compared. Shells out to python3.
    @Test func matchesHarnessInject() throws {
        let templateJSON = """
        {"1": {"class_type": "KSampler", "inputs": {"steps": 20, "cfg": 7.0, "cond": ["2", 0]}},
         "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "old prompt"}}}
        """
        let paramMapJSON = """
        {"prompt": {"node": "2", "input": "text"}, "steps": {"node": "1", "input": "steps"}, "cfg": {"node": "1", "input": "cfg"}}
        """
        let paramsJSON = """
        {"prompt": "a cat", "steps": 30, "cfg": 5.0}
        """

        // Swift side: decode + renderGraph + encode to the /prompt wire form.
        let template = try JSONDecoder().decode(ComfyTemplate.self, from: Data(templateJSON.utf8))
        let paramMap = try JSONDecoder().decode(ComfyParamMap.self, from: Data(paramMapJSON.utf8))
        let params = ComfyJobParams(
            prompt: "a cat", negativePrompt: nil, seed: 42, width: 1024, height: 1024,
            steps: 30, cfg: 5.0, sampler: "euler", scheduler: "simple", denoise: nil,
            unetName: nil, clipName: nil, vaeName: nil, sourceImageName: nil, loras: []
        )
        let graph = try renderGraph(template: template, paramMap: paramMap, params: params, loraMechanism: .emptyNoOp)
        let swiftData = try JSONEncoder().encode(graph)

        // Python side: run the harness inject() on the same inputs.
        guard let python = Self.findPython3() else {
            Issue.record("python3 not found; cannot verify harness inject() equivalence")
            return
        }
        let repoRoot = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        let scriptsDir = repoRoot.appendingPathComponent("scripts").path
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("comfy_task3_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let tmplFile = tmpDir.appendingPathComponent("template.json")
        let mapFile = tmpDir.appendingPathComponent("parammap.json")
        let paramsFile = tmpDir.appendingPathComponent("params.json")
        try templateJSON.write(to: tmplFile, atomically: true, encoding: .utf8)
        try paramMapJSON.write(to: mapFile, atomically: true, encoding: .utf8)
        try paramsJSON.write(to: paramsFile, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [
            "-c",
            "import sys, json\n" +
                "sys.path.insert(0, sys.argv[1])\n" +
                "import comfy_dry_run as cdr\n" +
                "t = json.load(open(sys.argv[2]))\n" +
                "m = json.load(open(sys.argv[3]))\n" +
                "p = json.load(open(sys.argv[4]))\n" +
                "print(json.dumps(cdr.inject(t, m, p), sort_keys=True))\n",
            scriptsDir, tmplFile.path, mapFile.path, paramsFile.path,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        let pyString = String(data: outData, encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "harness inject() exited \(proc.terminationStatus): \(pyString)")
        let pyData = Data(pyString.trimmingCharacters(in: .whitespacesAndNewlines).utf8)

        // Canonicalize both through the same serializer (sorted keys) so whitespace/order can't mask a real diff.
        let swiftObj = try JSONSerialization.jsonObject(with: swiftData)
        let pyObj = try JSONSerialization.jsonObject(with: pyData)
        let swiftCanonical = try JSONSerialization.data(withJSONObject: swiftObj, options: [.sortedKeys])
        let pyCanonical = try JSONSerialization.data(withJSONObject: pyObj, options: [.sortedKeys])
        let swiftStr = String(data: swiftCanonical, encoding: .utf8) ?? "?"
        let pyStr = String(data: pyCanonical, encoding: .utf8) ?? "?"
        #expect(
            swiftCanonical == pyCanonical,
            "renderGraph != harness inject():\nswift=\(swiftStr)\npy=\(pyStr)"
        )
    }
}
