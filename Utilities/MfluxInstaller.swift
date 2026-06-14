import Foundation

enum MfluxInstaller {
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

    static func install() async throws -> String {
        let uvPath: String = if let found = resolveUv() {
            found
        } else {
            try await installUv()
        }

        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["tool", "install", "mflux"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        process.environment = buildEnv()
        do { try process.run() } catch {
            throw InstallError.mfluxInstallFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw InstallError.mfluxInstallFailed(msg)
        }

        let detected = BinaryDetector.detect("mflux-generate-flux2")
        guard !detected.isEmpty else { throw InstallError.binaryNotFound }
        return URL(fileURLWithPath: detected).deletingLastPathComponent().path
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
