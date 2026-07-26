import Foundation

// Nonisolated: pure filesystem probes, callable from the installers' background work.
nonisolated enum BinaryDetector {
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

    /// Resolves a console script to a full path, preferring `dir` and falling back
    /// to the standard locations. Returns nil when the script exists nowhere —
    /// unlike the `mfluxGenerate…` helpers below, which return `""` and leave the
    /// caller to hand an empty executable path to `Process`.
    static func resolve(_ name: String, in dir: String) -> String? {
        if !dir.isEmpty {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        let fallback = detect(name)
        return fallback.isEmpty ? nil : fallback
    }

    /// Whether the mflux install rooted at `dir` ships the console script this
    /// model variant generates with. Drives the model picker: a family whose CLI
    /// is absent is not offered rather than failing at spawn time.
    ///
    /// mflux gains CLIs between releases (`mflux-generate-krea2` landed after
    /// 0.18.0), and the app installs mflux unpinned, so this cannot be inferred
    /// from a version number.
    static func supports(_ variant: FluxModelVariant, in dir: String) -> Bool {
        guard let name = variant.generateCLIName else { return true }
        return resolve(name, in: dir) != nil
    }

    /// Returns the full path to mflux-generate-flux2 given a binary directory.
    static func mfluxGenerateFlux2(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-generate-flux2") }
        let path = "\(dir)/mflux-generate-flux2"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-flux2")
    }

    /// Returns the full path to mflux-generate-flux2-edit given a binary directory.
    static func mfluxGenerateFlux2Edit(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-generate-flux2-edit") }
        let path = "\(dir)/mflux-generate-flux2-edit"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-flux2-edit")
    }

    /// Returns the full path to mflux-save given a binary directory.
    static func mfluxSave(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-save") }
        let path = "\(dir)/mflux-save"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-save")
    }

    /// Returns the full path to mflux-generate-ideogram4 given a binary directory.
    static func mfluxGenerateIdeogram4(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-generate-ideogram4") }
        let path = "\(dir)/mflux-generate-ideogram4"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-ideogram4")
    }

    /// Returns the full path to mflux-generate-krea2 given a binary directory.
    static func mfluxGenerateKrea2(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-generate-krea2") }
        let path = "\(dir)/mflux-generate-krea2"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-krea2")
    }

    /// Returns the full path to mflux-generate-z-image-turbo given a binary directory.
    static func mfluxGenerateZImageTurbo(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-generate-z-image-turbo") }
        let path = "\(dir)/mflux-generate-z-image-turbo"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-z-image-turbo")
    }

    /// Returns the full path to mflux-generate-z-image (base) given a binary directory.
    static func mfluxGenerateZImage(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-generate-z-image") }
        let path = "\(dir)/mflux-generate-z-image"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-z-image")
    }

    /// Returns the full path to mflux-upscale-seedvr2 given a binary directory.
    static func mfluxUpscaleSeedVR2(in dir: String) -> String {
        if dir.isEmpty { return detect("mflux-upscale-seedvr2") }
        let path = "\(dir)/mflux-upscale-seedvr2"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-upscale-seedvr2")
    }

    /// Returns the full path to the mlx_lm.generate binary for LLM caption generation.
    static func mlxLmGenerate(in dir: String) -> String {
        if dir.isEmpty { return detect("mlx_lm.generate") }
        let path = "\(dir)/mlx_lm.generate"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mlx_lm.generate")
    }
}
