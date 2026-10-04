import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// AppSettings rebuilds its Toolchain when the Custom Python changes, and every
/// child process gets the Python environment from it.
struct AppSettingsToolchainTests {
    @Test func changingTheCustomPythonRebuildsTheToolchain() {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.customPythonPath = "/nonexistent/venv/bin/python"
        #expect(settings.toolchain.customPython == "/nonexistent/venv/bin/python")
        #expect(settings.toolchain.problem == .customPythonMissing("/nonexistent/venv/bin/python"))
        settings.customPythonPath = ""
        #expect(settings.toolchain.customPython.isEmpty)
    }

    @Test func childProcessesGetThePythonEnvironment() {
        let settings = AppSettings()
        settings.suspendPersistence()
        let env = settings.buildEnvironment()
        #expect(env["PYTHONNOUSERSITE"] == "1")
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1")
        #expect(env["MPLCONFIGDIR"]?.hasSuffix("/matplotlib") == true)
    }
}
