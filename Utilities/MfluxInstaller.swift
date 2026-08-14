import Foundation

/// Nonisolated so the blocking subprocess/download work runs off the main actor
/// (the project defaults declarations to MainActor).
nonisolated enum MfluxInstaller {
    enum InstallError: LocalizedError {
        case uvInstallFailed(Error)
        case mfluxInstallFailed(String)
        case binaryNotFound

        var errorDescription: String? {
            switch self {
            case let .uvInstallFailed(err): "uv install failed: \(err.localizedDescription)"
            case let .mfluxInstallFailed(msg): "mflux install failed: \(msg)"
            case .binaryNotFound: "mflux installed but binary not found in PATH"
            }
        }
    }

    /// Lower bound on the mflux we install. 0.18.1 is the first release shipping the
    /// `mflux-generate-krea2` CLI; on anything older Krea 2 is silently absent from
    /// the model picker. Deliberately a floor rather than an exact pin — mflux adds
    /// model CLIs between releases and ``BinaryDetector`` probes for them at runtime,
    /// so a newer mflux can only add families, never remove one we rely on.
    static let minimumVersion = "0.18.1"

    static func install() async throws -> String {
        let uvPath: String = if let found = resolveUv() {
            found
        } else {
            try await installUv()
        }

        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        // `--upgrade` so one call serves both a first install and lifting an existing
        // install that sits below the floor. uv does tend to reinstall once the
        // requested requirement differs from the one in its receipt, but that is a
        // side effect of the string having changed rather than a guarantee — asking
        // outright does not depend on what the receipt happens to record.
        process.arguments = ["tool", "install", "--upgrade", "mflux>=\(minimumVersion)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        process.environment = buildEnv()
        do { try process.run() } catch {
            throw InstallError.mfluxInstallFailed(error.localizedDescription)
        }
        // Drain stderr *before* waiting: uv can emit more than the 64 KB pipe buffer,
        // and a child blocked writing to a full, unread pipe never exits (deadlock).
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw InstallError.mfluxInstallFailed(msg)
        }

        let detected = BinaryDetector.detect("mflux-generate-flux2")
        guard !detected.isEmpty else { throw InstallError.binaryNotFound }
        return URL(fileURLWithPath: detected).deletingLastPathComponent().path
    }

    /// Whether `version` — as `importlib.metadata` reports it — satisfies
    /// ``minimumVersion``. Component-wise and numeric, so PEP 440 suffixes
    /// ("0.18.1.dev0", "0.18.1+local") count as their release: a dev build of the
    /// floor still carries the CLIs we need, and calling it too old would nag anyone
    /// running a checkout. An unreadable version compares as 0 and so fails the floor.
    static func satisfiesMinimum(_ version: String) -> Bool {
        !UpdateChecker.compare(minimumVersion, isNewerThan: version)
    }

    /// Whether `binaryDir` resolves to the uv-managed mflux this app installed — the
    /// only one ``install()`` may upgrade in place. A dev checkout or any other
    /// hand-picked directory is left alone: reinstalling over someone's editable
    /// install would silently detach the app from the tree they are working in.
    static func isUVManaged(binaryDir: String) -> Bool {
        guard let python = MfluxDriverController.venvPython(
            fromShim: BinaryDetector.mfluxGenerateFlux2(in: binaryDir)
        ), let root = uvToolDir() else { return false }
        return python.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// uv's tool root, asked of uv itself rather than assumed — it moves with
    /// `UV_TOOL_DIR` and `XDG_DATA_HOME`.
    private static func uvToolDir() -> String? {
        guard let uvPath = resolveUv() else { return nil }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["tool", "dir"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = buildEnv()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func resolveUv() -> String? {
        if FileManager.default.fileExists(atPath: UvInstaller.installPath.path) {
            return UvInstaller.installPath.path
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func installUv() async throws -> String {
        do {
            return try await UvInstaller.install()
        } catch {
            throw InstallError.uvInstallFailed(error)
        }
    }

    private static func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return env
    }
}
