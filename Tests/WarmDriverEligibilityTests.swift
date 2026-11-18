import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// A family's jobs reach the warm driver only if its spec offers a request
/// through ``JobRunnerSpec``, the way ``JobRunner`` asks (generic dispatch).
struct WarmDriverEligibilityTests {
    private func request<S: JobRunnerSpec>(_: S.Type, job: S.Job) -> DriverGenerateRequest? {
        let settings = AppSettings()
        settings.suspendPersistence()
        let ctx = JobRunContext(
            seed: 1, outputFile: "/tmp/out.png",
            stepwiseDir: FileManager.default.temporaryDirectory, promptFile: nil, python: nil, baseModelSupported: nil
        )
        return S.driverRequest(job: job, ctx: ctx, settings: settings)
    }

    @Test func krea2JobsAreOfferedToTheWarmDriver() {
        #expect(request(Krea2RunnerSpec.self, job: Krea2Job(prompt: "a panda")) != nil)
    }

    @Test func aColdRetryDoesNotDuplicateLandedSeeds() {
        // Seed 11 lands, seed 22 fails, the driver retries cold and re-sends both.
        let progress = Qwen21JobRunner.DriverRunProgress()
        #expect(progress.land(seed: 11, path: "/out_seed_11.png"))
        #expect(!progress.land(seed: 11, path: "/out_seed_11.png"))
        #expect(progress.land(seed: 22, path: "/out_seed_22.png"))
        #expect(progress.landed.map(\.seed) == [11, 22])
        #expect(progress.landed.map(\.path) == ["/out_seed_11.png", "/out_seed_22.png"])
    }

    @Test func aRetriedSaveClearsItsMissingMark() {
        let progress = Qwen21JobRunner.DriverRunProgress()
        progress.missing = ["/out_seed_22.png"]
        _ = progress.land(seed: 22, path: "/out_seed_22.png")
        #expect(progress.missing.isEmpty)
    }

    @Test func qwen21JobsAreOfferedToTheWarmDriver() {
        #expect(request(Qwen21RunnerSpec.self, job: Qwen21Job(prompt: "a panda")) != nil)
    }
}
