import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The warm driver follows the toolchain (a changed Custom Python retires the
/// running driver and starts the next one on the new interpreter), and settles a
/// run whose process dies: a crash fails the job, a Stop cancels it.
struct MfluxDriverControllerTests {
    /// A generate request; the fake driver reads only its `cmd`.
    private static let request = DriverGenerateRequest(
        id: "run-1", family: "flux2", fingerprint: "flux2|test", model: "test/model",
        loraPaths: [], loraScales: [], prompt: "a cat", steps: 4, guidance: 1.0,
        outputs: [DriverOutput(seed: 1, path: "/dev/null")], stepwiseDir: "", tePolicy: "",
        cacheLimitGb: 0, modelVariantRaw: "flux2-klein-9b", modelLabel: "Test"
    )

    /// Stands in for Python running mflux_driver.py: ignores the script path,
    /// answers each `hello` with `ready`, runs `onGenerate` for a generate
    /// request, and runs until stdin closes.
    private func fakeInterpreter(onGenerate: String = ":") throws -> String {
        let url = FakeRuntime.tempDirectory("driver").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *hello*) echo '{"event":"ready","mflux_version":"0","python":"3"}' ;;
            *generate*) \(onGenerate) ;;
          esac
        done
        """, to: url)
        return url.path
    }

    /// A running driver on a fake interpreter.
    private func startedDriver(onGenerate: String) async throws -> MfluxDriverController {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.customPythonPath = try fakeInterpreter(onGenerate: onGenerate)
        let driver = MfluxDriverController(settings: settings)
        try #require(await driver.ensureRunning())
        return driver
    }

    private func failure(_ result: DriverRunResult) -> String? {
        if case let .failed(message) = result {
            return message
        }
        return nil
    }

    @Test func aDriverThatExitsMidRunFailsTheJob() async throws {
        let driver = try await startedDriver(onGenerate: "exit 3")

        let result = await driver.run(request: Self.request) { _ in }

        #expect(failure(result) == "Warm driver process died (exit status 3)")
        #expect(!driver.isRunning)
        // The next job falls back to the one-shot CLI rather than trusting the driver again.
        #expect(driver.availability == .unavailable("Driver process died mid-job"))
    }

    @Test func aDriverKilledBySignalReportsACrash() async throws {
        let driver = try await startedDriver(onGenerate: "kill -KILL $$")

        let result = await driver.run(request: Self.request) { _ in }

        #expect(failure(result) == RunnerSupport.crashReason("The warm driver", signal: SIGKILL))
        #expect(driver.availability == .unavailable("Driver process died mid-job"))
    }

    /// Stop before the denoise loop starts kills the driver outright. That is
    /// the user's doing, not a crash: the job is cancelled and the driver stays
    /// available, so the next job starts a fresh one.
    @Test func stoppingBeforeDenoiseCancelsTheJob() async throws {
        let driver = try await startedDriver(onGenerate: ":")

        let run = Task { await driver.run(request: Self.request) { _ in } }
        while !driver.isGenerating {
            await Task.yield()
        }
        #expect(driver.cancel() == false) // killed, not asked to abort
        let result = await run.value

        guard case .cancelled = result else {
            Issue.record("Expected .cancelled, got \(result)")
            return
        }
        #expect(driver.availability != .unavailable("Driver process died mid-job"))
        #expect(!driver.isRunning)
    }

    @Test func changingTheCustomPythonRestartsTheDriverOnIt() async throws {
        let settings = AppSettings()
        settings.suspendPersistence()
        let first = try fakeInterpreter()
        let second = try fakeInterpreter()
        settings.customPythonPath = first
        let driver = MfluxDriverController(settings: settings)

        #expect(await driver.ensureRunning())
        #expect(driver.interpreter == first)

        settings.customPythonPath = second
        #expect(await driver.ensureRunning())
        #expect(driver.interpreter == second)
        // The first driver's exit is reported after the restart, and must not
        // tear down the second.
        try await Task.sleep(for: .milliseconds(300))
        #expect(driver.isRunning)

        // A Custom Python that vanished leaves the driver unavailable (jobs fall
        // back to the one-shot CLI, which reports the problem), and stops the old one.
        settings.customPythonPath = "/nonexistent/venv/bin/python"
        #expect(await driver.ensureRunning() == false)
        #expect(!driver.isRunning)
    }
}
