import Foundation

enum BinaryDetector {
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

    // Returns the full path to mflux-generate-flux2 given a binary directory.
    static func mfluxGenerateFlux2(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-generate-flux2") }
        let path = "\(dir)/mflux-generate-flux2"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-flux2")
    }

    // Returns the full path to mflux-generate-flux2-edit given a binary directory.
    static func mfluxGenerateFlux2Edit(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-generate-flux2-edit") }
        let path = "\(dir)/mflux-generate-flux2-edit"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-flux2-edit")
    }

    // Returns the full path to mflux-save given a binary directory.
    static func mfluxSave(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-save") }
        let path = "\(dir)/mflux-save"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-save")
    }
}
