import Foundation

/// The one-time move from the old "mflux binary directory" setting to the
/// toolchain (spec §3). A uv-managed mflux, the one this app used to install,
/// gives way to the bundled runtime. Any other folder, such as a dev checkout,
/// becomes the Custom Python, using the interpreter its launcher names.
nonisolated enum ToolchainMigration {
    /// The Custom Python to carry over from `dir`, or nil to use the bundled runtime.
    static func customPython(fromLegacyBinaryDir dir: String) -> String? {
        guard !dir.isEmpty else { return nil }
        let shim = ((dir as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(PythonTool.flux2.rawValue)
        guard let python = venvPython(fromShim: shim), !isUVManaged(python: python) else { return nil }
        return python
    }

    /// uv installs tools into `<data dir>/uv/tools/<name>/`, wherever
    /// `XDG_DATA_HOME` puts the data dir.
    static func isUVManaged(python: String) -> Bool {
        python.contains("/uv/tools/")
    }

    /// The interpreter a launcher script runs: its shebang, or, for pip's
    /// `/bin/sh` form used when the path has spaces, the path on its
    /// `'''exec' "<python>"` line. Nil unless that interpreter exists.
    static func venvPython(fromShim shimPath: String) -> String? {
        guard !shimPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: shimPath),
              let head = try? handle.read(upToCount: 1024),
              let text = String(data: head, encoding: .utf8),
              text.hasPrefix("#!") else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var python = lines[0].dropFirst(2).trimmingCharacters(in: .whitespaces)
        if python == "/bin/sh" {
            // Only pip's exec form names an interpreter; any other shell script doesn't.
            guard lines.count > 1,
                  let match = lines[1].range(of: #"(?<=^'''exec' ")[^"]+"#, options: .regularExpression)
            else { return nil }
            python = String(lines[1][match])
        }
        return FileManager.default.isExecutableFile(atPath: python) ? python : nil
    }
}
