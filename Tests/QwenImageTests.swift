import Foundation
@testable import MLXBits_Image_Studio
import Testing

struct QwenImageRunnerArgsTests {
    private let ctx = JobRunContext(
        seed: 42, outputFile: "/tmp/qwenimage_out.png",
        stepwiseDir: URL(fileURLWithPath: "/tmp/stepwise-qwenimage"), promptFile: nil
    )

    private func args(_ job: QwenImageJob, modelSource: String? = nil, cacheGB: Double = 0) -> [String] {
        QwenImageRunnerSpec.arguments(job: job, ctx: ctx, modelSource: modelSource, mlxCacheLimitGB: cacheGB)
    }

    /// The value following `flag`, or nil when the flag is absent.
    private func value(_ flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    @Test func defaultsRunTheRegistryModelAtBF16GuidanceFree() {
        let a = args(QwenImageJob(prompt: "a fox"))
        #expect(value("--model", in: a) == "qwen-image-2.1")
        #expect(!a.contains("--quantize"))
        #expect(!a.contains("--base-model"))
        #expect(value("--steps", in: a) == "40")
        #expect(value("--guidance", in: a) == "1.00")
        #expect(value("--seed", in: a) == "42")
        #expect(value("--output", in: a) == "/tmp/qwenimage_out.png")
        #expect(!a.contains("--negative-prompt"))
        #expect(!a.contains("--image"))
        #expect(!a.contains("--mlx-cache-limit-gb"))
    }

    @Test func quantizeIsAppliedInMemory() {
        #expect(value("--quantize", in: args(QwenImageJob(prompt: "p", quantize: 8))) == "8")
        #expect(value("--quantize", in: args(QwenImageJob(prompt: "p", quantize: 4))) == "4")
    }

    /// mflux runs true CFG only when guidance > 1 and a negative prompt is set.
    @Test func negativePromptOnlyTravelsWithTrueCFG() {
        let guidanceFree = args(QwenImageJob(prompt: "p", negativePrompt: "blurry", guidance: 1.0))
        #expect(!guidanceFree.contains("--negative-prompt"))

        let cfg = args(QwenImageJob(prompt: "p", negativePrompt: "blurry", guidance: 4.0))
        #expect(value("--negative-prompt", in: cfg) == "blurry")
        #expect(value("--guidance", in: cfg) == "4.00")

        let blank = args(QwenImageJob(prompt: "p", negativePrompt: "  \n", guidance: 4.0))
        #expect(!blank.contains("--negative-prompt"))
    }

    @Test func img2imgUsesTheAtomicImageFlag() {
        let a = args(QwenImageJob(prompt: "p", imagePath: "/tmp/in.png", imageStrength: 0.6))
        let i = a.firstIndex(of: "--image")
        #expect(i.map { Array(a[$0 ... $0 + 2]) } == ["--image", "/tmp/in.png", "0.60"])
        #expect(!a.contains("--image-path"))
    }

    @Test func customCheckpointPinsTheBaseModelAndSkipsQuantize() {
        let a = args(QwenImageJob(prompt: "p", quantize: 8), modelSource: "org/qwen-finetune")
        #expect(value("--model", in: a) == "org/qwen-finetune")
        #expect(value("--base-model", in: a) == "qwen-image-2.1")
        #expect(!a.contains("--quantize"))
    }

    @Test func batchSeedsAreAllPassed() {
        let a = args(QwenImageJob(prompt: "p", seeds: [7, 8, 9]))
        let i = a.firstIndex(of: "--seed")
        #expect(i.map { Array(a[$0 ... $0 + 3]) } == ["--seed", "7", "8", "9"])
    }

    @Test func mlxCacheLimitIsForwarded() {
        #expect(value("--mlx-cache-limit-gb", in: args(QwenImageJob(prompt: "p"), cacheGB: 8)) == "8.0")
    }
}

struct QwenImageCatalogTests {
    @Test func variantRunsThroughItsOwnFamilyAndCLI() {
        let v = FluxModelVariant.qwenImage21
        #expect(v.family == .qwenImage)
        #expect(v.isQwenImage)
        #expect(!v.isFlux)
        #expect(v.generateCLIName == "mflux-generate-qwen-2.1")
        #expect(v.mfluxModelID == "qwen-image-2.1")
        #expect(v.defaultSteps == 40)
        #expect(v.defaultGuidance == 1.0)
        #expect(v.promptTokenSoftCap == 2048)
        #expect(FluxModelVariant.allModels.contains(v))
    }

    @Test func familyIsGenerativeButOutsideTheLoraSurfaces() {
        #expect(ModelFamily.generative.contains(.qwenImage))
        #expect(!ModelFamily.qwenImage.supportsLoras)
        #expect(ModelFamily.zimage.supportsLoras)
        #expect(!ModelFamily.seedvr2.supportsLoras)
    }

