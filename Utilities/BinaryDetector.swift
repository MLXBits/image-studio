import Foundation

// Nonisolated: pure filesystem probes, callable from the installers' background work.
nonisolated enum BinaryDetector {
    /// Memoises a probe per interpreter path. The probe spawns a process, so it
    /// must not run on every view body evaluation; keying on the path means a
    /// changed mflux directory in Settings re-probes rather than going stale.
    private final class ProbeCache<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: Value] = [:]

        func value(for key: String, compute: () -> Value) -> Value {
            lock.lock()
            if let hit = results[key] {
                lock.unlock()
                return hit
            }
            lock.unlock()
            let computed = compute()
            lock.lock()
            results[key] = computed
            lock.unlock()
            return computed
        }

        func reset() {
            lock.lock()
            results.removeAll()
            lock.unlock()
        }
    }

    private static let pidDecodeProbeCache = ProbeCache<Bool>()
    private static let mfluxVersionProbeCache = ProbeCache<String?>()
    private static let baseModelProbeCache = ProbeCache<Bool>()

    /// Drops the memoised probes. Call after installing or upgrading mflux: the
    /// interpreter path is unchanged by an upgrade, so the cache key alone cannot
    /// tell that what it points at is now a different version.
    static func invalidateProbes() {
        pidDecodeProbeCache.reset()
        mfluxVersionProbeCache.reset()
        baseModelProbeCache.reset()
    }

    /// The version of the `mflux` package importable by the install rooted at `dir`,
    /// or nil when it cannot be determined. Asks the interpreter rather than reading
    /// a `dist-info` directory name so editable installs resolve correctly.
    static func mfluxVersion(in dir: String) -> String? {
        let shim = mfluxGenerateFlux2(in: dir)
        guard let python = MfluxDriverController.venvPython(fromShim: shim) else { return nil }
        return mfluxVersionProbeCache.value(for: python) {
            runProbe(python: python, code: """
            import importlib.metadata as m, sys
            try:
                sys.stdout.write(m.version("mflux"))
            except Exception:
                pass
            """)
        }
    }

    /// Runs `python -c code` and returns its trimmed stdout, or nil when the process
    /// cannot start or writes nothing.
    private static func runProbe(python: String, code: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", code]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Whether the mflux install rooted at `dir` has the PiD pixel-diffusion
    /// decoder (`--pid-decode`). Gates the toggle in the Dimensions section so it
    /// only appears against an mflux that can honour it.
    ///
    /// PiD is unmerged upstream (filipstrand/mflux#490), so this cannot be
    /// inferred from a version number. Probes for the module rather than a console
    /// script: the flag is added to seven existing scripts, so no new script
    /// appears, and asking the interpreter resolves editable installs (whose
    /// `mflux` lives outside site-packages behind a `.pth`) correctly.
    ///
    /// Remove this gate and its call sites once PiD lands in a released mflux.
    static func supportsPidDecode(in dir: String) -> Bool {
        let shim = mfluxGenerateFlux2(in: dir)
        guard let python = MfluxDriverController.venvPython(fromShim: shim) else { return false }
        return pidDecodeProbeCache.value(for: python) {
            runProbe(python: python, code: """
            import importlib.util as u, pathlib, sys
            s = u.find_spec("mflux")
            loc = (s.submodule_search_locations or [None])[0] if s else None
            ok = loc is not None and (pathlib.Path(loc) / "models/common/pid_decoder").is_dir()
            sys.stdout.write("1" if ok else "0")
            """) == "1"
        }
    }

    /// Whether the mflux install rooted at `dir` accepts `--base-model`. Gates the flag in
    /// ``FluxRunnerSpec``'s buildArgs so a pre-option release is never handed an option its
    /// argparse rejects with exit 2.
    ///
    /// Inspects the parser's own option list rather than comparing versions or trial-parsing a
    /// value: package metadata lies on editable installs (a dev checkout reports an old version
    /// while carrying every registry key), no release boundary marks when the option landed, and
    /// this answers exactly what the gate needs — whether sending the flag would be rejected.
    /// Cached per interpreter like ``supportsPidDecode(in:)``: one process spawn per install
    /// per launch, reset by ``invalidateProbes()`` after installs and upgrades.
    static func supportsBaseModel(in dir: String) -> Bool {
        let shim = mfluxGenerateFlux2(in: dir)
        guard let python = MfluxDriverController.venvPython(fromShim: shim) else { return false }
        return baseModelProbeCache.value(for: python) {
            runProbe(python: python, code: """
            import sys
            ok = False
            try:
                from mflux.models.flux2.cli import flux2_generate as f
                p = f.build_parser()
                ok = any("--base-model" in (a.option_strings or ()) for a in p._actions)
            except BaseException:
                pass
            sys.stdout.write("1" if ok else "0")
            """) == "1"
        }
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

    /// Resolves a console script to a full path, preferring `dir` and falling back
    /// to the standard locations. Returns nil when the script exists nowhere —
    /// unlike the `mfluxGenerate…` helpers below, which return `""` and leave the
    /// caller to hand an empty executable path to `Process`.
    static func resolve(_ name: String, in dir: String) -> String? {
        if !dir.isEmpty {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let fallback = detect(name)
        return fallback.isEmpty ? nil : fallback
    }

    /// Whether the mflux install rooted at `dir` ships the console script this
    /// model variant generates with. Drives the model picker: a family whose CLI
    /// is absent is not offered rather than failing at spawn time.
    ///
    /// Still a filesystem probe rather than a version comparison even though
    /// ``MfluxInstaller/minimumVersion`` now sets a floor: the floor is only a
    /// lower bound, mflux keeps adding CLIs above it, and the directory may point
    /// at a checkout whose version says nothing about which families it carries.
    static func supports(_ variant: FluxModelVariant, in dir: String) -> Bool {
        guard let name = variant.generateCLIName else { return true }
        return resolve(name, in: dir) != nil
    }

    /// Returns the full path to mflux-generate-flux2 given a binary directory.
    static func mfluxGenerateFlux2(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-generate-flux2")
        }
        let path = "\(dir)/mflux-generate-flux2"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-flux2")
    }

    /// Returns the full path to mflux-generate-flux2-edit given a binary directory.
    static func mfluxGenerateFlux2Edit(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-generate-flux2-edit")
        }
        let path = "\(dir)/mflux-generate-flux2-edit"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-flux2-edit")
    }

    /// Returns the full path to mflux-save given a binary directory.
    static func mfluxSave(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-save")
        }
        let path = "\(dir)/mflux-save"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-save")
    }

    /// Returns the full path to mflux-generate-ideogram4 given a binary directory.
    static func mfluxGenerateIdeogram4(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-generate-ideogram4")
        }
        let path = "\(dir)/mflux-generate-ideogram4"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-ideogram4")
    }

    /// Returns the full path to mflux-generate-krea2 given a binary directory.
    static func mfluxGenerateKrea2(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-generate-krea2")
        }
        let path = "\(dir)/mflux-generate-krea2"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-krea2")
    }

    /// Returns the full path to mflux-generate-z-image-turbo given a binary directory.
    static func mfluxGenerateZImageTurbo(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-generate-z-image-turbo")
        }
        let path = "\(dir)/mflux-generate-z-image-turbo"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-z-image-turbo")
    }

    /// Returns the full path to mflux-generate-z-image (base) given a binary directory.
    static func mfluxGenerateZImage(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-generate-z-image")
        }
        let path = "\(dir)/mflux-generate-z-image"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-generate-z-image")
    }

    /// Returns the full path to mflux-upscale-seedvr2 given a binary directory.
    static func mfluxUpscaleSeedVR2(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mflux-upscale-seedvr2")
        }
        let path = "\(dir)/mflux-upscale-seedvr2"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mflux-upscale-seedvr2")
    }

    /// Returns the full path to the mlx_lm.generate binary for LLM caption generation.
    static func mlxLmGenerate(in dir: String) -> String {
        if dir.isEmpty {
            return detect("mlx_lm.generate")
        }
        let path = "\(dir)/mlx_lm.generate"
        return FileManager.default.fileExists(atPath: path) ? path : detect("mlx_lm.generate")
    }
}
