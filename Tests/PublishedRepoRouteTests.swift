import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Every stock model loads its mflux-community repo at every precision, passed as
/// `--model` with no `--quantize`: a Q4 never downloads or loads the BF16 weights
/// (the Krea 2 Q4 that ran out of memory on a 24 GB Mac). A legacy mflux-save copy
/// on disk still wins, so nobody downloads a model twice; an override wins over both.
@MainActor
struct PublishedRepoRouteTests {
    private let ctx = JobRunContext(
        seed: 1, outputFile: "/tmp/out.png",
        stepwiseDir: FileManager.default.temporaryDirectory, promptFile: nil, python: nil, baseModelSupported: nil
    )

    /// `AppSettings()` loads the developer's real settings.json: clear its overrides and
    /// point the mflux cache at an empty temp folder, so nothing on this Mac picks the route.
    private func settings() -> AppSettings {
        let s = AppSettings()
        s.suspendPersistence()
        s.modelDefaults = [:]
        s.ideogram4ModelRepoOverride = nil
        s.mfluxCacheDir = FakeRuntime.tempDirectory("PublishedRepoRouteTests").path
        return s
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    /// A legacy mflux-save copy of `model` at `quantize` in `settings`' cache.
    @discardableResult
    private func writeSavedCopy(_ model: FluxModelVariant, quantize: Int, settings: AppSettings) throws -> URL {
        let saved = model.savedModelPath(quantize: quantize, in: settings.effectiveMfluxCacheDir)
        let transformer = saved.appendingPathComponent("transformer")
        try FileManager.default.createDirectory(at: transformer, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: transformer.appendingPathComponent("0.safetensors").path, contents: nil)
        return saved
    }

    // MARK: - Catalog

    @Test func everyStockModelHasARepoAtEveryLevel() {
        for model in FluxModelVariant.allModels {
            for quantize in [0, 8, 4] {
                let repo = model.publishedRepoID(quantize: quantize)
                #expect(repo?.hasPrefix("mflux-community/") == true, "\(model) at q\(quantize)")
            }
        }
        #expect(FluxModelVariant.custom.publishedRepoID(quantize: 4) == nil)
    }

    // MARK: - Krea 2

    @Test(arguments: [
        (4, "mflux-community/krea-2-turbo-mflux-q4"),
        (8, "mflux-community/krea-2-turbo-mflux-q8"),
        (0, "mflux-community/krea-2-turbo-mflux-bf16"),
    ])
    func krea2LoadsThePublishedRepo(quantize: Int, repo: String) throws {
        let s = settings()
        let job = Krea2Job(prompt: "a fox", quantize: quantize)
        let args = Krea2RunnerSpec.buildArgs(job: job, ctx: ctx, settings: s)
        #expect(value(after: "--model", in: args) == repo)
        #expect(!args.contains("--quantize"))
        let request = try #require(Krea2RunnerSpec.driverRequest(job: job, ctx: ctx, settings: s))
        #expect(request.model == repo)
        #expect(request.quantize == nil)
    }

    @Test func krea2PrefersALegacySavedCopy() throws {
        let s = settings()
        let saved = try writeSavedCopy(.krea2, quantize: 4, settings: s)
        let args = Krea2RunnerSpec.buildArgs(job: Krea2Job(prompt: "a fox", quantize: 4), ctx: ctx, settings: s)
        #expect(value(after: "--model", in: args) == saved.path)
        #expect(!args.contains("--quantize"))
    }

    @Test func krea2OverrideWinsOverASavedCopy() throws {
        let s = settings()
        try writeSavedCopy(.krea2, quantize: 4, settings: s)
        s.modelDefaults[FluxModelVariant.krea2.rawValue] = ModelDefaults(modelRepoOverride: "org/my-krea")
        let args = Krea2RunnerSpec.buildArgs(job: Krea2Job(prompt: "a fox", quantize: 4), ctx: ctx, settings: s)
        #expect(value(after: "--model", in: args) == "org/my-krea")
        #expect(!args.contains("--quantize"))
    }

    // MARK: - Z-Image

    @Test(arguments: [
        (FluxModelVariant.zimageTurbo, 4, "mflux-community/z-image-turbo-mflux-q4"),
        (.zimageTurbo, 8, "mflux-community/z-image-turbo-mflux-q8"),
        (.zimage, 4, "mflux-community/z-image-base-mflux-q4"),
        (.zimage, 0, "mflux-community/z-image-base-mflux-bf16"),
    ])
    func zImageLoadsThePublishedRepo(model: FluxModelVariant, quantize: Int, repo: String) throws {
        let s = settings()
        let job = ZImageJob(modelVariant: model, prompt: "a fox", quantize: quantize)
        let args = ZImageRunnerSpec.buildArgs(job: job, ctx: ctx, settings: s)
        #expect(value(after: "--model", in: args) == repo)
        #expect(!args.contains("--quantize"))
        let request = try #require(ZImageRunnerSpec.driverRequest(job: job, ctx: ctx, settings: s))
        #expect(request.model == repo)
        #expect(request.quantize == nil)
    }

    @Test func zImagePrefersALegacySavedCopy() throws {
        let s = settings()
        let saved = try writeSavedCopy(.zimage, quantize: 8, settings: s)
        let job = ZImageJob(modelVariant: .zimage, prompt: "a fox", quantize: 8)
        let args = ZImageRunnerSpec.buildArgs(job: job, ctx: ctx, settings: s)
        #expect(value(after: "--model", in: args) == saved.path)
    }

    // MARK: - FLUX.2 Klein

    @Test(arguments: [
        (FluxModelVariant.flux2Klein9B, 4, "mflux-community/flux2-klein-9b-mflux-q4"),
        (.flux2Klein4B, 8, "mflux-community/flux2-klein-4b-mflux-q8"),
        (.flux2KleinBase9B, 4, "mflux-community/flux-2-klein-base-9b-mflux-q4"),
        (.flux2KleinBase4B, 0, "mflux-community/flux-2-klein-base-4b-mflux-bf16"),
    ])
    func kleinLoadsThePublishedRepo(model: FluxModelVariant, quantize: Int, repo: String) throws {
        let s = settings()
        let job = FluxJob(model: model, prompt: "a fox", quantize: quantize)
        #expect(FluxRunnerSpec.modelRoute(job: job, settings: s) == .published(repo: repo, baseKey: nil))
        let args = FluxRunnerSpec.buildArgs(job: job, ctx: ctx, settings: s)
        #expect(value(after: "--model", in: args) == repo)
        #expect(!args.contains("--quantize"))
        let request = try #require(FluxRunnerSpec.driverRequest(job: job, ctx: ctx, settings: s))
        #expect(request.model == repo)
        #expect(request.quantize == nil)
    }

    @Test func kleinPrefersALegacySavedCopy() throws {
        let s = settings()
        let saved = try writeSavedCopy(.flux2Klein9B, quantize: 4, settings: s)
        let job = FluxJob(model: .flux2Klein9B, prompt: "a fox", quantize: 4)
        #expect(FluxRunnerSpec.modelRoute(job: job, settings: s) == .saved(saved))
        let request = try #require(FluxRunnerSpec.driverRequest(job: job, ctx: ctx, settings: s))
        #expect(request.model == saved.path)
        #expect(request.quantize == nil)
    }

    /// A custom checkpoint is quantized in memory, as before: it names no published level.
    @Test func aCustomCheckpointStillQuantizesInMemory() {
        let job = FluxJob(model: .custom, customModelRepo: "org/my-klein", prompt: "a fox", quantize: 4)
        let args = FluxRunnerSpec.buildArgs(job: job, ctx: ctx, settings: settings())
        #expect(value(after: "--quantize", in: args) == "4")
    }

    // MARK: - Ideogram 4

    @Test func ideogramBF16LoadsThePublishedRepo() {
        let job = Ideogram4Job(usePlainPrompt: true, plainPrompt: "a panda", quantize: 0)
        let args = Ideogram4RunnerSpec.buildArgs(job: job, ctx: ctx, settings: settings())
        #expect(value(after: "--model", in: args) == "mflux-community/ideogram-4-mflux-bf16")
        #expect(!args.contains("--quantize"))
    }

    /// Ideogram's old saved copies are stale, so its published repo wins over one.
    @Test func ideogramIgnoresALegacySavedCopy() throws {
        let s = settings()
        try writeSavedCopy(.ideogram4, quantize: 4, settings: s)
        let job = Ideogram4Job(usePlainPrompt: true, plainPrompt: "a panda", quantize: 4)
        let args = Ideogram4RunnerSpec.buildArgs(job: job, ctx: ctx, settings: s)
        #expect(value(after: "--model", in: args) == "mflux-community/ideogram-4-mflux-q4")
    }

    // MARK: - Labels

    /// Krea 2 Turbo is labelled Distilled, but keeps its guidance: it is CFG-capable
    /// for the negative prompt, so the guidance lock must never reach it.
    @Test func krea2IsStepDistilledButKeepsItsGuidance() {
        #expect(FluxModelVariant.krea2.isStepDistilled)
        #expect(!FluxModelVariant.krea2.isDistilled)
        #expect(ModelDefaults(guidance: 3.0).resolved(for: .krea2).guidance == 3.0)
        #expect(!FluxModelVariant.zimage.isStepDistilled)
    }
}
