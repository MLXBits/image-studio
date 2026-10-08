import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Krea 2's Low RAM mode: the flag reaches `mflux-generate-krea2`, keeps the job
/// off the warm driver (a resident model defeats streaming), and keys timing.
@MainActor
struct Krea2LowRamTests {
    private let ctx = JobRunContext(
        seed: 1, outputFile: "/tmp/out.png",
        stepwiseDir: FileManager.default.temporaryDirectory, promptFile: nil
    )

    private func settings() -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        return settings
    }

    @Test func lowRamJobPassesTheFlag() {
        let args = Krea2RunnerSpec.buildArgs(job: Krea2Job(prompt: "a panda", lowRam: true), ctx: ctx, settings: settings())
        #expect(args.contains("--low-ram"))
    }

    @Test func defaultJobOmitsTheFlag() {
        let args = Krea2RunnerSpec.buildArgs(job: Krea2Job(prompt: "a panda"), ctx: ctx, settings: settings())
        #expect(!args.contains("--low-ram"))
    }

    @Test func lowRamJobStaysOffTheWarmDriver() {
        let job = Krea2Job(prompt: "a panda", lowRam: true)
        #expect(Krea2RunnerSpec.driverRequest(job: job, ctx: ctx, settings: settings()) == nil)
    }

    @Test func timingKeyFollowsTheJob() {
        #expect(Krea2RunnerSpec.timingLowRam(job: Krea2Job(lowRam: true)))
        #expect(!Krea2RunnerSpec.timingLowRam(job: Krea2Job()))
    }

    @Test func lowRamSurvivesPersistence() throws {
        let data = try JSONEncoder().encode(Krea2Job(prompt: "a panda", lowRam: true))
        #expect(try JSONDecoder().decode(Krea2Job.self, from: data).lowRam)
    }

    @Test func jobsSavedBeforeTheFieldDecodeAsOff() throws {
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","prompt":"a panda"}"#.utf8)
        #expect(try !JSONDecoder().decode(Krea2Job.self, from: legacy).lowRam)
    }

    @Test func settingsDefaultFlowsIntoTheJob() {
        let settings = settings()
        var d = settings.defaults(for: .krea2)
        d.lowRam = true
        settings.updateDefaults(d, for: .krea2)
        let params = Krea2ParamsPanelState()
        params.prompt = "a panda"
        params.lowRam = settings.resolvedDefaults(for: .krea2).lowRam
        #expect(params.makeJob().lowRam)
    }
}
