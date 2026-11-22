import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Qwen-Image 2.1 Turbo loads the published mflux-community repo for each
/// precision on the CLI and the warm driver alike, always with `--base-model` (mflux 0.24.0 otherwise runs these repo
/// names on the base model's 40-step config), and sizes an edit from its
/// references unless the job asks for a size.
@MainActor
struct Qwen21RouteTests {
    private let ctx = JobRunContext(
        seed: 7, outputFile: "/tmp/out.png",
        stepwiseDir: FileManager.default.temporaryDirectory, promptFile: nil, python: nil, baseModelSupported: nil
    )

    private func settings() -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        return settings
    }

    private func args(_ job: Qwen21Job) -> [String] {
        Qwen21RunnerSpec.buildArgs(job: job, ctx: ctx, settings: settings())
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    @Test(arguments: [
        (0, "mflux-community/qwen-image-2-1-turbo-mflux-bf16"),
        (8, "mflux-community/qwen-image-2-1-turbo-mflux-q8"),
        (4, "mflux-community/qwen-image-2-1-turbo-mflux-q4"),
    ])
    func eachPrecisionLoadsItsRepo(quantize: Int, repo: String) {
        let args = args(Qwen21Job(prompt: "a fox", quantize: quantize))
        #expect(value(after: "--model", in: args) == repo)
        #expect(value(after: "--base-model", in: args) == "qwen-image-2.1-turbo")
        #expect(!args.contains("--quantize"))
    }

    @Test func customCheckpointStillNamesTheTurboBase() {
        let args = args(Qwen21Job(prompt: "a fox", customModelRepo: "/models/my-qwen21-finetune"))
        #expect(value(after: "--model", in: args) == "/models/my-qwen21-finetune")
        #expect(value(after: "--base-model", in: args) == "qwen-image-2.1-turbo")
    }

    @Test func generateSendsTheSizeAndNoReferences() {
        // References left over from Edit mode are not sent once the job is in Generate mode.
        let args = args(Qwen21Job(isEditMode: false, editImagePaths: ["/a.png"], prompt: "a fox", width: 1344, height: 768))
        #expect(value(after: "--width", in: args) == "1344")
        #expect(value(after: "--height", in: args) == "768")
        #expect(!args.contains("--image-paths"))
    }

    @Test func editFollowsTheReferencesByDefault() throws {
        let job = Qwen21Job(isEditMode: true, editImagePaths: ["/subject.png", "/scene.png"], prompt: "combine")
        let args = args(job)
        let start = try #require(args.firstIndex(of: "--image-paths"))
        #expect(Array(args[(start + 1) ... (start + 2)]) == ["/subject.png", "/scene.png"])
        #expect(!args.contains("--width"))
        #expect(!args.contains("--height"))
    }

    @Test func editWithAChosenSizeSendsIt() {
        let job = Qwen21Job(
            isEditMode: true, editImagePaths: ["/subject.png"], matchReferenceSize: false,
            prompt: "night", width: 768, height: 1344
        )
        let args = args(job)
        #expect(value(after: "--width", in: args) == "768")
        #expect(value(after: "--height", in: args) == "1344")
    }

    @Test func onlyEnabledQwenLorasAreSent() {
        let job = Qwen21Job(prompt: "a fox", loras: [
            LoraEntry(path: "/loras/qwen21-style.safetensors", strength: 0.8, modelFamily: .qwen21),
            LoraEntry(path: "/loras/krea2-style.safetensors", strength: 0.5, modelFamily: .krea2),
        ])
        let args = args(job)
        #expect(value(after: "--lora-paths", in: args) == "/loras/qwen21-style.safetensors")
        #expect(value(after: "--lora-scales", in: args) == "0.80")
        #expect(!args.contains("/loras/krea2-style.safetensors"))
    }

    @Test func batchSendsEverySeed() throws {
        let job = Qwen21Job(prompt: "a fox", seeds: [1, 2, 3])
        let args = args(job)
        let start = try #require(args.firstIndex(of: "--seed"))
        #expect(Array(args[(start + 1) ... (start + 3)]) == ["1", "2", "3"])
    }

    @Test func warmDriverGetsTheSameRouteAsTheCLI() throws {
        let job = Qwen21Job(isEditMode: true, editImagePaths: ["/subject.png", "/scene.png"], prompt: "combine", quantize: 4)
        let request = try #require(Qwen21RunnerSpec.driverRequest(job: job, ctx: ctx, settings: settings()))
        #expect(request.family == "qwen21")
        #expect(request.model == "mflux-community/qwen-image-2-1-turbo-mflux-q4")
        #expect(request.baseModel == "qwen-image-2.1-turbo")
        #expect(request.quantize == nil)
        #expect(request.imagePaths == ["/subject.png", "/scene.png"])
        #expect(request.width == nil && request.height == nil)
    }

    @Test func enhancedEditAsksMfluxToRewriteOnBothPaths() throws {
        let job = Qwen21Job(isEditMode: true, editImagePaths: ["/subject.png"], prompt: "make it night", enhancePrompt: true)
        #expect(args(job).contains("--enhance-prompt"))
        #expect(try #require(Qwen21RunnerSpec.driverRequest(job: job, ctx: ctx, settings: settings())).enhancePrompt == true)
        #expect(!args(Qwen21Job(isEditMode: true, editImagePaths: ["/subject.png"])).contains("--enhance-prompt"))
    }

    /// mflux rejects `--enhance-prompt` without a reference, so a Generate job queued for ComfyUI's enhancer that
    /// falls back to local drops the flag, while an edit keeps it.
    @Test func localFallbackKeepsTheEnhancerOnlyForEdits() {
        let generate = Qwen21Job(prompt: "a fox", enhancePrompt: true)
        Qwen21RunnerSpec.willRunLocally(job: generate)
        #expect(!generate.enhancePrompt)
        #expect(!args(generate).contains("--enhance-prompt"))

        let edit = Qwen21Job(isEditMode: true, editImagePaths: ["/subject.png"], enhancePrompt: true)
        Qwen21RunnerSpec.willRunLocally(job: edit)
        #expect(edit.enhancePrompt)
    }

    @Test func warmDriverSendsTheSizeInGenerateMode() throws {
        let job = Qwen21Job(isEditMode: false, editImagePaths: ["/a.png"], prompt: "a fox", width: 1344, height: 768)
        let request = try #require(Qwen21RunnerSpec.driverRequest(job: job, ctx: ctx, settings: settings()))
        #expect(request.imagePaths == [])
        #expect(request.width == 1344 && request.height == 768)
    }

    @Test func precisionAndLorasChangeTheWarmFingerprint() throws {
        func fingerprint(_ job: Qwen21Job) throws -> String {
            try #require(Qwen21RunnerSpec.driverRequest(job: job, ctx: ctx, settings: settings())).fingerprint
        }
        let lora = LoraEntry(path: "/loras/qwen21-style.safetensors", strength: 0.8, modelFamily: .qwen21)
        let q8 = try fingerprint(Qwen21Job(quantize: 8))
        #expect(try q8 != fingerprint(Qwen21Job(quantize: 4)))
        #expect(try q8 != fingerprint(Qwen21Job(quantize: 8, loras: [lora])))
        // Switching Generate and Edit reuses the resident model.
        #expect(try q8 == fingerprint(Qwen21Job(isEditMode: true, editImagePaths: ["/a.png"], quantize: 8)))
    }

    @Test func everyCLIRunTilesTheDecode() {
        #expect(args(Qwen21Job(prompt: "a fox")).contains("--vae-tiling"))
        // --low-ram implies tiling.
        let lowRam = args(Qwen21Job(prompt: "a fox", lowRam: true))
        #expect(lowRam.contains("--low-ram") && !lowRam.contains("--vae-tiling"))
    }

    @Test func noStepwisePreviewsOnEitherPath() throws {
        #expect(!args(Qwen21Job(prompt: "a fox")).contains("--stepwise-image-output-dir"))
        let request = try #require(Qwen21RunnerSpec.driverRequest(job: Qwen21Job(prompt: "a fox"), ctx: ctx, settings: settings()))
        #expect(request.stepwiseDir.isEmpty)
    }

    /// The RAM label shows the measured peak for the path the job runs on; download sizes are untouched.
    @Test func ramLabelFollowsTheRunPath() {
        let model = FluxModelVariant.qwen21Turbo
        let settings = settings()
        settings.comfyBackendEnabled[ModelFamily.qwen21.id] = false
        settings.keepModelWarm = false
        settings.warmTextEncoderPolicy = .auto
        settings.updateDefaults(ModelDefaults(), for: model)
        #expect(model.approximateRAMGB(quantize: 4, settings: settings) == 10.3) // CLI, the default
        settings.keepModelWarm = true
        #expect(model.approximateRAMGB(quantize: 8, settings: settings) == 24.4) // warm, Automatic keeps the encoder
        settings.warmTextEncoderPolicy = .evict
        #expect(model.approximateRAMGB(quantize: 0, settings: settings) == 33.2)
        var lowRam = settings.defaults(for: model)
        lowRam.lowRam = true
        settings.updateDefaults(lowRam, for: model)
        #expect(model.approximateRAMGB(quantize: 0, settings: settings) == 24.8) // low RAM stays on the CLI
        #expect(model.approximateSizeGB(quantize: 0) == 32.5)
        #expect(FluxModelVariant.krea2.approximateRAMGB(quantize: 8, settings: settings) == 22.2)

        // Routed to ComfyUI, the server's memory is what counts: the label falls back to the weight size.
        settings.comfyBackendEnabled[ModelFamily.qwen21.id] = true
        settings.comfyURL = "http://127.0.0.1:1"
        settings.comfyUNet[ModelFamily.qwen21.id] = "unet.safetensors"
        settings.comfyClip[ModelFamily.qwen21.id] = "clip.safetensors"
        settings.comfyVae[ModelFamily.qwen21.id] = "vae.safetensors"
        #expect(model.approximateRAMGB(quantize: 8, settings: settings) == 17.8)
    }

    @Test func lowRamStaysOnTheCLI() {
        #expect(Qwen21RunnerSpec.driverRequest(job: Qwen21Job(lowRam: true), ctx: ctx, settings: settings()) == nil)
    }

    @Test func loraNamesForQwen21BeatKrea2sQwenToken() {
        #expect(LoraBaseModelHeuristic.guess(for: "qwen-image-2.1-turbo-outpaint.safetensors") == .matched(.qwen21))
        #expect(LoraBaseModelHeuristic.guess(for: "Qwen_Image_2_1_consistency.safetensors") == .matched(.qwen21))
        // The bare Qwen-Image token still means Krea 2.
        #expect(LoraBaseModelHeuristic.guess(for: "qwen-image-style.safetensors") == .matched(.krea2))
    }

    @Test func batchSeedsAreDistinct() {
        // A repeat would share its `_seed_N` file and break the batch's seed↔path pairing.
        #expect(Set(RunnerSupport.randomSeeds(count: 10)).count == 10)
        let params = Qwen21ParamsPanelState()
        params.prompt = "a fox"
        let seeds = params.makeJob(count: 6).seeds
        #expect(seeds.count == 6 && Set(seeds).count == 6)
    }

    @Test func typedBatchSeedsDropRepeats() {
        // Ideogram 4's typed seed list is the one way a batch can repeat a seed.
        let params = Ideogram4ParamsPanelState()
        params.batchSeeds = [11, 11, 22, 11]
        #expect(params.makeJob().seeds == [11, 22])
    }

    @Test func aSingleTypedSeedRunsAsAPlainJob() {
        // mflux adds `_seed_N` only for 2+ seeds, so a one-seed "batch" would be looked for under the wrong name.
        let params = Ideogram4ParamsPanelState()
        params.batchSeeds = [11, 11]
        let job = params.makeJob()
        #expect(job.seeds.isEmpty)
        #expect(job.seed == 11)
    }

    @Test func makeJobSnapsSizesToMfluxsMultipleOf32() {
        // A saved form or Settings default can predate the 32 px constraint.
        let params = Qwen21ParamsPanelState()
        params.prompt = "a fox"
        params.width = 1040
        params.height = 200
        let job = params.makeJob()
        #expect(job.width % 32 == 0 && job.height % 32 == 0)
        #expect(job.height == 256) // the Qwen minimum
        let directed = params.makeJob(size: (width: 1000, height: 1000))
        #expect(directed.width % 32 == 0 && directed.height % 32 == 0)
    }

    @Test func anUpscaleKeepsItsQwenSourceRecipe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("qwen21_20261114_seed_7.png").path
        var meta = Qwen21Metadata.from(job: Qwen21Job(prompt: "a fox in snow", steps: 8, width: 1344, height: 768))
        meta.seed = 7
        MetadataSidecar.write(meta, for: source)

        let resolved = SeedVR2Metadata.resolveSource(for: source)
        #expect(resolved.qwen21?.prompt == "a fox in snow")
        let fields = try #require(SeedVR2DisplayFields(source: resolved))
        #expect(fields.sourceModel == "Qwen Image 2.1 Turbo")
        #expect(fields.seed == 7 && fields.width == 1344 && fields.height == 768)
    }

    @Test func aRenamedQwenSourceStillResolves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("portrait.png").path
        MetadataSidecar.write(Qwen21Metadata.from(job: Qwen21Job(prompt: "renamed")), for: source)
        let resolved = SeedVR2Metadata.resolveSource(for: source)
        #expect(resolved.qwen21?.prompt == "renamed")
        #expect(resolved.krea2 == nil && resolved.zimage == nil && resolved.flux == nil)
    }

    @Test func oldHistoryEntriesDecodeWithDefaults() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","prompt":"a fox"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(Qwen21Job.self, from: Data(json.utf8))
        #expect(job.prompt == "a fox")
        #expect(job.steps == 8)
        #expect(!job.isEditMode)
        #expect(job.matchReferenceSize)
        #expect(job.status == .pending)
    }
}
