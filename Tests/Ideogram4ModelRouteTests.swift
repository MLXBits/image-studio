import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Ideogram Q8/Q4 load the mflux-community mflux-save checkpoints as published:
/// the one-shot CLI and the warm driver both get the repo as `--model` with no
/// quantize level (a level would re-quantize from the FP8 base). Whether mflux
/// accepts the repo is checked in the app, not here: it is a 14–26 GB download.
@MainActor
struct Ideogram4ModelRouteTests {
    private let ctx = JobRunContext(
        seed: 1, outputFile: "/tmp/out.png",
        stepwiseDir: FileManager.default.temporaryDirectory, promptFile: nil
    )

    private func settings() -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.ideogram4ModelRepoOverride = nil
        return settings
    }

    private func job(quantize: Int) -> Ideogram4Job {
        Ideogram4Job(usePlainPrompt: true, plainPrompt: "a panda", quantize: quantize)
    }

    @Test(arguments: [
        (8, "mflux-community/ideogram-4-mflux-q8"),
        (4, "mflux-community/ideogram-4-mflux-q4"),
    ])
    func oneShotLoadsThePublishedRepo(quantize: Int, repo: String) throws {
        let args = Ideogram4RunnerSpec.buildArgs(job: job(quantize: quantize), ctx: ctx, settings: settings())
        let model = try #require(args.firstIndex(of: "--model"))
        #expect(args[model + 1] == repo)
        #expect(!args.contains("--quantize"))
    }

    @Test(arguments: [
        (8, "mflux-community/ideogram-4-mflux-q8"),
        (4, "mflux-community/ideogram-4-mflux-q4"),
    ])
    func warmDriverLoadsThePublishedRepo(quantize: Int, repo: String) throws {
        let request = try #require(
            Ideogram4RunnerSpec.driverRequest(job: job(quantize: quantize), ctx: ctx, settings: settings())
        )
        #expect(request.model == repo)
        #expect(request.quantize == nil)
    }
}
