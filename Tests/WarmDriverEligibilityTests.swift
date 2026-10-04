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
            stepwiseDir: FileManager.default.temporaryDirectory, promptFile: nil
        )
        return S.driverRequest(job: job, ctx: ctx, settings: settings)
    }

    @Test func krea2JobsAreOfferedToTheWarmDriver() {
        #expect(request(Krea2RunnerSpec.self, job: Krea2Job(prompt: "a panda")) != nil)
    }
}
