import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The one-time move from the old "mflux binary directory" setting (spec §3):
/// a uv-managed mflux (the one the app used to install) gives way to the
/// bundled runtime, and anything else becomes the Custom Python.
struct ToolchainMigrationTests {
    /// An interpreter plus an `mflux-generate-flux2` launcher naming it, in `bin`.
    @discardableResult
    private func venv(at bin: URL, launcher: ((String) -> String)? = nil) throws -> String {
        let python = bin.appendingPathComponent("python").path
        try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: URL(fileURLWithPath: python))
        let shim = launcher?(python) ?? "#!\(python)\nimport sys\n"
        try Data(shim.utf8).write(to: bin.appendingPathComponent("mflux-generate-flux2"))
        return python
    }

    @Test func devCheckoutBecomesTheCustomPython() throws {
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent("Git/mflux/.venv/bin")
        let python = try venv(at: bin)
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == python)
    }

    @Test func uvManagedInstallFallsBackToBundled() throws {
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent(".local/share/uv/tools/mflux/bin")
        try venv(at: bin)
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == nil)
    }

    /// uv puts symlinks to its tool launchers in ~/.local/bin, which is what the
    /// old auto-detection stored.
    @Test func uvShimSymlinkedIntoLocalBinIsDropped() throws {
        let home = FakeRuntime.tempDirectory("home")
        let toolBin = home.appendingPathComponent(".local/share/uv/tools/mflux/bin")
        try venv(at: toolBin)
        let localBin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: localBin.appendingPathComponent("mflux-generate-flux2"),
            withDestinationURL: toolBin.appendingPathComponent("mflux-generate-flux2")
        )
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: localBin.path) == nil)
    }

    /// pip writes this form when the interpreter's path has spaces or is long.
    @Test func shellExecLauncherIsUnwrapped() throws {
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent("My Projects/mflux/.venv/bin")
        let python = try venv(at: bin) { python in
            "#!/bin/sh\n'''exec' \"\(python)\" \"$0\" \"$@\"\n' '''\nimport sys\n"
        }
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == python)
    }

    /// uv writes the same `/bin/sh` form with single quotes, spelling an
    /// apostrophe in the path as `'"'"'` (uv 0.12.9's exact output).
    @Test func uvExecLauncherIsUnwrapped() throws {
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent("it's here/My Projects/mflux/.venv/bin")
        let python = try venv(at: bin) { python in
            let quoted = python.replacingOccurrences(of: "'", with: "'\"'\"'")
            return "#!/bin/sh\n'''exec' '\(quoted)' \"$0\" \"$@\"\n' '''\nimport sys\n"
        }
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == python)
    }

    @Test func emptyOrStaleSettingsUseBundled() throws {
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: "") == nil)
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: "/nonexistent/bin") == nil)
        // A launcher whose interpreter has since been deleted.
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent("gone/.venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/nonexistent/python\n".utf8).write(to: bin.appendingPathComponent("mflux-generate-flux2"))
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == nil)
    }
}
