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
        stepwiseDir: FileManager.default.temporaryDirectory, promptFile: nil
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
        #expect(Qwen21RunnerSpec.quantSaveDestination(job: Qwen21Job(quantize: quantize), settings: settings()) == nil)
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

    @Test func lowRamStaysOnTheCLI() {
        #expect(Qwen21RunnerSpec.driverRequest(job: Qwen21Job(lowRam: true), ctx: ctx, settings: settings()) == nil)
    }

    @Test func loraNamesForQwen21BeatKrea2sQwenToken() {
        #expect(LoraBaseModelHeuristic.guess(for: "qwen-image-2.1-turbo-outpaint.safetensors") == .matched(.qwen21))
        #expect(LoraBaseModelHeuristic.guess(for: "Qwen_Image_2_1_consistency.safetensors") == .matched(.qwen21))
        // The bare Qwen-Image token still means Krea 2.
        #expect(LoraBaseModelHeuristic.guess(for: "qwen-image-style.safetensors") == .matched(.krea2))
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
