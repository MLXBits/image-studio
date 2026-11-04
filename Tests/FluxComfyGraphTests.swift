import Foundation
@testable import MLXBits_Image_Studio
import os
import Testing

// MARK: - FLUX.2 comfyGraph (Task 4)

/// Stands in for a ComfyUI server's `/upload/image` endpoint. Installed as the protocol class of the
/// test session injected through ``ComfyUIClient/init(config:session:)``; `canInit` matches only
/// `http://127.0.0.1/upload/image`, so any other request on that session passes through to the real
/// transport.
nonisolated private final class StubUploadProtocol: URLProtocol {
    /// The server filename every upload "lands" as.
    static let uploadedName = "uploaded_ref.png"
    /// Backing store for ``requestedPaths``. URLSession writes it from its own thread while tests
    /// reset and read it on the main actor, so every access goes through the lock.
    private static let requestLog = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Paths of every intercepted request, in order (suite is serialized; reset per test).
    static var requestedPaths: [String] {
        get { requestLog.withLock { $0 } }
        set { requestLog.withLock { $0 = newValue } }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.path == "/upload/image"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestLog.withLock { $0.append(url.path) }
        let body = Data(#"{"name": "uploaded_ref.png", "subfolder": "", "type": "input"}"#.utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The FLUX.2 remote-routing entry point: ``FluxRunnerSpec/comfyGraph(job:settings:client:)``.
/// The four FLUX.2 variants map to eight bundled templates (`flux2/<size>-<flow>-<variant>`); FLUX.3
/// is a separate workstream and stays local, as does any variant whose model files aren't fully
/// configured. Serialized: the upload tests share `StubUploadProtocol`'s static request log.
@Suite("FluxRunnerSpec.comfyGraph (FLUX.2)", .serialized)
struct FluxComfyGraphTests {
    // MARK: Fixtures

    /// The repo's `Resources/comfy_templates/flux2` dir, resolved from this file's location.
    private static var templateDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/comfy_templates/flux2")
    }

    /// True when the flux2 templates are in the app bundle (the `comfyGraph` path loads from there).
    nonisolated private static var templatesBundled: Bool {
        (try? ComfyTemplate.load(familyFlowKey: "flux2/4b-t2i-distilled")) != nil
    }

    /// The same decode path as ``ComfyParamMap/load(familyFlowKey:)``, pointed at the repo file
    /// instead of the app bundle (filenames match the loader's layout).
    private static func loadParamMap(_ key: String) throws -> ComfyParamMap {
        try JSONDecoder().decode(
            ComfyParamMap.self,
            from: Data(contentsOf: templateDir.appendingPathComponent("\(key).parammap.json"))
        )
    }

    /// Settings with all three FLUX.2 model files configured for one variant — the only gate that
    /// routes a FLUX.2 job remote.
    private static func flux2Settings(_ variantID: String) -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.comfyUNet = [variantID: "unet-\(variantID).safetensors"]
        settings.comfyClip = [variantID: "clip-\(variantID).safetensors"]
        settings.comfyVae = [variantID: "vae-\(variantID).safetensors"]
        return settings
    }

    private static func client() -> ComfyUIClient {
        ComfyUIClient(config: .init(baseURL: "http://127.0.0.1:1"))
    }

    /// A client whose session routes the upload endpoint to `StubUploadProtocol` (the rest of the
    /// transport is never exercised: these tests make no other requests).
    private static func stubClient() -> ComfyUIClient {
        let cfg = URLSessionConfiguration.default
        cfg.protocolClasses = [StubUploadProtocol.self]
        return ComfyUIClient(
            config: .init(baseURL: "http://127.0.0.1:1"), session: URLSession(configuration: cfg)
        )
    }

    // MARK: wire-form accessors (same shape as ComfyRenderTests')

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

    /// The rendered value a param-map param injected, resolved through the map's target.
    private static func injected(
        _ rendered: [String: [String: Any]], _ map: ComfyParamMap, _ param: String
    ) throws -> Any? {
        let target = try #require(map.params[param])
        return try Self.input(#require(rendered[target.node]), target.input)
    }

    // MARK: Helpers

    private static func writeTempImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flux2-test-\(UUID().uuidString).png")
        try Data("test-image".utf8).write(to: url)
        return url
    }

    // MARK: Flow key selection

    @Test func flowKeyMapsVariantAndMode() {
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux2Klein4B, hasRefs: false) == "flux2/4b-t2i-distilled")
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux2Klein9B, hasRefs: false) == "flux2/9b-t2i-distilled")
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux2KleinBase4B, hasRefs: false) == "flux2/4b-t2i-base")
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux2KleinBase9B, hasRefs: false) == "flux2/9b-t2i-base")
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux2Klein4B, hasRefs: true) == "flux2/4b-i2e-distilled")
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux2Klein9B, hasRefs: true) == "flux2/9b-i2e-distilled")
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux2KleinBase4B, hasRefs: true) == "flux2/4b-i2e-base")
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux2KleinBase9B, hasRefs: true) == "flux2/9b-i2e-base")
    }

    @Test func flowKeyIsNilForFlux3AndOtherFamilies() {
        // FLUX.3 is a separate workstream (no bundled templates here); other families have none at all.
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux3Klein, hasRefs: false) == nil)
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux3Klein, hasRefs: true) == nil)
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .flux3KleinBase, hasRefs: true) == nil)
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .krea2, hasRefs: false) == nil)
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .zimage, hasRefs: false) == nil)
        #expect(FluxRunnerSpec.flux2FlowKey(variant: .custom, hasRefs: false) == nil)
    }

    // MARK: (a) t2i — every FLUX.2 variant routes remote

    @Test(.enabled(if: Self.templatesBundled))
    func t2iJobYieldsAComfyGraphForEachVariant() async throws {
        let cases: [(FluxModelVariant, Int)] = [
            (.flux2Klein4B, 16),
            (.flux2Klein9B, 15),
            (.flux2KleinBase4B, 16),
            (.flux2KleinBase9B, 15),
        ]
        for (variant, nodeCount) in cases {
            let job = FluxJob(
                model: variant, prompt: "a panda", width: 512, height: 768, steps: 8, guidance: 3.5
            )
            let graph = try await FluxRunnerSpec.comfyGraph(
                job: job, settings: Self.flux2Settings(variant.rawValue), client: Self.client()
            )
            let g = try #require(graph, "\(variant) t2i should route remote")
            #expect(g.totalNodes == nodeCount, "\(variant) t2i node count")
            #expect(g.totalSteps == 8)

            let rendered = try Self.nodes(g.build(42))
            let size = variant.rawValue.contains("4b") ? "4b" : "9b"
            let kind = variant.isDistilled ? "distilled" : "base"
            // The right template: the 4b graphs carry the PrimitiveStringMultiline prompt node (9b don't);
            // distilled vs Base is asserted below via cfg (1.0 vs the job's guidance).
            let classes = Set(rendered.values.compactMap { $0["class_type"] as? String })
            #expect(classes.contains("PrimitiveStringMultiline") == (size == "4b"), "\(variant) template size")
            let map = try Self.loadParamMap("\(size)-t2i-\(kind)")
            // Prompt, model files, size, and subfolder ride through the param map.
            #expect(try Self.injected(rendered, map, "prompt") as? String == "a panda")
            #expect(
                try Self.injected(rendered, map, "unet_name") as? String == "unet-\(variant.rawValue).safetensors"
            )
            #expect(
                try Self.injected(rendered, map, "clip_name") as? String == "clip-\(variant.rawValue).safetensors"
            )
            #expect(try Self.injected(rendered, map, "vae_name") as? String == "vae-\(variant.rawValue).safetensors")
            #expect(try Self.injected(rendered, map, "width") as? Int == 512)
            #expect(try Self.injected(rendered, map, "height") as? Int == 768)
            #expect(try Self.injected(rendered, map, "save_subfolder") as? String == "mlxbits/flux2")
            // Steps + sampler; cfg is 1.0 for distilled (no CFG branch) and the job's guidance for Base.
            #expect(try Self.injected(rendered, map, "steps") as? Int == 8)
            #expect(try Self.injected(rendered, map, "sampler") as? String == "euler")
            let expectedCfg: Double = variant.isDistilled ? 1.0 : 3.5
            #expect(try Self.injected(rendered, map, "cfg") as? Double == expectedCfg)
            // The per-seed closure swaps only the noise seed.
            #expect(try Self.injected(rendered, map, "seed") as? Int == 42)
        }
    }

    // MARK: (b) i2e — one reference (imagePath)

    @Test(.enabled(if: Self.templatesBundled))
    func i2iJobWithOneRefYieldsAComfyGraphAndUploadsTheSource() async throws {
        StubUploadProtocol.requestedPaths = []

        let image = try Self.writeTempImage()
        let job = FluxJob(model: .flux2Klein4B, prompt: "a panda", steps: 8, imagePath: image.path)
        let graph = try await FluxRunnerSpec.comfyGraph(
            job: job, settings: Self.flux2Settings("flux2-klein-4b"), client: Self.stubClient()
        )
        let g = try #require(graph, "1-ref i2e should route remote")
        #expect(g.totalNodes == 19) // 44-node 6-slot template excised to 1 ref: 44 − 5 slots × 5 nodes = 19
        #expect(g.totalSteps == 8)

        let rendered = try Self.nodes(g.build(7))
        let map = try Self.loadParamMap("4b-i2e-distilled")
        #expect(try Self.injected(rendered, map, "source_image") as? String == StubUploadProtocol.uploadedName)
        #expect(StubUploadProtocol.requestedPaths == ["/upload/image"], "exactly one upload")
    }

    // MARK: (c) incomplete model files stay local

    @Test func incompleteModelFilesYieldNil() async throws {
        // Clear the fields explicitly: `AppSettings()` may load ambient settings.
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.comfyUNet = [:]
        settings.comfyClip = ["flux2-klein-4b": "clip.safetensors"]
        settings.comfyVae = ["flux2-klein-4b": "vae.safetensors"]
        let job = FluxJob(model: .flux2Klein4B, prompt: "a panda")
        let graph = try await FluxRunnerSpec.comfyGraph(job: job, settings: settings, client: Self.client())
        #expect(graph == nil, "missing UNET stays on local mflux")
    }

    // MARK: (d) FLUX.3 is out of scope

    @Test func flux3VariantsYieldNil() async throws {
        // Even with model files configured, FLUX.3 has no bundled templates here — it stays local.
        let settings = Self.flux2Settings("flux3-image-klein")
        for variant in [FluxModelVariant.flux3Klein, .flux3KleinBase] {
            let job = FluxJob(model: variant, prompt: "a panda")
            let graph = try await FluxRunnerSpec.comfyGraph(job: job, settings: settings, client: Self.client())
            #expect(graph == nil, "\(variant) should stay local")
        }
    }

    // MARK: i2e — multi-reference editing

    @Test(.enabled(if: Self.templatesBundled))
    func multiRefEditJobUploadsEachReference() async throws {
        StubUploadProtocol.requestedPaths = []

        let a = try Self.writeTempImage()
        let b = try Self.writeTempImage()
        let job = FluxJob(
            model: .flux2KleinBase9B, prompt: "a panda", steps: 8, isEditMode: true,
            editImagePaths: [a.path, b.path]
        )
        let graph = try await FluxRunnerSpec.comfyGraph(
            job: job, settings: Self.flux2Settings("flux2-klein-base-9b"), client: Self.stubClient()
        )
        let g = try #require(graph, "2-ref edit should route remote")
        #expect(g.totalNodes == 24) // 44-node 6-slot template excised to 2 refs: 44 − 4 slots × 5 nodes = 24

        let rendered = try Self.nodes(g.build(1))
        let map = try Self.loadParamMap("9b-i2e-base")
        #expect(try Self.injected(rendered, map, "source_image") as? String == StubUploadProtocol.uploadedName)
        #expect(try Self.injected(rendered, map, "source_image_1") as? String == StubUploadProtocol.uploadedName)
        #expect(StubUploadProtocol.requestedPaths == ["/upload/image", "/upload/image"], "one upload per reference")
    }

    @Test(.enabled(if: Self.templatesBundled))
    func editModeIgnoresStaleImagePathAndUsesEditRefs() async throws {
        StubUploadProtocol.requestedPaths = []

        let stale = try Self.writeTempImage()
        let a = try Self.writeTempImage()
        let b = try Self.writeTempImage()
        // Stale state from a prior i2i run lingers in `imagePath`; edit mode must route on `editImagePaths`.
        let job = FluxJob(
            model: .flux2KleinBase9B, prompt: "a panda", steps: 8, imagePath: stale.path,
            isEditMode: true, editImagePaths: [a.path, b.path]
        )
        let graph = try await FluxRunnerSpec.comfyGraph(
            job: job, settings: Self.flux2Settings("flux2-klein-base-9b"), client: Self.stubClient()
        )
        let g = try #require(graph, "edit mode should route remote")
        #expect(g.totalNodes == 24) // 2 edit refs: 44-node 6-slot template excised to 2 refs (stale imagePath ignored)

        let rendered = try Self.nodes(g.build(1))
        let map = try Self.loadParamMap("9b-i2e-base")
        #expect(try Self.injected(rendered, map, "source_image") as? String == StubUploadProtocol.uploadedName)
        #expect(try Self.injected(rendered, map, "source_image_1") as? String == StubUploadProtocol.uploadedName)
        #expect(
            StubUploadProtocol.requestedPaths == ["/upload/image", "/upload/image"],
            "one upload per edit ref; stale imagePath not uploaded"
        )
    }

    @Test(.enabled(if: Self.templatesBundled))
    func nonEditModeIgnoresStaleEditRefsAndRoutesT2i() async throws {
        StubUploadProtocol.requestedPaths = []

        let a = try Self.writeTempImage()
        let b = try Self.writeTempImage()
        // Stale state from a prior edit run lingers in `editImagePaths`; non-edit mode with an empty
        // `imagePath` must route t2i (no references), not i2e.
        let job = FluxJob(
            model: .flux2Klein4B, prompt: "a panda", steps: 8, editImagePaths: [a.path, b.path]
        )
        let graph = try await FluxRunnerSpec.comfyGraph(
            job: job, settings: Self.flux2Settings("flux2-klein-4b"), client: Self.stubClient()
        )
        let g = try #require(graph, "t2i should route remote")
        #expect(g.totalNodes == 16) // 4b-t2i-distilled has no reference slots
        #expect(StubUploadProtocol.requestedPaths == [], "stale editImagePaths must not be uploaded")
    }

    @Test func tooManyReferencesThrows() async throws {
        let paths = try (0 ..< 7).map { _ in try Self.writeTempImage().path }
        let job = FluxJob(
            model: .flux2Klein4B, prompt: "a panda", steps: 8, isEditMode: true, editImagePaths: paths
        )
        do {
            _ = try await FluxRunnerSpec.comfyGraph(
                job: job, settings: Self.flux2Settings("flux2-klein-4b"), client: Self.client()
            )
            Issue.record("expected tooManyReferences")
        } catch let error as FluxComfyGraphError {
            #expect(error == .tooManyReferences(got: 7, max: 6))
        }
    }

    /// When remote routing is enabled but the variant's model files are incomplete, an over-limit reference
    /// count must fall back to local mflux (return nil), not throw — the model-file gate runs before the
    /// reference-count shape check.
    @Test func incompleteModelFilesWithTooManyRefsYieldNil() async throws {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.comfyUNet = [:]
        settings.comfyClip = ["flux2-klein-4b": "clip.safetensors"]
        settings.comfyVae = ["flux2-klein-4b": "vae.safetensors"]
        let paths = try (0 ..< 7).map { _ in try Self.writeTempImage().path }
        let job = FluxJob(
            model: .flux2Klein4B, prompt: "a panda", steps: 8, isEditMode: true, editImagePaths: paths
        )
        let graph = try await FluxRunnerSpec.comfyGraph(job: job, settings: settings, client: Self.client())
        #expect(graph == nil, "incomplete files stay local even with an over-limit ref count")
    }

    // MARK: custom checkpoints follow their target

    @Test(.enabled(if: Self.templatesBundled))
    func customCheckpointRoutesByTargetVariant() async throws {
        // A custom checkpoint runs as its target variant, so template + model files follow the target.
        let job = FluxJob(
            model: .custom, customModelRepo: "hf/user/checkpoint", customBaseModel: .flux2Klein9B,
            prompt: "a panda", steps: 8
        )
        let graph = try await FluxRunnerSpec.comfyGraph(
            job: job, settings: Self.flux2Settings("flux2-klein-9b"), client: Self.client()
        )
        let g = try #require(graph, "custom→9B should route remote")
        #expect(g.totalNodes == 15)
    }

    // MARK: LoRAs

    @Test(.enabled(if: Self.templatesBundled))
    func t2iJobMapsEnabledFluxLorasAsFullLoaders() async throws {
        let job = FluxJob(
            model: .flux2Klein4B,
            prompt: "a panda",
            steps: 8,
            loras: [
                LoraEntry(path: "/Users/me/Loras/flux/styleA.safetensors", strength: 0.8, modelFamily: .flux),
                LoraEntry(path: "krea2/other.safetensors", strength: 0.5, modelFamily: .krea2), // wrong family: dropped
                LoraEntry(path: "", strength: 0.5, modelFamily: .flux), // invalid: dropped
            ]
        )
        let graph = try await FluxRunnerSpec.comfyGraph(
            job: job, settings: Self.flux2Settings("flux2-klein-4b"), client: Self.client()
        )
        let g = try #require(graph)
        #expect(g.totalNodes == 16 + 1) // one LoRA node added to the 16-node template

        let rendered = try Self.nodes(g.build(1))
        let loraNodes = rendered.filter { $0.value["class_type"] as? String == "LoraLoader" }
        #expect(loraNodes.count == 1, "only the enabled, valid, .flux LoRA loads")
        let lora = try #require(loraNodes.first?.value)
        // Absolute local paths reduce to the server basename; the .full kind uses LoraLoader (not ModelOnly).
        #expect(try Self.input(lora, "lora_name") as? String == "styleA.safetensors")
        #expect(try Self.input(lora, "strength_model") as? Double == 0.8)
    }
}
