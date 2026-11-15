import Foundation
import ImageIO
@testable import MLXBits_Image_Studio
import Testing

/// Answers uploads like `StubUploadProtocol` without writing its request log: the FLUX.2 suite counts that
/// log, and the two suites run in parallel.
nonisolated private final class QuietUploadProtocol: StubUploadProtocol {
    override func startLoading() {
        respondUploaded()
    }
}

/// ``Qwen21RunnerSpec/comfyGraph(job:settings:client:)`` against the bundled qwen21 templates.
@Suite("Qwen21RunnerSpec.comfyGraph")
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
        cfg.protocolClasses = [QuietUploadProtocol.self]
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

    /// A real PNG of the given size: the edit size is read from the last reference's pixels.
    private static func tempImage(width: Int = 64, height: Int = 64) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qwen21-test-\(UUID().uuidString).png")
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
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
        // The last reference is 2:1, unlike the first: the edit is sized from the last, as on local mflux.
        let paths = try [Self.tempImage(), Self.tempImage(), Self.tempImage(width: 96, height: 48)]
        defer { paths.forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let job = Qwen21Job(isEditMode: true, editImagePaths: paths, prompt: "swap the hats", enhancePrompt: true)
        let graph = try await Self.graph(job, Self.settings(enhancer: true))

        #expect(Self.ids(ofClass: "LoadImage", in: graph).count == 3)
        let encoder = Self.inputs(graph, "459:509")
        let enhancer = Self.inputs(graph, "459:500")
        #expect(Self.ids(ofClass: "BatchImagesNode", in: graph).isEmpty)
        #expect((enhancer["images.image1"] as? [Any])?.first as? String == "470")
        for n in 2 ... 3 {
            #expect((encoder["images.image_\(n)"] as? [Any])?.first as? String == "ref_\(n)")
            #expect((enhancer["images.image\(n)"] as? [Any])?.first as? String == "ref_\(n)")
        }
        #expect(Self.inputs(graph, "459:500")["prompt"] as? String == "swap the hats")
        #expect(Self.inputs(graph, "459:477")["clip_name"] as? String == "pe.safetensors")
        // 2:1 at about 1024², in multiples of 32 (mflux's rule), sampled from the empty latent.
        #expect(Self.inputs(graph, "459:468")["switch"] as? Bool == true)
        #expect(Self.inputs(graph, "459:456")["width"] as? Int == 1440)
        #expect(Self.inputs(graph, "459:456")["height"] as? Int == 736)
        #expect(Self.inputs(graph, "459:509")["resolution"] as? Int == 1024)
        Self.expectNoDanglingRefs(graph)
    }

    /// A chosen size is kept even when its aspect ratio differs from the references', and the references still
    /// encode at 1024 in their own shape, as on local mflux.
    @Test func editAtAChosenSizeKeepsItAndTheReferenceResolution() async throws {
        let square = try Self.tempImage()
        defer { try? FileManager.default.removeItem(atPath: square) }
        let job = Qwen21Job(isEditMode: true, editImagePaths: [square], matchReferenceSize: false, prompt: "x", width: 1344, height: 768)
        let graph = try await Self.graph(job, Self.settings())
        #expect(Self.inputs(graph, "459:456")["width"] as? Int == 1344)
        #expect(Self.inputs(graph, "459:456")["height"] as? Int == 768)
        #expect(Self.inputs(graph, "459:509")["resolution"] as? Int == 1024)
    }

    /// Settings changed while the job was queued: it runs locally, and the sidecar must not claim the enhancer ran.
    @Test func localFallbackClearsEnhancePrompt() {
        let job = Qwen21Job(prompt: "a cat", enhancePrompt: true)
        Qwen21RunnerSpec.willRunLocally(job: job)
        #expect(!job.enhancePrompt)
        #expect(Qwen21Metadata.from(job: job).enhancePrompt == nil)
    }

    @Test func unreadableLastReferenceFailsTheJob() {
        let job = Qwen21Job(isEditMode: true, editImagePaths: ["/nonexistent/ref.png"])
        #expect(throws: Qwen21ComfyGraphError.unreadableReference) {
            _ = try Qwen21RunnerSpec.editSize(job: job)
        }
    }

    @Test func loraChainFeedsTheCacheNode() async throws {
        let lora = LoraEntry(path: "/loras/style.safetensors", strength: 0.7, modelFamily: .qwen21)
        let graph = try await Self.graph(Qwen21Job(prompt: "a cat", loras: [lora]), Self.settings())
        #expect(Self.inputs(graph, "lora_ins_0")["model"] as? [AnyHashable] == ["459:451", 0])
        #expect(Self.inputs(graph, "459:490")["model"] as? [AnyHashable] == ["lora_ins_0", 0])
    }
}
