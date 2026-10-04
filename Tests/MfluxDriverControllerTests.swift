import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The warm driver follows the toolchain: a changed Custom Python retires the
/// running driver and starts the next one on the new interpreter.
struct MfluxDriverControllerTests {
    /// Stands in for Python running mflux_driver.py: ignores the script path,
    /// answers each `hello` with `ready`, and runs until stdin closes.
    private func fakeInterpreter() throws -> String {
        let url = FakeRuntime.tempDirectory("driver").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in *hello*) echo '{"event":"ready","mflux_version":"0","python":"3"}' ;; esac
        done
        """, to: url)
        return url.path
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
