import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers how the app resolves Python (spec §3): the bundled runtime by default,
/// the DMG's Custom Python for mflux only, and clear errors instead of silent
/// fallbacks when either is missing.
struct ToolchainTests {
    /// A venv-shaped folder outside the fake bundle: `bin/python` plus the given launchers.
    private func customVenv(launchers: [PythonTool] = []) throws -> String {
        let bin = FakeRuntime.tempDirectory("venv").appendingPathComponent("bin", isDirectory: true)
        try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: bin.appendingPathComponent("python"))
        for tool in launchers {
            try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: bin.appendingPathComponent(tool.rawValue))
        }
        return bin.appendingPathComponent("python").path
    }

    @Test func toolsRunThroughRunToolOnTheBundledInterpreter() throws {
        let runtime = try FakeRuntime()
        let command = try runtime.toolchain().command(.flux2)
        #expect(command.executable == runtime.python.path)
        #expect(command.arguments == [runtime.runTool.path, "mflux-generate-flux2"])
    }

    @Test func customPythonRunsMfluxToolsOnly() throws {
        let runtime = try FakeRuntime()
        let custom = try customVenv()
        let toolchain = runtime.toolchain(customPython: custom)
        #expect(try toolchain.command(.flux2).executable == custom)
        #expect(try toolchain.command(.save).executable == custom)
        #expect(try toolchain.mfluxInterpreter() == custom)
        #expect(try toolchain.command(.hf).executable == runtime.python.path)
        #expect(try toolchain.command(.mlxLmGenerate).executable == runtime.python.path)
        #expect(try toolchain.bundledInterpreter() == runtime.python.path)
    }

    @Test func missingCustomPythonIsAnErrorNotASilentFallback() throws {
        let toolchain = try FakeRuntime().toolchain(customPython: "/nonexistent/venv/bin/python")
        #expect(throws: ToolchainError.customPythonMissing("/nonexistent/venv/bin/python")) {
            try toolchain.command(.flux2)
        }
        #expect(toolchain.problem == .customPythonMissing("/nonexistent/venv/bin/python"))
        #expect(!toolchain.hasTool(.flux2))
        // Tools that never follow the override are unaffected.
        #expect(throws: Never.self) { try toolchain.command(.hf) }
    }

    /// The venv can vanish while the app runs (deleted, checkout moved); jobs
    /// must then get the Custom Python message, not a stale "runnable".
    @Test func customPythonDeletedAfterwardsIsReportedMissing() throws {
        let custom = try customVenv()
        let toolchain = try FakeRuntime().toolchain(customPython: custom)
        try FileManager.default.removeItem(atPath: custom)
        #expect(throws: ToolchainError.customPythonMissing(custom)) { try toolchain.command(.flux2) }
        #expect(toolchain.problem == .customPythonMissing(custom))
    }

    @Test func tildeInCustomPythonIsExpanded() throws {
        let toolchain = try FakeRuntime().toolchain(customPython: "~/no-such-venv/bin/python")
        #expect(toolchain.customPython == NSHomeDirectory() + "/no-such-venv/bin/python")
    }

    @Test func buildWithoutRuntimeReportsItMissing() throws {
        let toolchain = try FakeRuntime(python: nil).toolchain()
        #expect(toolchain.bundledPython == nil)
        #expect(toolchain.problem == .runtimeMissing)
        #expect(throws: ToolchainError.runtimeMissing) { try toolchain.command(.flux2) }
        #expect(throws: ToolchainError.runtimeMissing) { try toolchain.command(.mlxLmGenerate) }
        #expect(!toolchain.hasTool(.flux2))
        #expect(toolchain.acknowledgementsURL == nil)
        #expect(toolchain.runtimeURL == nil)
    }

    @Test func noResourcesFolderMeansNoRuntime() {
        let toolchain = Toolchain(resourcesURL: nil, customPython: "")
        #expect(toolchain.problem == .runtimeMissing)
    }

    @Test func bundledRuntimeHasEveryTool() throws {
        let toolchain = try FakeRuntime().toolchain()
        #expect(toolchain.problem == nil)
        #expect(PythonTool.allCases.allSatisfy { toolchain.hasTool($0) })
    }

    /// Every venv installs its launchers beside its interpreter; a family whose
    /// launcher is absent is one that install can't run.
    @Test func customPythonHasTheToolsInstalledBesideIt() throws {
        let toolchain = try FakeRuntime().toolchain(customPython: customVenv(launchers: [.flux2]))
        #expect(toolchain.hasTool(.flux2))
        #expect(!toolchain.hasTool(.krea2))
        #expect(toolchain.hasTool(.hf)) // bundled, regardless of the override
    }

    @Test func acknowledgementsAndManifestComeFromTheRuntime() throws {
        let runtime = try FakeRuntime()
        let toolchain = runtime.toolchain()
        #expect(toolchain.acknowledgementsURL?.lastPathComponent == "Acknowledgements.txt")
        let manifest = try #require(RuntimeManifest.load(from: toolchain.runtimeURL))
        #expect(manifest.python == "3.14.7")
        #expect(manifest.version(of: "mflux") == "0.21.0")
        #expect(manifest.version(of: "not-a-package") == nil)
    }

    @Test func environmentDropsInheritedInterpreterOverrides() {
        let caches = URL(fileURLWithPath: "/tmp/caches")
        let env = Toolchain.environment(
            base: [
                "PYTHONHOME": "/elsewhere", "PYTHONPATH": "/elsewhere/lib",
                "__PYVENV_LAUNCHER__": "/elsewhere/bin/python", "HF_HOME": "/models",
            ],
            cachesURL: caches
        )
        #expect(env["PYTHONHOME"] == nil)
        #expect(env["PYTHONPATH"] == nil)
        #expect(env["__PYVENV_LAUNCHER__"] == nil)
        #expect(env["HF_HOME"] == "/models")
        #expect(env["PYTHONNOUSERSITE"] == "1")
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1")
        #expect(env["PYTHONUNBUFFERED"] == "1")
        #expect(env["MPLCONFIGDIR"] == "/tmp/caches/matplotlib")
    }
}
