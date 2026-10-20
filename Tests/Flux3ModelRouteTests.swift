import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// FLUX 3 routes through the ungated mflux-community pre-saved repos (mflux layout) at every
/// precision — including BF16 — so the app never touches BFL's gated source repos. Distilled
/// klein has no CFG branch (`--guidance` omitted), both CLIs reject `--negative-prompt`, and
/// img2img/PiD args are silently dropped by mflux — pinned here alongside tool selection.
@MainActor
struct Flux3ModelRouteTests {
    private let ctx = JobRunContext(
        seed: 1, outputFile: "/tmp/out.png",
        stepwiseDir: FileManager.default.temporaryDirectory, promptFile: nil
    )

    private func settings() -> AppSettings {
        let s = AppSettings()
        s.suspendPersistence()
        return s
    }

    private func job(model: FluxModelVariant, quantize: Int) -> FluxJob {
        FluxJob(model: model, prompt: "a panda", quantize: quantize)
    }

    // MARK: - Tool selection

    @Test(arguments: [false, true])
    func toolFollowsTheEditMode(isEdit: Bool) {
        #expect(FluxRunnerSpec.tool(job: FluxJob(model: .flux3Klein, prompt: "x", isEditMode: isEdit)) == (isEdit ? .flux3Edit : .flux3))
        #expect(FluxRunnerSpec.tool(job: FluxJob(model: .flux2Klein9B, prompt: "x", isEditMode: isEdit)) == (isEdit ? .flux2Edit : .flux2))
    }

    // MARK: - Published repo routing at every precision

    @Test(arguments: [
        (FluxModelVariant.flux3Klein, 0, "mflux-community/flux-3-image-klein-mflux-bf16"),
        (FluxModelVariant.flux3Klein, 8, "mflux-community/flux-3-image-klein-mflux-q8"),
        (FluxModelVariant.flux3Klein, 4, "mflux-community/flux-3-image-klein-mflux-q4"),
        (FluxModelVariant.flux3KleinBase, 0, "mflux-community/flux-3-image-klein-base-mflux-bf16"),
        (FluxModelVariant.flux3KleinBase, 8, "mflux-community/flux-3-image-klein-base-mflux-q8"),
        (FluxModelVariant.flux3KleinBase, 4, "mflux-community/flux-3-image-klein-base-mflux-q4"),
    ])
    func oneShotLoadsThePublishedRepo(model: FluxModelVariant, quantize: Int, repo: String) throws {
        let args = FluxRunnerSpec.buildArgs(job: job(model: model, quantize: quantize), ctx: ctx, settings: settings())
        let i = try #require(args.firstIndex(of: "--model"))
        #expect(args[i + 1] == repo)
        // A level would re-quantize from the base; the repo carries its own precision.
        #expect(!args.contains("--quantize"))
        // The community name (".../flux-3-image-klein-mflux-q8") matches no "flux3*" alias, so
        // mflux cannot infer the root config — --base-model must ride along unconditionally,
        // without depending on a probe that can time out on a cold interpreter.
        let iBase = try #require(args.firstIndex(of: "--base-model"))
        let expectedKey = model == .flux3Klein ? "flux3-image-klein" : "flux3-image-klein-base"
        #expect(args[iBase + 1] == expectedKey)
    }

    // MARK: - Executor routing

    @Test func flux3FallsBackToTheCliSubprocess() {
        // The warm driver resolves models via ModelConfig.from_name with no base-model
        // parameter; a community repo ID can't be inferred ("Cannot infer base_model")
        // and the flux2 branch would load FLUX 3 weights into the wrong variant class.
        for model in [FluxModelVariant.flux3Klein, .flux3KleinBase] {
            #expect(FluxRunnerSpec.driverRequest(job: job(model: model, quantize: 8), ctx: ctx, settings: settings()) == nil)
        }
        // Control: FLUX.2 still uses the warm driver for a plain txt2img job.
        #expect(FluxRunnerSpec.driverRequest(job: job(model: .flux2Klein9B, quantize: 8), ctx: ctx, settings: settings()) != nil)
    }

