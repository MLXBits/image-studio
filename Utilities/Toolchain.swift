import Foundation

/// Why a Python tool can't start. Shown as-is in job logs, the banner and
/// Settings, so each message says what to do next.
nonisolated enum ToolchainError: LocalizedError, Equatable {
    /// This build carries no bundled runtime: a dev build made with
    /// `BUNDLE_PYTHON_RUNTIME=NO`, or a damaged install.
    case runtimeMissing
    /// The DMG's Custom Python override names nothing runnable.
    case customPythonMissing(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            "Python runtime missing from this build. Reinstall the app."
        case let .customPythonMissing(path):
            "Custom Python not found at \(path). Fix or clear it in Settings → Advanced."
        }
    }
}

/// An interpreter plus the leading arguments that run one tool through it.
/// Callers append the tool's own arguments.
nonisolated struct ToolCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]

    var executableURL: URL {
        URL(fileURLWithPath: executable)
    }
}

/// How the app runs Python (spec §3). Tools run on the runtime bundled in
/// `Contents/Resources/python` or, in the DMG, on a Custom Python override for
/// mflux. Every tool runs as `<interpreter> run_tool.py <tool> <args>`, so the
/// app never depends on launcher scripts whose shebangs hold absolute paths.
///
/// A value built from paths, so tests can point it at a fake bundle.
nonisolated struct Toolchain: Equatable, Sendable {
    /// The app's own cache folder (`Caches/<bundle id>`); inside the container
    /// in the App Store build.
    static var cachesURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "MLXBits Image Studio", isDirectory: true)
    }

    /// The child-process environment (spec §3): no user site-packages, no
    /// bytecode written into the signed bundle, matplotlib's cache in Caches,
    /// and none of the inherited variables that would point the interpreter
    /// at another installation. An app launched from a Terminal inherits the
    /// shell's.
    static func environment(base: [String: String], cachesURL: URL) -> [String: String] {
        var env = base
        for key in ["PYTHONHOME", "PYTHONPATH", "__PYVENV_LAUNCHER__"] {
            env[key] = nil
        }
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["MPLCONFIGDIR"] = cachesURL.appendingPathComponent("matplotlib").path
        return env
    }

    /// The runtime build leaves exactly one entry in `bin/`: `python3.<minor>`.
    private static func findInterpreter(in runtime: URL) -> String? {
        let bin = runtime.appendingPathComponent("bin", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []
        guard let name = names.sorted().first(where: {
            $0.range(of: #"^python3\.\d+$"#, options: .regularExpression) != nil
        }) else { return nil }
        let path = bin.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The bundled interpreter, or nil when this build has no runtime.
    let bundledPython: String?
    /// The Custom Python override with `~` expanded; empty when unset.
    let customPython: String
    /// `Resources/python`, or nil when this build has no runtime.
    let runtimeURL: URL?
    /// The runtime's third-party notices (Help ▸ Acknowledgements).
    let acknowledgementsURL: URL?
    private let runTool: String
    /// Whether the Custom Python existed when this value was built. Checks use
    /// ``customPythonIsRunnable`` instead, since a venv can vanish mid-session;
    /// this snapshot makes a rebuild after that compare unequal, so observers
    /// (the banner) update.
    private let customPythonFound: Bool

    /// Checked live: the venv may have been deleted or moved since launch.
    private var customPythonIsRunnable: Bool {
        !customPython.isEmpty && FileManager.default.isExecutableFile(atPath: customPython)
    }

    /// The first problem that stops a generation, for the banner.
    var problem: ToolchainError? {
        if !customPython.isEmpty, !customPythonIsRunnable {
            return .customPythonMissing(customPython)
        }
        return bundledPython == nil ? .runtimeMissing : nil
    }

    init(resourcesURL: URL?, customPython: String) {
        let fileManager = FileManager.default
        let runtime = resourcesURL?.appendingPathComponent("python", isDirectory: true)
        let python = runtime.flatMap { Self.findInterpreter(in: $0) }
        bundledPython = python
        runtimeURL = python == nil ? nil : runtime
        let acknowledgements = runtime?.appendingPathComponent("Acknowledgements.txt")
        acknowledgementsURL = acknowledgements.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
        runTool = resourcesURL?.appendingPathComponent("run_tool.py").path ?? "run_tool.py"
        let trimmed = customPython.trimmingCharacters(in: .whitespaces)
        self.customPython = trimmed.isEmpty ? "" : (trimmed as NSString).expandingTildeInPath
        customPythonFound = !self.customPython.isEmpty && fileManager.isExecutableFile(atPath: self.customPython)
    }

    /// The bundled interpreter, for everything that never follows the override:
    /// the Hugging Face CLI, local Gemma and the Scenario driver.
    func bundledInterpreter() throws -> String {
        guard let bundledPython else { throw ToolchainError.runtimeMissing }
        return bundledPython
    }

    /// mflux's interpreter: the Custom Python when set, otherwise the bundled
    /// one. The warm mflux driver runs on it too.
    func mfluxInterpreter() throws -> String {
        guard !customPython.isEmpty else { return try bundledInterpreter() }
        guard customPythonIsRunnable else { throw ToolchainError.customPythonMissing(customPython) }
        return customPython
    }

    func interpreter(for tool: PythonTool) throws -> String {
        try tool.isMflux ? mfluxInterpreter() : bundledInterpreter()
    }

    func command(_ tool: PythonTool) throws -> ToolCommand {
        try ToolCommand(executable: interpreter(for: tool), arguments: [runTool, tool.rawValue])
    }

    /// Whether `tool` can run here. The bundled runtime carries every tool (its
    /// build smoke-tests each one). A Custom Python carries the ones whose
    /// launcher sits beside it, as every venv installs them.
    func hasTool(_ tool: PythonTool) -> Bool {
        guard let python = try? interpreter(for: tool) else { return false }
        guard python == customPython else { return true }
        let launcher = ((python as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(tool.rawValue)
        return FileManager.default.fileExists(atPath: launcher)
    }
}
