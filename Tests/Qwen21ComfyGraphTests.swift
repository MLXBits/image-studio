import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// ``Qwen21RunnerSpec/comfyGraph(job:settings:client:)`` against the bundled qwen21 templates.
/// Serialized: the edit tests share `StubUploadProtocol`'s static request log with the FLUX.2 suite.
@Suite("Qwen21RunnerSpec.comfyGraph", .serialized)
struct Qwen21ComfyGraphTests {
    private static let familyID = ModelFamily.qwen21.id

    private static func settings(enhancer: Bool = false) -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.comfyUNet = [familyID: "unet.safetensors"]
        settings.comfyClip = [familyID: "clip.safetensors"]
        if enhancer {
            settings.comfyClip[Qwen21RunnerSpec.enhancerClipKey] = "pe.safetensors"
        }
        settings.comfyVae = [familyID: "vae.safetensors"]
        return settings
    }

    private static func stubClient() -> ComfyUIClient {
        let cfg = URLSessionConfiguration.default
        cfg.protocolClasses = [StubUploadProtocol.self]
        return ComfyUIClient(config: .init(baseURL: "http://127.0.0.1:1"), session: URLSession(configuration: cfg))
    }

    private static func graph(_ job: Qwen21Job, _ settings: AppSettings) async throws -> [String: [String: Any]] {
        let built = try #require(try await Qwen21RunnerSpec.comfyGraph(job: job, settings: settings, client: stubClient()))
        let raw = try #require(built.build(42) as? [String: Any])
        return raw.compactMapValues { $0 as? [String: Any] }
    }

    private static func inputs(_ graph: [String: [String: Any]], _ id: String) -> [String: Any] {
        graph[id]?["inputs"] as? [String: Any] ?? [:]
    }

    private static func ids(ofClass cls: String, in graph: [String: [String: Any]]) -> [String] {
        graph.filter { $0.value["class_type"] as? String == cls }.map(\.key)
    }

    /// Every `[nodeID, slot]` ref resolves to a node in the graph.
    private static func expectNoDanglingRefs(_ graph: [String: [String: Any]]) {
        for (id, _) in graph {
            for (name, value) in inputs(graph, id) {
                if let ref = value as? [Any], ref.count == 2, let src = ref[0] as? String {
                    #expect(graph[src] != nil, "\(id).\(name) -> \(src)")
                }
            }
        }
    }

    private static func tempImage() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qwen21-test-\(UUID().uuidString).png")
        try Data("test-image".utf8).write(to: url)
        return url.path
    }

    private static func values(_ sigmas: String) -> [Double] {
        sigmas.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    @Test func sigmasKeepTheTemplateScheduleAtEightSteps() throws {
        let template = try ComfyTemplate.load(familyFlowKey: "qwen21/t2i")
        guard case let .scalar(.string(baked)) = template.nodes["459:484"]?.inputs["sigmas"] else {
            Issue.record("no baked sigmas"); return
        }
        #expect(Self.values(Qwen21RunnerSpec.comfySigmas(steps: 8)) == Self.values(baked))
    }

    @Test func sigmasResampleOtherStepCounts() {
        let values = Self.values(Qwen21RunnerSpec.comfySigmas(steps: 4))
        #expect(values.count == 5)
        #expect(values.first == 1)
        #expect(values.last == 0)
        #expect(values == values.sorted(by: >))
        #expect(values[2] == 0.89508) // the 8-step schedule's midpoint
    }

    /// With thinking on, ComfyUI's TextGenerate nodes return an empty string for this enhancer, and the
    /// encoder then gets an empty prompt. A re-export of the templates must keep it off.
    @Test(arguments: ["qwen21/t2i", "qwen21/edit"])
    func enhancerThinkingIsOff(key: String) throws {
        let template = try ComfyTemplate.load(familyFlowKey: key)
        let generators = template.nodes.values.filter { $0.classType.hasPrefix("TextGenerate") }
        #expect(generators.count == 1)
        #expect(generators.allSatisfy { $0.inputs["thinking"] == .scalar(.bool(false)) })
    }

    @Test func incompleteFilesRunLocally() async throws {
        let settings = Self.settings()
        settings.comfyVae = [:]
        let graph = try await Qwen21RunnerSpec.comfyGraph(job: Qwen21Job(prompt: "a cat"), settings: settings, client: Self.stubClient())
        #expect(graph?.totalNodes == nil)
    }

    @Test func enhancerWithoutItsClipFailsTheJob() async {
        await #expect(throws: Qwen21ComfyGraphError.noEnhancerClip) {
            _ = try await Qwen21RunnerSpec.comfyGraph(
                job: Qwen21Job(prompt: "a cat", enhancePrompt: true), settings: Self.settings(), client: Self.stubClient()
            )
        }
    }

    @Test func generateWithoutEnhancerPrunesItsBranch() async throws {
        let job = Qwen21Job(prompt: "a cat", width: 1344, height: 768)
        let graph = try await Self.graph(job, Self.settings())
        for cls in ["TextGenerateV2", "PreviewAny", "PrimitiveStringMultiline", "ComfySwitchNode"] {
            #expect(Self.ids(ofClass: cls, in: graph).isEmpty, "\(cls) left in the graph")
        }
        #expect(Self.ids(ofClass: "CLIPLoader", in: graph) == ["459:453"])
        #expect(Self.inputs(graph, "459:452")["prompt"] as? String == "a cat")
        #expect(Self.inputs(graph, "459:488")["noise_seed"] as? Int == 42)
        #expect(Self.inputs(graph, "459:456")["width"] as? Int == 1344)
        #expect(Self.inputs(graph, "461")["filename_prefix"] as? String == "mlxbits/qwen21")
        Self.expectNoDanglingRefs(graph)
    }

    @Test func editWiresEveryReferenceIntoEncoderAndEnhancer() async throws {
        let paths = try (0 ..< 3).map { _ in try Self.tempImage() }
        defer { paths.forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let job = Qwen21Job(isEditMode: true, editImagePaths: paths, prompt: "swap the hats", enhancePrompt: true)
        let graph = try await Self.graph(job, Self.settings(enhancer: true))

        #expect(Self.ids(ofClass: "LoadImage", in: graph).count == 3)
        let encoder = Self.inputs(graph, "459:509")
        let batch = Self.inputs(graph, "459:508")
        for n in 2 ... 3 {
            #expect((encoder["images.image_\(n)"] as? [Any])?.first as? String == "ref_\(n)")
            #expect((batch["images.image\(n - 1)"] as? [Any])?.first as? String == "ref_\(n)")
        }
        #expect(Self.inputs(graph, "459:500")["prompt"] as? String == "swap the hats")
        #expect(Self.inputs(graph, "459:477")["clip_name"] as? String == "pe.safetensors")
        #expect(Self.inputs(graph, "459:468")["switch"] as? Bool == false) // follows the reference size
        Self.expectNoDanglingRefs(graph)
    }

    @Test func loraChainFeedsTheCacheNode() async throws {
        let lora = LoraEntry(path: "/loras/style.safetensors", strength: 0.7, modelFamily: .qwen21)
        let graph = try await Self.graph(Qwen21Job(prompt: "a cat", loras: [lora]), Self.settings())
        #expect(Self.inputs(graph, "lora_ins_0")["model"] as? [AnyHashable] == ["459:451", 0])
        #expect(Self.inputs(graph, "459:490")["model"] as? [AnyHashable] == ["lora_ins_0", 0])
    }
}
