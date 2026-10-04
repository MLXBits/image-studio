import Foundation

// Nonisolated: pure filesystem probes, callable from the installers' background work.
/// What remains of the old launcher-script search: only the install flow and
/// the legacy `mfluxBinaryDir` setting use it, and both go with it in the
/// toolchain migration (milestone 4, Task 7).
nonisolated enum BinaryDetector {
    /// The version of the `mflux` package importable by the install rooted at `dir`.
    static func mfluxVersion(in dir: String) -> String? {
        MfluxProbes.mfluxVersion(python: ToolchainMigration.venvPython(fromShim: mfluxGenerateFlux2(in: dir)))
    }

    static func detect(_ name: String) -> String {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }

    static func detectBinaryDir(for name: String) -> String {
        let path = detect(name)
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    /// Returns the full path to mflux-generate-flux2 given a binary directory.
    static func mfluxGenerateFlux2(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-generate-flux2")
        }
        let path = "\(dir)/mflux-generate-flux2"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-flux2")
    }
}