    /// Every precision quantizes the one official BF16 repo in memory, so Settings
    /// downloads that repo directly and lists a single cached entry.
    @Test func everyPrecisionSharesTheOneBF16Download() {
        let v = FluxModelVariant.qwenImage21
        for q in [0, 4, 8] {
            #expect(v.directDownloadRepoID(quantize: q) == "Qwen/Qwen-Image-2.1")
            #expect(v.approximateDownloadGB(quantize: q) == v.approximateBF16SizeGB)
        }
        #expect(v.cachedQuantizeLevels == [0])
        #expect(v.approximateSizeGB(quantize: 0) > v.approximateSizeGB(quantize: 8))
        #expect(v.approximateSizeGB(quantize: 8) > v.approximateSizeGB(quantize: 4))
    }

    @Test func otherModelsKeepTheirDownloadRouting() {
        #expect(FluxModelVariant.zimageTurbo.directDownloadRepoID(quantize: 4) == "filipstrand/Z-Image-Turbo-mflux-4bit")
        #expect(FluxModelVariant.zimageTurbo.directDownloadRepoID(quantize: 8) == nil)
        #expect(FluxModelVariant.ideogram4.directDownloadRepoID(quantize: 0) == "ideogram-ai/ideogram-4-fp8")
        #expect(FluxModelVariant.flux2Klein9B.directDownloadRepoID(quantize: 0) == nil)
        #expect(FluxModelVariant.krea2.cachedQuantizeLevels == [0, 4, 8])
    }

    @Test func dimensionsSnapToSixteens() {
        let c = DimensionConstraints.qwenImage
        #expect(c.snap(1000) == 1008)
        #expect(c.snap(100) == 256)
        #expect(c.snap(5000) == 2048)
    }
}

struct QwenImageSidecarTests {
    private func tempImagePath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwenimage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("qwenimage_test.png").path
    }

    @Test func metadataRoundTripsThroughTheSidecar() throws {
        let path = try tempImagePath()
        let job = QwenImageJob(
            prompt: "a lighthouse", negativePrompt: "fog", width: 1280, height: 720,
            steps: 30, guidance: 3.5, quantize: 8, board: "Coast"
        )
        job.resolvedSeed = 1234
        MetadataSidecar.writeQwenImage(QwenImageMetadata.from(job: job), for: path)

        let meta = try #require(MetadataSidecar.readQwenImage(for: path))
        #expect(meta.model == "qwen-image-2.1")
        #expect(meta.prompt == "a lighthouse")
        #expect(meta.negativePrompt == "fog")
        #expect(meta.seed == 1234)
        #expect(meta.width == 1280 && meta.height == 720)
        #expect(meta.steps == 30 && meta.guidance == 3.5 && meta.quantize == 8)
        #expect(meta.board == "Coast")
        #expect(meta.customModelRepo == nil)
    }

    /// A Flux sidecar also carries `model`, so the reader must check its value.
    @Test func aSidecarForAnotherModelIsNotReadAsQwenImage() throws {
        let path = try tempImagePath()
        let json = """
        {"model":"flux2-klein-9b","prompt":"x","seed":1,"steps":4,"guidance":1,
         "width":512,"height":512,"quantize":8,"generatedAt":"2026-09-23T00:00:00Z"}
        """
        try Data(json.utf8).write(to: MetadataSidecar.sidecarURL(for: path))
        #expect(MetadataSidecar.readQwenImage(for: path) == nil)
    }
}

struct HFCacheCompletenessTests {
    /// Newer huggingface_hub keeps payloads in a shared blob store and leaves each
    /// repo's `blobs/` entries as symlinks; the completeness check must size the
    /// link target, not the link.
    @Test func symlinkedBlobsCountTheirTargetSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hfcache-tests-\(UUID().uuidString)", isDirectory: true)
        let store = root.appendingPathComponent("blobs/ab", isDirectory: true)
        let repoBlobs = root.appendingPathComponent("hub/models--Qwen--Qwen-Image-2.1/blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoBlobs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A sparse 1.5 GiB payload: full logical size, no real disk use.
        let payload = store.appendingPathComponent("abcdef")
        FileManager.default.createFile(atPath: payload.path, contents: nil)
        let handle = try FileHandle(forWritingTo: payload)
        try handle.truncate(atOffset: 1_610_612_736)
        try handle.close()

        try FileManager.default.createSymbolicLink(
            atPath: repoBlobs.appendingPathComponent("abcdef").path,
            withDestinationPath: "../../../blobs/ab/abcdef"
        )
        #expect(FluxModelVariant.isCompleteHFCache(at: repoBlobs.deletingLastPathComponent()))
    }

    @Test func aMetadataOnlyRepoIsIncomplete() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("hfcache-tests-\(UUID().uuidString)/models--x--y", isDirectory: true)
        let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        try Data("{}".utf8).write(to: blobs.appendingPathComponent("config"))
        #expect(!FluxModelVariant.isCompleteHFCache(at: repo))
    }
}
