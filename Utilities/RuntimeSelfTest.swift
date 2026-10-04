import Foundation

/// `--runtime-self-test` (spec §2) checks the bundled runtime from inside the
/// app's own process tree and exits non-zero on any failure. In the App Store
/// build, `python3.14` runs only as a sandboxed app's child, so a check from
/// outside the app can't stand in. The DMG release workflow runs it against
/// the signed app before notarizing.
nonisolated enum RuntimeSelfTest {
    static let flag = "--runtime-self-test"
    /// The packages whose native code a broken signature or a missing
    /// hardened-runtime exception would stop from loading.
    static let imports = "import mflux, mlx.core, mlx_lm, mlx_vlm, torch"

    /// Runs every check, reporting one line each through `report`, and returns
    /// the exit status: 0 when all passed.
    static func run(toolchain: Toolchain, environment: [String: String], report: (String) -> Void) -> Int32 {
        let python: String
        do {
            python = try toolchain.bundledInterpreter()
        } catch {
            report("FAIL runtime: \(error.localizedDescription)")
            return 1
        }
        var failures = 0
        func record(_ name: String, _ failure: String?) {
            if let failure {
                failures += 1
                report("FAIL \(name): \(failure)")
            } else {
                report("ok   \(name)")
            }
        }
        record("imports", check(python, ["-c", imports], environment))
        for tool in PythonTool.allCases {
            do {
                let command = try toolchain.command(tool)
                record(tool.rawValue, check(command.executable, command.arguments + ["--help"], environment))
            } catch {
                record(tool.rawValue, error.localizedDescription)
            }
        }
        report(failures == 0 ? "Runtime self-test passed" : "Runtime self-test: \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    /// Runs one child to completion. Returns nil when it exits 0, otherwise its
    /// status and the tail of its stderr. stderr goes to a file, not a pipe, so
    /// a chatty child can't fill a pipe nobody reads and hang.
    private static func check(_ executable: String, _ arguments: [String], _ environment: [String: String]) -> String? {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-self-test-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        guard let errors = try? FileHandle(forWritingTo: log) else { return "could not create \(log.path)" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        process.waitUntilExit()
        try? errors.close()
        guard process.terminationStatus != 0 else { return nil }
        let stderr = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return "exit \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(800))"
    }
}