    @Test(arguments: [0, 8, 4])
    func downloadPlanIsThePlainHfDownload(quantize: Int) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for model in [FluxModelVariant.flux3Klein, .flux3KleinBase] {
            let expected = try #require(model.preQuantizedRepoID(quantize: quantize))
            // A plain `hf download` — no mflux-save pass, so BFL's gated source is never fetched.
            #expect(WeightDownloadStore.plan(model: model, quantize: quantize, cacheDir: dir, hubDir: dir) == .download(repo: expected))
        }
    }

    // MARK: - CLI quirk gating

    @Test func distilledKleinOmitsGuidanceButBaseKeepsIt() {
        let klein = FluxRunnerSpec.buildArgs(job: job(model: .flux3Klein, quantize: 8), ctx: ctx, settings: settings())
        #expect(!klein.contains("--guidance"))
        let base = FluxRunnerSpec.buildArgs(job: job(model: .flux3KleinBase, quantize: 8), ctx: ctx, settings: settings())
        #expect(base.contains("--guidance"))
    }

    @Test func negativePromptIsDroppedForFlux3ButKeptElsewhere() {
        let f3 = FluxJob(model: .flux3KleinBase, prompt: "x", negativePrompt: "blurry", quantize: 8)
        #expect(!FluxRunnerSpec.buildArgs(job: f3, ctx: ctx, settings: settings()).contains("--negative-prompt"))
        // Z-Image is the only builtin with negative-prompt support here; custom checkpoints keep it too.
        let z = FluxJob(model: .zimage, prompt: "x", negativePrompt: "blurry")
        #expect(FluxRunnerSpec.buildArgs(job: z, ctx: ctx, settings: settings()).contains("--negative-prompt"))
    }

    @Test func staleImg2imgStateIsDroppedForFlux3() {
        let stale = FluxJob(model: .flux3Klein, prompt: "x", quantize: 8, imagePath: "/tmp/stale.png")
        #expect(!FluxRunnerSpec.buildArgs(job: stale, ctx: ctx, settings: settings()).contains("--image-path"))
    }

    @Test func editModeStillPassesItsImages() {
        let j = FluxJob(model: .flux3KleinBase, prompt: "x", quantize: 8, isEditMode: true, editImagePaths: ["/tmp/a.png"])
        let args = FluxRunnerSpec.buildArgs(job: j, ctx: ctx, settings: settings())
        #expect(args.contains("--image-paths"))
        #expect(!args.contains("--image-path"))
    }

    @Test func pidDecodeIsDroppedForFlux3() {
        let f3 = FluxJob(model: .flux3Klein, prompt: "x", quantize: 8, pidDecode: true)
        #expect(!FluxRunnerSpec.buildArgs(job: f3, ctx: ctx, settings: settings()).contains("--pid-decode"))
        let f2 = FluxJob(model: .flux2Klein9B, prompt: "x", pidDecode: true)
        #expect(FluxRunnerSpec.buildArgs(job: f2, ctx: ctx, settings: settings()).contains("--pid-decode"))
    }

    // MARK: - Custom checkpoints and LoRAs

    @Test(arguments: [FluxModelVariant.flux3Klein, .flux3KleinBase])
    func customCheckpointNamesItsFlux3BaseUnconditionally(base: FluxModelVariant) throws {
        // A FLUX 3 fine-tune must not depend on the interpreter probe answering in time —
        // any runtime with the flux3 CLI accepts --base-model, so it rides along always.
        let j = FluxJob(
            model: .custom,
            customModelRepo: "/tmp/ft.safetensors",
            customBaseModel: base,
            prompt: "x"
        )
        let args = FluxRunnerSpec.buildArgs(job: j, ctx: ctx, settings: settings())
        let i = try #require(args.firstIndex(of: "--model"))
        #expect(args[i + 1] == "/tmp/ft.safetensors")
        let iBase = try #require(args.firstIndex(of: "--base-model"))
        #expect(args[iBase + 1] == base.mfluxModelID)
    }

    @Test func lorasAreDroppedForFlux3ButKeptElsewhere() {
        // LoraEntry carries no per-model scope, so an enabled Flux.2 LoRA survives a model
        // switch; its layers don't map onto FLUX 3's architecture.
        let lora = LoraEntry(path: "/tmp/style.safetensors", strength: 0.8)
        let f3 = FluxJob(model: .flux3Klein, prompt: "x", loras: [lora], quantize: 8)
        #expect(!FluxRunnerSpec.buildArgs(job: f3, ctx: ctx, settings: settings()).contains("--lora-paths"))
        // Control at quantize 0: FLUX.2 has no published repo there, so this path builds its
        // args without touching the interpreter probe.
        let f2 = FluxJob(model: .flux2Klein9B, prompt: "x", loras: [lora], quantize: 0)
        #expect(FluxRunnerSpec.buildArgs(job: f2, ctx: ctx, settings: settings()).contains("--lora-paths"))
    }

    // MARK: - Catalog facts

    @Test func probeKeysDisambiguateFromFlux2() {
        #expect(FluxModelVariant.flux3Klein.probeKey == "flux3")
        #expect(FluxModelVariant.flux3KleinBase.probeKey == "flux3-base")
    }

    @Test func sizesMatchTheCommunityRepos() {
        for model in [FluxModelVariant.flux3Klein, .flux3KleinBase] {
            #expect(model.approximateSizeGB(quantize: 0) == 18.5)
            #expect(model.approximateSizeGB(quantize: 8) == 9.9)
            #expect(model.approximateSizeGB(quantize: 4) == 5.3)
        }
    }

    @Test func defaultsAndFamily() {
        #expect(FluxModelVariant.flux3Klein.defaultSteps == 16)
        #expect(FluxModelVariant.flux3KleinBase.defaultSteps == 50)
        #expect(!FluxModelVariant.flux3Klein.supportsGuidance)
        #expect(FluxModelVariant.flux3KleinBase.supportsGuidance)
        #expect(FluxModelVariant.flux3Klein.family == .flux)
        #expect(FluxModelVariant.flux3KleinBase.family == .flux)
    }
}
