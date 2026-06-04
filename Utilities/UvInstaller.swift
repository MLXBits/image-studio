import Foundation

enum UvInstaller {
    enum InstallError: LocalizedError {
        case unsupportedArch
        case downloadFailed(Error)
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedArch:         return "Unsupported CPU architecture"
            case .downloadFailed(let err): return "Download failed: \(err.localizedDescription)"
            case .extractionFailed:        return "Failed to extract uv archive"
            }
        }
    }

    static var installPath: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MLXBits Image Studio/bin/uv")
    }

    static func install() async throws -> String {
        #if arch(arm64)
        let archName = "aarch64"
        #elseif arch(x86_64)
        let archName = "x86_64"
        #else
        throw InstallError.unsupportedArch
        #endif

        guard let url = URL(string:
            "https://github.com/astral-sh/uv/releases/latest/download/uv-\(archName)-apple-darwin.tar.gz")
        else { throw InstallError.downloadFailed(URLError(.badURL)) }

        let (tmpFile, _): (URL, URLResponse)
        do {
            (tmpFile, _) = try await URLSession.shared.download(from: url)
        } catch {
            throw InstallError.downloadFailed(error)
        }
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let binDir = installPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tmpFile.path, "-C", binDir.path, "--strip-components=1"]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw InstallError.extractionFailed }

        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: installPath.path)
        return installPath.path
    }
}
