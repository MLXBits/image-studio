# App Store build, milestone 4: the bundled toolchain — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both flavors run every Python tool on the Python runtime bundled in the app. The DMG keeps a "Custom Python (advanced)" override for development. The uv/mflux installers are deleted. A hidden `--runtime-self-test` flag checks the signed runtime. The result ships as DMG **v0.16.0**.

**Architecture:**
- **`Toolchain`** is one value type that answers three questions: which interpreter runs a tool, the command line for it (`<interpreter> Resources/run_tool.py <tool> <args>`), and the child-process environment.
- **`PythonTool`** is an enum of the eleven tool names, kept in step with `Runtime/tools.txt` by a test.
- **`AppSettings`** owns the current `Toolchain`, rebuilt when the Custom Python setting changes.
- **Every launch site switches to it:** the five job runners, `mflux-save`, the warm driver, `hf`, local Gemma, and the Scenario driver.
- **The old `mfluxBinaryDir` setting is migrated once:**
  - a uv-managed install is dropped;
  - anything else becomes the Custom Python.
- **The app gets a custom `@main`**, so `--runtime-self-test` runs before any app state exists.

**Tech stack:** Swift 5.9 (MainActor default isolation), SwiftUI, Swift Testing, XcodeGen, GitHub Actions.

**Spec:** `docs/specs/2026-10-03-app-store-build-design.md`, §3 (Toolchain), §2 (self-test in the release workflows), §1 (the `BUNDLE_PYTHON_RUNTIME` default, and the name-collision result), §7 (tests), and milestone 4. Read the spec and this plan.

**Branch:** `feature/toolchain`, from `main` (at `770d4b0` or later).

## Global Constraints

**Platform**
- **Deployment target and architecture:** macOS 26.0. Both flavors are **arm64 only** after this plan: the runtime is arm64, and MLX needs Apple silicon.
- **Bundle IDs:**
  - DMG: `com.mlxbits.image-studio`
  - App Store: `com.mlxbits.image-studio.appstore`

**Runtime layout** (built by milestones 1–2, unchanged here)
- **Interpreter:** `Contents/Resources/python/bin/python3.14`. The runtime build leaves exactly one entry in `bin/`, named `python3.<minor>`.
- **Tool launcher:** `Contents/Resources/run_tool.py`.
- **Notices and versions:** `Contents/Resources/python/Acknowledgements.txt` and `Contents/Resources/python/runtime-manifest.json`. The manifest's shape is `{"python": "3.14.7", "lock_sha256": "…", "packages": {"<name>": {"version": "…", "license": "…"}}}`.
- **The eleven tool names**, exactly as `Runtime/tools.txt` lists them:
  - `mflux-generate-flux2`, `mflux-generate-flux2-edit`
  - `mflux-generate-ideogram4`, `mflux-generate-krea2`
  - `mflux-generate-z-image`, `mflux-generate-z-image-turbo`
  - `mflux-upscale-seedvr2`, `mflux-save`
  - `hf`, `mlx_lm.generate`, `mlx_vlm.generate`

**Toolchain rules** (spec §3)
- **Custom Python:**
  - DMG only. It applies to the `mflux-*` tools and the warm mflux driver.
  - `hf`, `mlx_lm.generate`, `mlx_vlm.generate` and the Scenario driver always use the bundled interpreter.
  - The App Store build ignores the setting and hides it.
- **Child environment:** `PYTHONNOUSERSITE=1`, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONUNBUFFERED=1`, and `MPLCONFIGDIR=<Caches>/<bundle id>/matplotlib`. Remove inherited `PYTHONHOME`, `PYTHONPATH` and `__PYVENV_LAUNCHER__`. Keep everything `AppSettings.buildEnvironment()` sets today: `HF_HOME`, `MFLUX_CACHE_DIR`, `HF_HUB_OFFLINE`, `HF_TOKEN`, `PATH`.
- **Error copy, verbatim:**
  - `Python runtime missing from this build. Reinstall the app.`
  - `Custom Python not found at <path>. Fix or clear it in Settings → Advanced.`

**Process**
- **Lint gate before every commit** (CI runs exactly these):
  ```bash
  swiftformat --lint --config .swiftformat .
  swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict
  ```
  `type_contents_order` is the usual catch. Static members go before instance properties, and properties before `init`.
- **New Swift files:** run `xcodegen generate`, then restore the tracked DMG scheme and commit `project.pbxproj`:
  ```bash
  git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
  ```
- **Builds and tests** go through the workspace, into a derived-data folder of their own. The owner's running Debug build lives in Xcode's default DerivedData; don't overwrite it.
  ```bash
  DD="$TMPDIR/image-studio-m4-derived"
  xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio" \
    -derivedDataPath "$DD" test BUNDLE_PYTHON_RUNTIME=NO 2>&1 | tail -40
  ```
  Unit tests use fake runtimes, so `BUNDLE_PYTHON_RUNTIME=NO` keeps them fast. Builds meant to be run use `YES`, the default once Task 9 lands.
- **Tests that create `AppSettings()`** call `settings.suspendPersistence()` before changing any global setting. Without it they write the owner's real `settings.json`.
- **Data safety:**
  - Debug and Release DMG builds share the owner's real Application Support and defaults.
  - Before the first launch of a DMG build from this branch, Task 10 step 1 backs them up.
  - Never launch one while the owner's own copy is running.
- **Commits:** no AI attribution of any kind.

## Review Focus

These are the failure modes most likely to reach a person using the app. Each has a pinning test in the task that owns the code.

1. **Inherited interpreter variables.** The app is launched from a Terminal with `PYTHONHOME` or `PYTHONPATH` set.
   - **Expected:** the bundled interpreter ignores them.
   - **Test:** Task 1, `environmentDropsInheritedInterpreterOverrides`.
2. **A Custom Python that disappears.** The venv is deleted or the checkout moves after the setting was made.
   - **Expected:** jobs fail with the "Custom Python not found …" message and the banner shows it. Nothing falls back to the bundled runtime silently.
   - **Test:** Task 1, `missingCustomPythonIsAnErrorNotASilentFallback`.
3. **Changing the Custom Python while a model is warm.**
   - **Expected:** the next job restarts the driver on the new interpreter, and the old driver's late exit doesn't tear down the new one.
   - **Test:** Task 5, `changingTheCustomPythonRestartsTheDriverOnIt`.
4. **Legacy setting shapes.**
   - `~/.local/bin` (symlinks into uv's tool venv) is recognized as uv-managed and dropped.
   - A launcher written in pip's `/bin/sh` exec form, used for paths with spaces, is unwrapped to its real interpreter.
   - **Tests:** Task 2, `uvShimSymlinkedIntoLocalBinIsDropped` and `shellExecLauncherIsUnwrapped`.
5. **A build without the runtime** (CI's test job, a dev build with `BUNDLE_PYTHON_RUNTIME=NO`).
   - **Expected:** every Python entry point reports "Python runtime missing from this build" instead of spawning a path that doesn't exist.
   - **Tests:**
     - Task 1, `buildWithoutRuntimeReportsItMissing`
     - Task 6, `missingRuntimeIsReported`
     - Task 8, `missingRuntimeFails`

**Manual only** (no unit test is possible; checked in Task 10): **Browse…** on a venv's `bin/python` must keep the symlink path. Resolving it would lose the venv. Task 7 sets `resolvesAliases = false`.

---

### Task 1: `PythonTool`, `Toolchain`, `RuntimeManifest`, `BuildFlavor`

**Files:**
- Create: `Utilities/BuildFlavor.swift`, `Utilities/PythonTool.swift`, `Utilities/Toolchain.swift`, `Utilities/RuntimeManifest.swift`
- Create: `Tests/Support/FakeRuntime.swift`, `Tests/PythonToolTests.swift`, `Tests/ToolchainTests.swift`

**Interfaces:**
- **Produces:**
  - `BuildFlavor.isAppStore: Bool`
  - `enum PythonTool: String, CaseIterable`, with cases `.flux2 .flux2Edit .ideogram4 .krea2 .zImage .zImageTurbo .seedVR2 .save .hf .mlxLmGenerate .mlxVlmGenerate`, and `var isMflux: Bool`
  - `enum ToolchainError: LocalizedError, Equatable { case runtimeMissing; case customPythonMissing(String) }`
  - `struct ToolCommand { let executable: String; let arguments: [String]; var executableURL: URL }`
  - `struct Toolchain`:
    - `init(resourcesURL: URL?, customPython: String)`
    - properties `bundledPython: String?`, `customPython: String`, `runtimeURL: URL?`, `acknowledgementsURL: URL?`, `problem: ToolchainError?`
    - methods `bundledInterpreter() throws -> String`, `mfluxInterpreter() throws -> String`, `interpreter(for:) throws -> String`, `command(_:) throws -> ToolCommand`, `hasTool(_:) -> Bool`
    - statics `environment(base:cachesURL:) -> [String: String]` and `cachesURL: URL`
  - `struct RuntimeManifest`:
    - properties `python: String`, `packages: [String: Package]`
    - `version(of:) -> String?`
    - `static load(from runtimeURL: URL?) -> RuntimeManifest?`
    - `static let bundled: RuntimeManifest?`
  - Test helper `FakeRuntime`:
    - `init(python: String?)`, where `nil` means no runtime
    - `resources`, `python`, `runTool` (URLs) and `toolchain(customPython:)`
    - statics `writeExecutable(_:to:)`, `tempDirectory(_:)`, `succeeding`

- [ ] **Step 1: Write the test helper**

`Tests/Support/FakeRuntime.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio

/// A stand-in for the app's `Contents/Resources`, shaped like the bundled
/// runtime (`python/bin/python3.14`, `run_tool.py`, the acknowledgements and
/// manifest), so Toolchain consumers can be tested without the real 1.6 GB
/// runtime. The interpreter is a shell script the test supplies. The path
/// contains a space, as the real app's does.
struct FakeRuntime {
    /// An interpreter that answers every call with exit 0.
    static let succeeding = "#!/bin/sh\nexit 0\n"

    static let manifestJSON = """
    {"python": "3.14.7", "lock_sha256": "0", "packages": {
      "mflux": {"version": "0.21.0", "license": "MIT"},
      "mlx-lm": {"version": "0.32.0", "license": "MIT"},
      "mlx-vlm": {"version": "0.6.3", "license": "MIT"}}}
    """

    /// A fresh, empty temp folder.
    static func tempDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Writes `script` to `url` as an executable file, creating its folder.
    static func writeExecutable(_ script: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    let resources: URL

    var python: URL {
        resources.appendingPathComponent("python/bin/python3.14")
    }

    var runTool: URL {
        resources.appendingPathComponent("run_tool.py")
    }

    /// `python: nil` builds a bundle without a runtime, like a build made with
    /// `BUNDLE_PYTHON_RUNTIME=NO`.
    init(python script: String? = Self.succeeding) throws {
        resources = Self.tempDirectory("FakeRuntime")
            .appendingPathComponent("Fake App.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("# fake run_tool.py\n".utf8).write(to: runTool)
        if let script {
            try Self.writeExecutable(script, to: python)
            let runtime = resources.appendingPathComponent("python")
            try Data("Acknowledgements\n".utf8).write(to: runtime.appendingPathComponent("Acknowledgements.txt"))
            try Data(Self.manifestJSON.utf8).write(to: runtime.appendingPathComponent("runtime-manifest.json"))
        }
    }

    func toolchain(customPython: String = "") -> Toolchain {
        Toolchain(resourcesURL: resources, customPython: customPython)
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/PythonToolTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The runtime build smoke-tests every name in `Runtime/tools.txt`, so the app
/// must ask for exactly those: a renamed command then fails a test, not a job.
struct PythonToolTests {
    /// `Runtime/tools.txt` from the source tree (tests run from a checkout).
    private func listedTools() throws -> Set<String> {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent("Runtime/tools.txt"), encoding: .utf8)
        return Set(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    @Test func everyToolIsOneTheRuntimeBuildSmokeTests() throws {
        let listed = try listedTools()
        #expect(Set(PythonTool.allCases.map(\.rawValue)) == listed)
    }

    @Test func onlyMfluxToolsFollowTheCustomPython() {
        #expect(PythonTool.allCases.filter(\.isMflux)
            == [.flux2, .flux2Edit, .ideogram4, .krea2, .zImage, .zImageTurbo, .seedVR2, .save])
    }
}
```

`Tests/ToolchainTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers how the app resolves Python (spec §3): the bundled runtime by default,
/// the DMG's Custom Python for mflux only, and clear errors instead of silent
/// fallbacks when either is missing.
struct ToolchainTests {
    /// A venv-shaped folder outside the fake bundle: `bin/python` plus the given launchers.
    private func customVenv(launchers: [PythonTool] = []) throws -> String {
        let bin = FakeRuntime.tempDirectory("venv").appendingPathComponent("bin", isDirectory: true)
        try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: bin.appendingPathComponent("python"))
        for tool in launchers {
            try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: bin.appendingPathComponent(tool.rawValue))
        }
        return bin.appendingPathComponent("python").path
    }

    @Test func toolsRunThroughRunToolOnTheBundledInterpreter() throws {
        let runtime = try FakeRuntime()
        let command = try runtime.toolchain().command(.flux2)
        #expect(command.executable == runtime.python.path)
        #expect(command.arguments == [runtime.runTool.path, "mflux-generate-flux2"])
    }

    @Test func customPythonRunsMfluxToolsOnly() throws {
        let runtime = try FakeRuntime()
        let custom = try customVenv()
        let toolchain = runtime.toolchain(customPython: custom)
        #expect(try toolchain.command(.flux2).executable == custom)
        #expect(try toolchain.command(.save).executable == custom)
        #expect(try toolchain.mfluxInterpreter() == custom)
        #expect(try toolchain.command(.hf).executable == runtime.python.path)
        #expect(try toolchain.command(.mlxLmGenerate).executable == runtime.python.path)
        #expect(try toolchain.bundledInterpreter() == runtime.python.path)
    }

    @Test func missingCustomPythonIsAnErrorNotASilentFallback() throws {
        let toolchain = try FakeRuntime().toolchain(customPython: "/nonexistent/venv/bin/python")
        #expect(throws: ToolchainError.customPythonMissing("/nonexistent/venv/bin/python")) {
            try toolchain.command(.flux2)
        }
        #expect(toolchain.problem == .customPythonMissing("/nonexistent/venv/bin/python"))
        #expect(!toolchain.hasTool(.flux2))
        // Tools that never follow the override are unaffected.
        #expect(throws: Never.self) { try toolchain.command(.hf) }
    }

    @Test func tildeInCustomPythonIsExpanded() throws {
        let toolchain = try FakeRuntime().toolchain(customPython: "~/no-such-venv/bin/python")
        #expect(toolchain.customPython == NSHomeDirectory() + "/no-such-venv/bin/python")
    }

    @Test func buildWithoutRuntimeReportsItMissing() throws {
        let toolchain = try FakeRuntime(python: nil).toolchain()
        #expect(toolchain.bundledPython == nil)
        #expect(toolchain.problem == .runtimeMissing)
        #expect(throws: ToolchainError.runtimeMissing) { try toolchain.command(.flux2) }
        #expect(throws: ToolchainError.runtimeMissing) { try toolchain.command(.mlxLmGenerate) }
        #expect(!toolchain.hasTool(.flux2))
        #expect(toolchain.acknowledgementsURL == nil)
        #expect(toolchain.runtimeURL == nil)
    }

    @Test func noResourcesFolderMeansNoRuntime() {
        let toolchain = Toolchain(resourcesURL: nil, customPython: "")
        #expect(toolchain.problem == .runtimeMissing)
    }

    @Test func bundledRuntimeHasEveryTool() throws {
        let toolchain = try FakeRuntime().toolchain()
        #expect(toolchain.problem == nil)
        #expect(PythonTool.allCases.allSatisfy { toolchain.hasTool($0) })
    }

    /// Every venv installs its launchers beside its interpreter; a family whose
    /// launcher is absent is one that install can't run.
    @Test func customPythonHasTheToolsInstalledBesideIt() throws {
        let toolchain = try FakeRuntime().toolchain(customPython: customVenv(launchers: [.flux2]))
        #expect(toolchain.hasTool(.flux2))
        #expect(!toolchain.hasTool(.krea2))
        #expect(toolchain.hasTool(.hf)) // bundled, regardless of the override
    }

    @Test func acknowledgementsAndManifestComeFromTheRuntime() throws {
        let runtime = try FakeRuntime()
        let toolchain = runtime.toolchain()
        #expect(toolchain.acknowledgementsURL?.lastPathComponent == "Acknowledgements.txt")
        let manifest = try #require(RuntimeManifest.load(from: toolchain.runtimeURL))
        #expect(manifest.python == "3.14.7")
        #expect(manifest.version(of: "mflux") == "0.21.0")
        #expect(manifest.version(of: "not-a-package") == nil)
    }

    @Test func environmentDropsInheritedInterpreterOverrides() {
        let caches = URL(fileURLWithPath: "/tmp/caches")
        let env = Toolchain.environment(
            base: [
                "PYTHONHOME": "/elsewhere", "PYTHONPATH": "/elsewhere/lib",
                "__PYVENV_LAUNCHER__": "/elsewhere/bin/python", "HF_HOME": "/models",
            ],
            cachesURL: caches
        )
        #expect(env["PYTHONHOME"] == nil)
        #expect(env["PYTHONPATH"] == nil)
        #expect(env["__PYVENV_LAUNCHER__"] == nil)
        #expect(env["HF_HOME"] == "/models")
        #expect(env["PYTHONNOUSERSITE"] == "1")
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1")
        #expect(env["PYTHONUNBUFFERED"] == "1")
        #expect(env["MPLCONFIGDIR"] == "/tmp/caches/matplotlib")
    }
}
```

- [ ] **Step 3: Generate the project and run the tests to see them fail**

```bash
xcodegen generate
git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio" \
  -derivedDataPath "$DD" test BUNDLE_PYTHON_RUNTIME=NO 2>&1 | grep -E "error:|Test run" | head -20
```

Expected: compile errors such as `cannot find type 'Toolchain' in scope` and `cannot find 'PythonTool' in scope`.

- [ ] **Step 4: Implement**

`Utilities/BuildFlavor.swift`:

```swift
/// Which app this binary is: the GitHub DMG or the sandboxed App Store build.
/// A constant rather than `#if` at each use, so both sides of every check
/// compile in both flavors (spec §7) and CI's App Store compile job catches
/// breakage in either.
nonisolated enum BuildFlavor {
    #if APP_STORE
        static let isAppStore = true
    #else
        static let isAppStore = false
    #endif
}
```

`Utilities/PythonTool.swift`:

```swift
/// A command-line tool the app runs from a Python environment. Raw values are
/// the console-script names, the same names as mflux's old launcher scripts,
/// and must match `Runtime/tools.txt`: the runtime build smoke-tests every name
/// listed there, and `PythonToolTests` keeps the two in step.
nonisolated enum PythonTool: String, CaseIterable, Sendable {
    case flux2 = "mflux-generate-flux2"
    case flux2Edit = "mflux-generate-flux2-edit"
    case ideogram4 = "mflux-generate-ideogram4"
    case krea2 = "mflux-generate-krea2"
    case zImage = "mflux-generate-z-image"
    case zImageTurbo = "mflux-generate-z-image-turbo"
    case seedVR2 = "mflux-upscale-seedvr2"
    case save = "mflux-save"
    case hf
    case mlxLmGenerate = "mlx_lm.generate"
    case mlxVlmGenerate = "mlx_vlm.generate"

    /// mflux's own tools follow the DMG's Custom Python override. The rest (the
    /// Hugging Face CLI, local Gemma) always run on the bundled runtime.
    var isMflux: Bool {
        rawValue.hasPrefix("mflux-")
    }
}
```

`Utilities/Toolchain.swift`:

```swift
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
    private let customPythonIsRunnable: Bool

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
        customPythonIsRunnable = !self.customPython.isEmpty && fileManager.isExecutableFile(atPath: self.customPython)
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
```

`Utilities/RuntimeManifest.swift`:

```swift
import Foundation

/// `python/runtime-manifest.json`, written by the runtime build: the Python
/// version and every package's version and license.
nonisolated struct RuntimeManifest: Decodable, Equatable, Sendable {
    struct Package: Decodable, Equatable, Sendable {
        let version: String
        let license: String?
    }

    /// This app's own runtime. Read once: a bundle doesn't change while it runs.
    static let bundled: RuntimeManifest? = load(from: Toolchain(
        resourcesURL: Bundle.main.resourceURL, customPython: ""
    ).runtimeURL)

    /// The manifest inside `runtimeURL`, or nil when it's absent or unreadable.
    static func load(from runtimeURL: URL?) -> RuntimeManifest? {
        guard let url = runtimeURL?.appendingPathComponent("runtime-manifest.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    let python: String
    let packages: [String: Package]

    func version(of package: String) -> String? {
        packages[package]?.version
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

```bash
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio" \
  -derivedDataPath "$DD" test BUNDLE_PYTHON_RUNTIME=NO \
  -only-testing:"MLXBits Image StudioTests/ToolchainTests" \
  -only-testing:"MLXBits Image StudioTests/PythonToolTests" 2>&1 | grep -E "✔|✘|passed|failed" | tail -20
```

Expected: all `ToolchainTests` and `PythonToolTests` pass.

- [ ] **Step 6: Lint and commit**

```bash
swiftformat --lint --config .swiftformat . && swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict
git add Utilities/BuildFlavor.swift Utilities/PythonTool.swift Utilities/Toolchain.swift Utilities/RuntimeManifest.swift \
  Tests/Support/FakeRuntime.swift Tests/PythonToolTests.swift Tests/ToolchainTests.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: Toolchain resolves how every Python tool runs"
```

---

### Task 2: Migrate the old mflux folder setting

**Files:**
- Create: `Utilities/ToolchainMigration.swift`, `Tests/ToolchainMigrationTests.swift`
- Modify:
  - `Runner/MfluxDriverController.swift:22-36` (move `venvPython(fromShim:)` out)
  - `Utilities/BinaryDetector.swift` (three `MfluxDriverController.venvPython` calls)
  - `Utilities/MfluxInstaller.swift:79` (one call)

**Interfaces:**
- **Consumes:** `PythonTool.flux2` (Task 1).
- **Produces:**
  - `ToolchainMigration.customPython(fromLegacyBinaryDir: String) -> String?`
  - `ToolchainMigration.isUVManaged(python: String) -> Bool`
  - `ToolchainMigration.venvPython(fromShim: String) -> String?`

- [ ] **Step 1: Write the failing tests**

`Tests/ToolchainMigrationTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The one-time move from the old "mflux binary directory" setting (spec §3):
/// a uv-managed mflux (the one the app used to install) gives way to the
/// bundled runtime, and anything else becomes the Custom Python.
struct ToolchainMigrationTests {
    /// An interpreter plus an `mflux-generate-flux2` launcher naming it, in `bin`.
    @discardableResult
    private func venv(at bin: URL, launcher: ((String) -> String)? = nil) throws -> String {
        let python = bin.appendingPathComponent("python").path
        try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: URL(fileURLWithPath: python))
        let shim = launcher?(python) ?? "#!\(python)\nimport sys\n"
        try Data(shim.utf8).write(to: bin.appendingPathComponent("mflux-generate-flux2"))
        return python
    }

    @Test func devCheckoutBecomesTheCustomPython() throws {
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent("Git/mflux/.venv/bin")
        let python = try venv(at: bin)
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == python)
    }

    @Test func uvManagedInstallFallsBackToBundled() throws {
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent(".local/share/uv/tools/mflux/bin")
        try venv(at: bin)
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == nil)
    }

    /// uv puts symlinks to its tool launchers in ~/.local/bin, which is what the
    /// old auto-detection stored.
    @Test func uvShimSymlinkedIntoLocalBinIsDropped() throws {
        let home = FakeRuntime.tempDirectory("home")
        let toolBin = home.appendingPathComponent(".local/share/uv/tools/mflux/bin")
        try venv(at: toolBin)
        let localBin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: localBin.appendingPathComponent("mflux-generate-flux2"),
            withDestinationURL: toolBin.appendingPathComponent("mflux-generate-flux2")
        )
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: localBin.path) == nil)
    }

    /// pip writes this form when the interpreter's path has spaces or is long.
    @Test func shellExecLauncherIsUnwrapped() throws {
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent("My Projects/mflux/.venv/bin")
        let python = try venv(at: bin) { python in
            "#!/bin/sh\n'''exec' \"\(python)\" \"$0\" \"$@\"\n' '''\nimport sys\n"
        }
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == python)
    }

    @Test func emptyOrStaleSettingsUseBundled() throws {
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: "") == nil)
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: "/nonexistent/bin") == nil)
        // A launcher whose interpreter has since been deleted.
        let bin = FakeRuntime.tempDirectory("home").appendingPathComponent("gone/.venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/nonexistent/python\n".utf8).write(to: bin.appendingPathComponent("mflux-generate-flux2"))
        #expect(ToolchainMigration.customPython(fromLegacyBinaryDir: bin.path) == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodegen generate`, restore the DMG scheme, then run the test command with `-only-testing:"MLXBits Image StudioTests/ToolchainMigrationTests"`.

Expected: `cannot find 'ToolchainMigration' in scope`.

- [ ] **Step 3: Implement, moving `venvPython(fromShim:)` out of the driver**

`Utilities/ToolchainMigration.swift`:

```swift
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
```

Then:
- Delete `venvPython(fromShim:)` and its doc comment from `Runner/MfluxDriverController.swift`. It is the first item under `// MARK: - Static helpers`.
- Replace every `MfluxDriverController.venvPython(` with `ToolchainMigration.venvPython(`. The callers are `Utilities/BinaryDetector.swift` (three) and `Utilities/MfluxInstaller.swift` (one). In `Runner/MfluxDriverController.swift`, `start()` calls it as `Self.venvPython(`; that becomes `ToolchainMigration.venvPython(`.

```bash
grep -rn "venvPython" --include='*.swift' App Models Runner Stores Utilities Views
```
Expected: only `ToolchainMigration.venvPython` references remain.

- [ ] **Step 4: Run the new tests and the full suite**

Run the full test command from Global Constraints.
Expected: the 5 new tests pass, and every existing test passes.

- [ ] **Step 5: Lint and commit**

```bash
git add Utilities/ToolchainMigration.swift Tests/ToolchainMigrationTests.swift Runner/MfluxDriverController.swift \
  Utilities/BinaryDetector.swift Utilities/MfluxInstaller.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: migrate the mflux folder setting to the bundled runtime or a Custom Python"
```

---

### Task 3: `AppSettings` owns the toolchain

**Files:**
- Modify: `Stores/AppSettings.swift`:
  - `Stored` (`:58-…`)
  - static helpers (`:165-171`)
  - properties (`:173-183`)
  - `init` (`:588-…`)
  - `saveNow` (`:834-…`)
  - `buildEnvironment` (`:963-981`)
- Create: `Tests/AppSettingsToolchainTests.swift`

**Interfaces:**
- **Consumes:** `Toolchain`, `BuildFlavor` (Task 1), and `ToolchainMigration.customPython(fromLegacyBinaryDir:)` (Task 2).
- **Produces:**
  - `AppSettings.customPythonPath: String` (global, persisted as `customPython`)
  - `AppSettings.toolchain: Toolchain` (`private(set)`)
  - `buildEnvironment()` now returns `Toolchain.environment(base:cachesURL:)` applied to today's environment

- [ ] **Step 1: Write the failing tests**

`Tests/AppSettingsToolchainTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// AppSettings rebuilds its Toolchain when the Custom Python changes, and every
/// child process gets the Python environment from it.
struct AppSettingsToolchainTests {
    @Test func changingTheCustomPythonRebuildsTheToolchain() {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.customPythonPath = "/nonexistent/venv/bin/python"
        #expect(settings.toolchain.customPython == "/nonexistent/venv/bin/python")
        #expect(settings.toolchain.problem == .customPythonMissing("/nonexistent/venv/bin/python"))
        settings.customPythonPath = ""
        #expect(settings.toolchain.customPython.isEmpty)
    }

    @Test func childProcessesGetThePythonEnvironment() {
        let settings = AppSettings()
        settings.suspendPersistence()
        let env = settings.buildEnvironment()
        #expect(env["PYTHONNOUSERSITE"] == "1")
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1")
        #expect(env["MPLCONFIGDIR"]?.hasSuffix("/matplotlib") == true)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Expected: `value of type 'AppSettings' has no member 'customPythonPath'`.

- [ ] **Step 3: Implement**

In `Stored`, after `var mfluxBinaryDir: String?`, add:

```swift
        /// DMG only: the Custom Python override (spec §3). Absent until the
        /// first launch of 0.16.0 migrates `mfluxBinaryDir` into it.
        var customPython: String?
```

Next to `loadStored()` (static methods come before instance properties), add:

```swift
    /// The App Store build has no Custom Python (spec §3), whatever the file says.
    private static func makeToolchain(customPython: String) -> Toolchain {
        Toolchain(resourcesURL: Bundle.main.resourceURL, customPython: BuildFlavor.isAppStore ? "" : customPython)
    }
```

Directly below the `mfluxBinaryDir` property, add:

```swift
    /// Global, DMG only: an interpreter that runs mflux and the warm driver in
    /// place of the bundled runtime, such as a dev checkout's `.venv/bin/python`.
    var customPythonPath: String {
        didSet {
            toolchain = Self.makeToolchain(customPython: customPythonPath)
            refreshAvailableModels()
            save()
        }
    }

    /// How Python tools run. Rebuilt when ``customPythonPath`` changes.
    private(set) var toolchain: Toolchain
```

In `init()`, directly after the `mfluxBinaryDir = …` line, add:

```swift
        // First launch of 0.16.0: carry a dev checkout over as the Custom
        // Python; a uv-managed install (or none) means the bundled runtime.
        customPythonPath = s.customPython
            ?? ToolchainMigration.customPython(fromLegacyBinaryDir: s.mfluxBinaryDir ?? "")
            ?? ""
        toolchain = Self.makeToolchain(customPython: customPythonPath)
```

The migration runs again on every launch until a save writes `customPython`. It gives the same answer each time, and `ProfileStore`'s bootstrap calls `persistGlobalNow()` on every launch, so the key is written at the first launch.

In `saveNow()`, add `customPython: customPythonPath,` to the `Stored(…)` call, directly after `mfluxBinaryDir: mfluxBinaryDir,`. The memberwise initializer takes arguments in declaration order.

Replace `buildEnvironment()` with:

```swift
    func buildEnvironment() -> [String: String] {
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if !hfHome.isEmpty {
            env["HF_HOME"] = hfHome
        }
        if !mfluxCacheDir.isEmpty {
            env["MFLUX_CACHE_DIR"] = mfluxCacheDir
        }
        if hfOffline {
            env["HF_HUB_OFFLINE"] = "1"
        }
        if !hfToken.isEmpty {
            env["HF_TOKEN"] = hfToken
        }
        return Toolchain.environment(base: env, cachesURL: Toolchain.cachesURL)
    }
```

`PYTHONUNBUFFERED` now comes from `Toolchain.environment`.

- [ ] **Step 4: Run the tests to see them pass**

Run the full test command.
Expected: both new tests pass, and every existing test passes.

- [ ] **Step 5: Lint and commit**

```bash
git add Stores/AppSettings.swift Tests/AppSettingsToolchainTests.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: settings carry the Custom Python and the toolchain built from it"
```

---

### Task 4: Job runners, `mflux-save`, `hf` and model availability run on the toolchain

**Files:**
- Create: `Utilities/MfluxProbes.swift`, `Tests/MfluxProbesTests.swift`, `Tests/ModelAvailabilityTests.swift`
- Modify:
  - `Runner/JobRunner.swift:66-73` (the spec protocol), `:323-363` (launch), `:624-638` (`runSave`)
  - the five specs:
    - `Runner/FluxJobRunner.swift:20-38, :143-149`
    - `Runner/ZImageJobRunner.swift`
    - `Runner/Krea2JobRunner.swift`
    - `Runner/Ideogram4JobRunner.swift`
    - `Runner/SeedVR2JobRunner.swift`
  - `Models/FluxModelCatalog.swift:24-30, :187-204`
  - `Stores/AppSettings.swift`:
    - `refreshAvailableModels`, `supportsModel` docs
    - the binary-path helpers at `:910-940`
  - `Views/Settings/ModelDefaultsView.swift:440-466, :504-540`
  - `Views/ParamsPanel/PidDecodeToggleView.swift:60-62`
  - `Utilities/BinaryDetector.swift`
  - `App/ContentView.swift`, `Views/Settings/SettingsView.swift` (drop two `invalidateProbes()` lines)
  - doc comments in `Models/FluxJob.swift`, `Models/Ideogram4Job.swift`, `Models/Krea2Job.swift`, `Models/ZImageJob.swift`

**Interfaces:**
- **Consumes:** `AppSettings.toolchain` (Task 3), `PythonTool`, `ToolCommand`, `Toolchain.environment` (Task 1).
- **Produces:**
  - `JobRunnerSpec.tool(job:) -> PythonTool`, which replaces `binaryName`, `binaryPath` and `saveBinaryPath`
  - `FluxModelVariant.generateTool: PythonTool?`, which replaces `generateCLIName`
  - `FluxModelVariant.customTargets(toolchain:)`
  - `MfluxProbes.mfluxVersion(python: String?) -> String?`
  - `MfluxProbes.supportsPidDecode(python:) -> Bool`
  - `MfluxProbes.supportsBaseModel(python:) -> Bool`

- [ ] **Step 1: Write the failing tests**

`Tests/MfluxProbesTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The probes ask the interpreter they're given (the bundled one or the Custom
/// Python) and treat "no interpreter" as "unsupported".
struct MfluxProbesTests {
    private func interpreter(printing output: String) throws -> String {
        let url = FakeRuntime.tempDirectory("probe").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("#!/bin/sh\nprintf '\(output)'\n", to: url)
        return url.path
    }

    @Test func capabilityProbesAskTheGivenInterpreter() throws {
        let yes = try interpreter(printing: "1")
        let no = try interpreter(printing: "0")
        #expect(MfluxProbes.supportsBaseModel(python: yes))
        #expect(MfluxProbes.supportsPidDecode(python: yes))
        #expect(!MfluxProbes.supportsBaseModel(python: no))
    }

    @Test func versionComesFromTheInterpreter() throws {
        let python = try interpreter(printing: "0.21.0")
        #expect(MfluxProbes.mfluxVersion(python: python) == "0.21.0")
    }

    @Test func noInterpreterMeansUnsupported() {
        #expect(!MfluxProbes.supportsBaseModel(python: nil))
        #expect(!MfluxProbes.supportsPidDecode(python: nil))
        #expect(MfluxProbes.mfluxVersion(python: nil) == nil)
    }
}
```

`Tests/ModelAvailabilityTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The model picker offers a family only when the active toolchain can run its
/// CLI: always with the bundled runtime, and per installed launcher with a
/// Custom Python.
struct ModelAvailabilityTests {
    @Test func bundledRuntimeOffersEveryModel() throws {
        let toolchain = try FakeRuntime().toolchain()
        #expect(FluxModelVariant.customTargets(toolchain: toolchain) == FluxModelVariant.allModels)
    }

    @Test func customPythonOffersOnlyFamiliesItHasLaunchersFor() throws {
        let bin = FakeRuntime.tempDirectory("venv").appendingPathComponent("bin")
        try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: bin.appendingPathComponent("python"))
        try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: bin.appendingPathComponent("mflux-generate-flux2"))
        let toolchain = try FakeRuntime().toolchain(customPython: bin.appendingPathComponent("python").path)
        #expect(FluxModelVariant.customTargets(toolchain: toolchain) == FluxModelVariant.builtIn)
    }

    @Test func everyModelNamesAToolTheRuntimeShips() {
        for model in FluxModelVariant.allModels {
            #expect(model.generateTool != nil, "\(model) has no generation tool")
        }
        #expect(FluxModelVariant.custom.generateTool == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Expected: `cannot find 'MfluxProbes' in scope`, and `customTargets(toolchain:)` / `generateTool` don't exist.

- [ ] **Step 3: Create `MfluxProbes`, moving the probe code out of `BinaryDetector`**

`Utilities/MfluxProbes.swift` takes these from `BinaryDetector`, unchanged:
- the `ProbeCache` class, minus its `reset()`
- `runProbe(python:code:)`
- the three probe bodies, with their doc comments and probe Python source

Only the keys and the environment change:

```swift
import Foundation

/// Questions asked of the interpreter mflux runs on: its mflux version, and
/// whether it accepts options the app sends only when supported. Each probe
/// spawns that interpreter once and is cached by its path for the rest of the
/// launch, so choosing another Custom Python asks again.
// Nonisolated: process probes, callable off the main actor.
nonisolated enum MfluxProbes {
    // ProbeCache: moved from BinaryDetector unchanged, minus reset().

    private static let pidDecodeCache = ProbeCache<Bool>()
    private static let versionCache = ProbeCache<String?>()
    private static let baseModelCache = ProbeCache<Bool>()

    /// The `mflux` version importable by `python`, or nil when there is none.
    static func mfluxVersion(python: String?) -> String? {
        guard let python else { return nil }
        return versionCache.value(for: python) {
            runProbe(python: python, code: """
            import importlib.metadata as m, sys
            try:
                sys.stdout.write(m.version("mflux"))
            except Exception:
                pass
            """)
        }
    }

    // supportsPidDecode(python: String?) -> Bool and supportsBaseModel(python: String?) -> Bool:
    // the existing bodies and doc comments, with `guard let python else { return false }`
    // in place of the shim lookup, and pidDecodeCache / baseModelCache as the caches.

    /// Runs `python -c code` with the toolchain environment, and returns its trimmed
    /// stdout, or nil when the process can't start or writes nothing.
    private static func runProbe(python: String, code: String) -> String? {
        // existing body, plus:
        // proc.environment = Toolchain.environment(
        //     base: ProcessInfo.processInfo.environment, cachesURL: Toolchain.cachesURL)
    }
}
```

`supportsPidDecode`'s doc comment says "Remove this gate and its call sites once PiD lands in a released mflux"; keep it.

- [ ] **Step 4: Switch the job runners to `PythonTool`**

In `Runner/JobRunner.swift`'s `JobRunnerSpec`, replace:

```swift
    /// CLI name shown in the "not found" error message.
    static func binaryName(job: Job) -> String
    static func binaryPath(job: Job, settings: AppSettings) -> String
```

with:

```swift
    /// The tool that generates `job`, run through ``Toolchain``.
    static func tool(job: Job) -> PythonTool
```

Delete the `static func saveBinaryPath(settings: AppSettings) -> String` requirement.

In each spec, delete `binaryName`, `binaryPath` and `saveBinaryPath`, and add `tool(job:)`:

| Spec | `tool(job:)` returns |
|---|---|
| `FluxRunnerSpec` | `job.isEditMode ? .flux2Edit : .flux2` |
| `ZImageRunnerSpec` | `job.isTurbo ? .zImageTurbo : .zImage` |
| `Krea2RunnerSpec` | `.krea2` |
| `Ideogram4RunnerSpec` | `.ideogram4` |
| `SeedVR2RunnerSpec` | `.seedVR2` |

Unused parameters are spelled `job _: Krea2Job`, as the old `binaryPath` signatures do.

In `JobRunner.run`, replace the binary check (`let binaryPath = Spec.binaryPath(…)` through its `guard … return }`) with:

```swift
        let tool = Spec.tool(job: job)
        let command: ToolCommand
        do {
            command = try settings.toolchain.command(tool)
        } catch {
            finishJob(job, status: .failed(error.localizedDescription), stepDir: stepDir)
            return
        }
```

Replace the one-shot launch lines:

```swift
        job.log += "$ \(tool.rawValue) \(args.joined(separator: " "))\n\n"

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments + args
        process.environment = settings.buildEnvironment()
```

In `runSave`, replace the `saveBinary` lookup, its guard, and the `executableURL`/`arguments` lines:

```swift
        guard let save = try? settings.toolchain.command(.save) else {
            job.log += "⚠️  mflux-save unavailable — falling back to in-memory quantization.\n"
            return .success // non-fatal: generate will quantize in-memory instead
        }
        …
        process.executableURL = save.executableURL
        process.arguments = save.arguments + args
```

The `…` stands for the unchanged lines between them. The `args` local stays as is.

In `FluxRunnerSpec.baseModelArgs`, change the guard to:

```swift
        guard MfluxProbes.supportsBaseModel(python: try? settings.toolchain.mfluxInterpreter()) else { return [] }
```

Update its doc comment's ``BinaryDetector/supportsBaseModel(in:)`` reference to ``MfluxProbes/supportsBaseModel(python:)``, and "Probed per install" to "Probed per interpreter".

- [ ] **Step 5: Switch model availability**

In `Models/FluxModelCatalog.swift`:

```swift
    /// Models the `custom` picker entry can load through: every variant the app
    /// has a params panel for, minus any whose tool the toolchain can't run.
    /// A custom checkpoint is run by its target family's runner, so the target
    /// must be one this toolchain can actually spawn.
    static func customTargets(toolchain: Toolchain) -> [Self] {
        allModels.filter { model in model.generateTool.map(toolchain.hasTool) ?? true }
    }
```

```swift
    /// The tool this variant generates with, or nil when the variant has no
    /// tool of its own (`custom` inherits its target's). The bundled runtime
    /// ships every one; a Custom Python may not (see ``Toolchain/hasTool(_:)``).
    var generateTool: PythonTool? {
        switch self {
        case .flux2Klein4B, .flux2Klein9B, .flux2KleinBase4B, .flux2KleinBase9B: .flux2
        case .ideogram4: .ideogram4
        case .krea2: .krea2
        case .zimageTurbo: .zImageTurbo
        case .zimage: .zImage
        case .custom: nil
        }
    }
```

In `Stores/AppSettings.swift`, `refreshAvailableModels()` becomes:

```swift
    /// Re-checks which families the current toolchain can run. Called when the
    /// Custom Python changes.
    func refreshAvailableModels() {
        availableModels = FluxModelVariant.customTargets(toolchain: toolchain)
    }
```

In `supportsModel`'s doc, change "(mflux not installed yet, or installed somewhere unexpected)" to "(no runtime and no usable Custom Python)". The `availableModels` doc becomes "Models the current toolchain ships a generation tool for."

`init()` already calls `refreshAvailableModels()` last, after `toolchain` is set.

Delete these helpers from `AppSettings`:
- `mfluxEditBinaryPath()`, `mfluxIdeogram4BinaryPath()`, `mfluxKrea2BinaryPath()`
- `mfluxZImageBinaryPath(turbo:)`, `mfluxSeedVR2BinaryPath()`, `mlxLmBinaryPath()`

Keep `mfluxBinaryPath()` until Task 7.

- [ ] **Step 6: Switch the Settings model tools and the PiD toggle**

`Views/Settings/ModelDefaultsView.swift`, `runPreQuantizedDownload`: replace the `hfBinary` lookup and its guard with:

```swift
        let hf: ToolCommand
        do {
            hf = try settings.toolchain.command(.hf)
        } catch {
            cachePhase = .failed(error.localizedDescription)
            return
        }
```

Replace the launch lines with `process.executableURL = hf.executableURL` and `process.arguments = hf.arguments + ["download", repo]`. The comment about `hf` replacing `huggingface-cli` stays.

`runMfluxSave`: replace the `saveBinary` lookup, including the Ideogram 4 special case and its comment, and the guard, with:

```swift
        let save: ToolCommand
        do {
            save = try settings.toolchain.command(.save)
        } catch {
            cachePhase = .failed(error.localizedDescription)
            return
        }
```

Then use `process.executableURL = save.executableURL` and `process.arguments = save.arguments + args`.

`Views/ParamsPanel/PidDecodeToggleView.swift`:

```swift
    private var isSupported: Bool {
        MfluxProbes.supportsPidDecode(python: try? settings.toolchain.mfluxInterpreter())
    }
```

Update the file's header comment: `BinaryDetector.supportsPidDecode` becomes `MfluxProbes.supportsPidDecode`.

- [ ] **Step 7: Trim `BinaryDetector` to what Task 7 deletes**

From `Utilities/BinaryDetector.swift`, delete:
- `ProbeCache`, the three caches, `invalidateProbes()`, `runProbe`
- `supportsPidDecode(in:)`, `supportsBaseModel(in:)`
- `resolve(_:in:)`, `supports(_:in:)`
- the `mfluxGenerate…` helpers **except** `mfluxGenerateFlux2(in:)`
- `mfluxSave(in:)`, `mlxLmGenerate(in:)`

Rewrite `mfluxVersion(in:)` as a forwarder:

```swift
    /// Used only by the install flow, which Task 7 of the M4 plan deletes along with this type.
    static func mfluxVersion(in dir: String) -> String? {
        MfluxProbes.mfluxVersion(python: ToolchainMigration.venvPython(fromShim: mfluxGenerateFlux2(in: dir)))
    }
```

Delete the `BinaryDetector.invalidateProbes()` line in `App/ContentView.swift` (`runMfluxInstall`) and in `Views/Settings/SettingsView.swift` (`installMflux`). Both functions are deleted in Task 7.

In the four `Models/*Job.swift` doc comments, replace ``BinaryDetector/supportsPidDecode(in:)`` with ``MfluxProbes/supportsPidDecode(python:)``.

- [ ] **Step 8: Build, run the tests, grep**

```bash
xcodegen generate && git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
# full test command
grep -rn "binaryPath\|saveBinaryPath\|binaryName\|generateCLIName\|BinaryDetector.supports\|BinaryDetector.mfluxSave\|BinaryDetector.detect(\"hf\")" \
  --include='*.swift' App Models Runner Stores Utilities Views Tests
```

Expected:
- **Tests:** all pass, including the 6 new ones.
- **grep:** no matches.

- [ ] **Step 9: Lint and commit**

```bash
git add -A Utilities Runner Models Stores Views App Tests "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: job runners, mflux-save and hf run through the toolchain"
```

---

### Task 5: The warm driver runs on the toolchain and restarts when the interpreter changes

**Files:**
- Modify: `Runner/MfluxDriverController.swift`:
  - header doc (`:3-12`)
  - state (`:55-…`)
  - `ensureRunning` (`:114-124`)
  - `start` (`:132-…`)
  - `processDied` (`:216`)
- Create: `Tests/MfluxDriverControllerTests.swift`

**Interfaces:**
- **Consumes:**
  - `AppSettings.toolchain` and `customPythonPath` (Task 3)
  - `Toolchain.mfluxInterpreter()` (Task 1)
- **Produces:**
  - `MfluxDriverController.interpreter: String?` (`private(set)`)
  - `MfluxDriverController.isRunning: Bool`

- [ ] **Step 1: Write the failing test**

`Tests/MfluxDriverControllerTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The warm driver follows the toolchain: a changed Custom Python retires the
/// running driver and starts the next one on the new interpreter.
struct MfluxDriverControllerTests {
    /// Stands in for Python running mflux_driver.py: ignores the script path,
    /// answers each `hello` with `ready`, and runs until stdin closes.
    private func fakeInterpreter() throws -> String {
        let url = FakeRuntime.tempDirectory("driver").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in *hello*) echo '{"event":"ready","mflux_version":"0","python":"3"}' ;; esac
        done
        """, to: url)
        return url.path
    }

    @Test func changingTheCustomPythonRestartsTheDriverOnIt() async throws {
        let settings = AppSettings()
        settings.suspendPersistence()
        let first = try fakeInterpreter()
        let second = try fakeInterpreter()
        settings.customPythonPath = first
        let driver = MfluxDriverController(settings: settings)

        #expect(await driver.ensureRunning())
        #expect(driver.interpreter == first)

        settings.customPythonPath = second
        #expect(await driver.ensureRunning())
        #expect(driver.interpreter == second)
        // The first driver's exit is reported after the restart, and must not
        // tear down the second.
        try await Task.sleep(for: .milliseconds(300))
        #expect(driver.isRunning)

        // A Custom Python that vanished leaves the driver unavailable (jobs fall
        // back to the one-shot CLI, which reports the problem), and stops the old one.
        settings.customPythonPath = "/nonexistent/venv/bin/python"
        #expect(await driver.ensureRunning() == false)
        #expect(!driver.isRunning)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Expected: `value of type 'MfluxDriverController' has no member 'interpreter'`.

- [ ] **Step 3: Implement**

Header doc, replacing the paragraph that begins "The driver runs with the mflux tool venv's Python":

```swift
/// The driver runs on the toolchain's mflux interpreter (the bundled runtime,
/// or the DMG's Custom Python) and speaks NDJSON over stdio:
```

State, after `private var process: Process?`:

```swift
    /// The interpreter the running (or last attempted) driver started on. A
    /// different one in the toolchain means the Custom Python changed.
    private(set) var interpreter: String?

    var isRunning: Bool {
        process?.isRunning == true
    }
```

`isRunning` is a computed instance property; place it next to `isLoaded` to satisfy `type_contents_order`.

`ensureRunning()`:

```swift
    func ensureRunning() async -> Bool {
        // A changed Custom Python retires the current driver, and re-arms one
        // that failed on the old interpreter: the next job must run on the new one.
        let wanted = try? settings?.toolchain.mfluxInterpreter()
        if wanted != interpreter {
            retire()
            availability = .unknown
        }
        if case .unavailable = availability {
            return false
        }
        if isRunning {
            return true
        }
        return await start()
    }
```

In `start()`, replace the `venvPython` guard with:

```swift
        let python: String
        do {
            python = try settings.toolchain.mfluxInterpreter()
        } catch {
            interpreter = nil
            availability = .unavailable(error.localizedDescription)
            return false
        }
        interpreter = python
```

Change the termination handler so a late exit can't clear a newer process:

```swift
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.processDied(proc) }
        }
```

`processDied` becomes `private func processDied(_ proc: Process)`, starting with:

```swift
        // A retired driver's exit arrives after its replacement started.
        guard proc === process else { return }
```

Add below `resetAvailability()`:

```swift
    /// Stops the driver now, for a restart on another interpreter. Its state is
    /// cleared here; the termination callback that follows is ignored because
    /// `process` no longer points at it.
    private func retire() {
        guard let proc = process else { return }
        processDied(proc)
        proc.terminate()
    }
```

`processDied` must still be reached for a driver's own crash. Those calls come only from the termination handler, which now passes the process.

- [ ] **Step 4: Run the test and the full suite**

Expected: `changingTheCustomPythonRestartsTheDriverOnIt` passes, and every existing test passes.

- [ ] **Step 5: Lint and commit**

```bash
git add Runner/MfluxDriverController.swift Tests/MfluxDriverControllerTests.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: warm driver runs on the toolchain and restarts when the Custom Python changes"
```

---

### Task 6: Local Gemma, captions and the Scenario Generator run on the bundled Python

**Files:**
- Modify:
  - `Utilities/GemmaChatRunner.swift` (`:3-16` error, `:24-49` uv/requirements, `:150-232` `run` and `spawn`)
  - `Utilities/ScenarioGenerator.swift` (`:52-70` error, `:347-386` `startDriver`, `:455-466` one-shot)
  - `Utilities/IdeogramCaptionGenerator.swift` (`:3-27` error, `:118-126`)
  - `Views/Settings/PromptLLMSettingsView.swift:52-86`
  - `Runtime/requirements.in` (the pin rationale moves here)
- Create: `Tests/GemmaChatRunnerTests.swift`

**Interfaces:**
- **Consumes:**
  - `Toolchain.command(_:)` and `bundledInterpreter()` (Task 1)
  - `AppSettings.toolchain` (Task 3)
  - `RuntimeManifest.bundled` (Task 1)
- **Produces:** `GemmaChatRunner.run(modelPath:prompt:maxTokens:temp:environment:toolchain:)`. It throws `ToolchainError` when the runtime is missing.

- [ ] **Step 1: Write the failing tests**

`Tests/GemmaChatRunnerTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Local Gemma runs `mlx_lm.generate` (retrying VLM-only models through
/// `mlx_vlm.generate`) on the bundled interpreter via run_tool.py.
struct GemmaChatRunnerTests {
    @Test func localGemmaRunsMlxLmOnTheBundledInterpreter() async throws {
        // $1 is run_tool.py, $2 the tool name.
        let runtime = try FakeRuntime(python: "#!/bin/sh\necho \"tool=$2 model=$4\"\n")
        let (output, exitCode) = try await GemmaChatRunner.run(
            modelPath: "org/model", prompt: "hi", maxTokens: 8, temp: 0.1,
            environment: [:], toolchain: runtime.toolchain()
        )
        #expect(exitCode == 0)
        #expect(output.contains("tool=mlx_lm.generate model=org/model"))
    }

    @Test func vlmOnlyModelsRetryThroughMlxVlm() async throws {
        let runtime = try FakeRuntime(python: """
        #!/bin/sh
        if [ "$2" = "mlx_lm.generate" ]; then echo "Model type gemma4_unified not supported."; exit 1; fi
        echo "tool=$2"
        """)
        let (output, exitCode) = try await GemmaChatRunner.run(
            modelPath: "org/model", prompt: "hi", maxTokens: 8, temp: 0.1,
            environment: [:], toolchain: runtime.toolchain()
        )
        #expect(exitCode == 0)
        #expect(output.contains("tool=mlx_vlm.generate"))
    }

    @Test func missingRuntimeIsReported() async throws {
        let runtime = try FakeRuntime(python: nil)
        await #expect(throws: ToolchainError.runtimeMissing) {
            try await GemmaChatRunner.run(
                modelPath: "org/model", prompt: "hi", maxTokens: 8, temp: 0.1,
                environment: [:], toolchain: runtime.toolchain()
            )
        }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Expected: `extra argument 'toolchain' in call`.

- [ ] **Step 3: Move the pin rationale into `Runtime/requirements.in`**

Replace its mlx-vlm and transformers comment lines with the full reasoning from `GemmaChatRunner`'s doc comments (which are deleted next), so the pins keep their explanation:

```text
# Local Gemma for the Scenario Generator and caption tools.
mlx-lm>=0.31.3
# Pinned, not a floor. mlx-vlm 0.6.4 regressed gemma4_unified: its
# Gemma4UnifiedProcessor always passes video_processor= to transformers'
# ProcessorMixin, which (with no torchvision installed) rejects it, and mlx-vlm
# swallows that and reports a misleading "Could not import module
# 'Gemma4UnifiedProcessor'". Bump once mlx-vlm fixes it.
mlx-vlm==0.6.3
# One pin both sides accept: mflux needs >=5.5. transformers 5.13 rejects
# mlx-lm's AutoTokenizer.register("NewlineTokenizer", …) string argument, so
# every generate dies with "'str' object has no attribute '__module__'".
transformers>=5.5,<5.13
```

This changes `Runtime/**`, so CI rebuilds the runtime once (cache key). The lock is unchanged; don't re-lock.

- [ ] **Step 4: Rewrite `GemmaChatRunner` on the toolchain**

- **Delete:**
  - the `uvNotFound` case and its description
  - `uvPath`
  - `mlxLMRequirement`, `mlxVLMRequirement`, `transformersRequirement` and their doc comments
- **Type doc:** "via `uv run mlx_lm.generate`" becomes "on the bundled Python (`mlx_lm.generate` through run_tool.py)", and "the uv subprocess runner" becomes "the subprocess runner".
- **`stripToolPreamble`:** keep it and its tests. Its doc says uv printed those lines; add one sentence: "Kept for remote and older outputs; the bundled runtime prints none."

New `run` and `spawn`:

```swift
    /// Runs `mlx_lm.generate` on the bundled Python and returns the combined
    /// stdout+stderr plus the exit code (callers log the output before acting on
    /// a nonzero exit, so failures still surface the model's raw text).
    /// Cancelling the enclosing Task terminates the subprocess.
    ///
    /// `environment` should come from `AppSettings.buildEnvironment()` so the
    /// user's HF_HOME / HF_TOKEN / HF_HUB_OFFLINE settings apply to mlx_lm's
    /// model resolution exactly as they do to mflux.
    static func run(
        modelPath: String,
        prompt: String,
        maxTokens: Int,
        temp: Double,
        environment: [String: String],
        toolchain: Toolchain
    ) async throws -> (output: String, exitCode: Int32) {
        let mlxLM = try toolchain.command(.mlxLmGenerate)

        // (keep the existing modelNotFound check here, unchanged)

        func arguments(_ command: ToolCommand, extra: [String]) -> [String] {
            command.arguments + [
                "--model", expandedModel,
                "--prompt", prompt,
                "--max-tokens", "\(maxTokens)",
            ] + extra
        }

        let first = try await spawn(
            mlxLM, arguments: arguments(mlxLM, extra: ["--temp", "\(temp)"]), environment: environment
        )
        // (keep the existing VLM-retry comment)
        if first.exitCode != 0, first.output.contains("Model type"), first.output.contains("not supported") {
            let mlxVLM = try toolchain.command(.mlxVlmGenerate)
            return try await spawn(
                mlxVLM,
                arguments: arguments(mlxVLM, extra: ["--temperature", "\(temp)", "--no-verbose"]),
                environment: environment
            )
        }
        return first
    }

    private static func spawn(
        _ command: ToolCommand,
        arguments: [String],
        environment: [String: String]
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = arguments
        process.environment = environment
        let output = try await runCollectingOutput(process)
        return (output, process.terminationStatus)
    }
```

- [ ] **Step 5: Update the two callers and the Scenario driver**

**`IdeogramCaptionGenerator`:**
- Delete the `uvNotFound` case and its description.
- Replace the `do { … } catch GemmaChatRunnerError.uvNotFound { … }` block with a direct call:

```swift
            let exitCode: Int32
            (rawOutput, exitCode) = try await GemmaChatRunner.run(
                modelPath: modelPath, prompt: fullPrompt, maxTokens: 8192, temp: 0.3,
                environment: settings.buildEnvironment(), toolchain: settings.toolchain
            )
```

**`ScenarioGenerator`:**
- Delete the `uvNotFound` case and its description.
- In `generateOneShot`, replace the `do/catch` the same way, keeping the existing `temp: settings.llmTemperature` argument and adding `toolchain: settings.toolchain`.
- Change line 204's comment "including uv's install noise" to "including any tool preamble".

`startDriver`:

```swift
    private func startDriver(settings: AppSettings) async -> Bool {
        guard let python = try? settings.toolchain.bundledInterpreter(),
              let script = Bundle.main.url(forResource: "scenario_llm_driver", withExtension: "py") else {
            driverUnavailable = true
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script.path]
        proc.environment = settings.buildEnvironment()
```

The rest is unchanged, except the handshake comment "first uv resolve can be slow" becomes "first import (mlx, transformers) can be slow".

The one-shot fallback then reports a missing runtime through `ToolchainError`'s message.

**`PromptLLMSettingsView.localFields`:**
- Delete `uvPath` and `uvFound`.
- The help text becomes `"HF repo ID or local path for the Gemma model."`.
- The status row becomes:

```swift
        HStack(spacing: 6) {
            let manifest = RuntimeManifest.bundled
            Image(systemName: manifest != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(manifest != nil ? Color.green : Color.red)
            Text(manifest.map {
                "Runs on the bundled Python (mlx-lm \($0.version(of: "mlx-lm") ?? "?"), "
                    + "mlx-vlm \($0.version(of: "mlx-vlm") ?? "?"))"
            } ?? ToolchainError.runtimeMissing.localizedDescription)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.vertical, 2)
```

- [ ] **Step 6: Run the tests and grep**

```bash
# full test command
grep -rn "uvNotFound\|uvPath\|Requirement\b\|uv run\|uv tool install" --include='*.swift' App Models Runner Stores Utilities Views
```

Expected:
- **Tests:** all pass (3 new).
- **grep:** matches only in `Utilities/UvInstaller.swift`, `Utilities/MfluxInstaller.swift` and the ContentView/SettingsView install flows, which Task 7 deletes.

- [ ] **Step 7: Lint and commit**

```bash
git add Utilities Views/Settings/PromptLLMSettingsView.swift Runtime/requirements.in Tests/GemmaChatRunnerTests.swift \
  "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: local Gemma, captions and the Scenario Generator run on the bundled Python"
```

---

### Task 7: Python settings and banner; delete the installers

**Files:**
- Create: `Views/Settings/PythonSettingsSection.swift`, `Views/Shared/ToolchainBanner.swift`
- Delete: `Utilities/UvInstaller.swift`, `Utilities/MfluxInstaller.swift`, `Utilities/BinaryDetector.swift`, `Tests/MfluxInstallerTests.swift`
- Modify:
  - `App/ContentView.swift`:
    - `:8-18` (the `MfluxAutoInstall` enum)
    - `:91` (its state)
    - `:346` (its `.task`)
    - `:498` (the banner slot)
    - `:1059-1131` (`mfluxInstallBanner`)
    - `:1412-1456` (three install functions)
  - `Views/Settings/SettingsView.swift`:
    - `:8` (`SetupPhase`), `:34` (its state)
    - `:87-94` (the generation-tab banner)
    - `:215-254` (`mfluxSetupBanner`)
    - `:287-302` (the "mflux Binary" section)
    - `:479-491` (`installMflux`), `:504-512` (`browseBinaryDir`)
  - `Stores/AppSettings.swift`: the `mfluxBinaryDir` property, its `init` line, its `saveNow` argument, `mfluxBinaryPath()`, and the `Stored.mfluxBinaryDir` doc

**Interfaces:**
- **Consumes:**
  - `AppSettings.toolchain` and `customPythonPath`
  - `MfluxProbes.mfluxVersion(python:)`
  - `RuntimeManifest.bundled`, `ToolchainError`, `BuildFlavor`
- **Produces:** the views `PythonSettingsSection` and `ToolchainBanner`.

- [ ] **Step 1: Delete the installers and their UI**

```bash
git rm Utilities/UvInstaller.swift Utilities/MfluxInstaller.swift Utilities/BinaryDetector.swift Tests/MfluxInstallerTests.swift
```

**`App/ContentView.swift`:** delete
- the `MfluxAutoInstall` enum
- `@State private var mfluxAutoInstall`
- the `.task { await checkAndAutoInstallMflux() }` line
- the `mfluxInstallBanner` property
- `checkAndAutoInstallMflux()`, `enforceMfluxVersionFloor()`, `runMfluxInstall()`

In the top `safeAreaInset`, replace `mfluxInstallBanner` with `ToolchainBanner()`.

**`Views/Settings/SettingsView.swift`:** delete
- `SetupPhase` and `mfluxSetupPhase`
- the `mfluxMissing` constant and its `if mfluxMissing { … }` block in `generationTab`; the `VStack` keeps only the `Form`
- `mfluxSetupBanner`, `installMflux()`, `browseBinaryDir()`

In `advancedTab`, replace the whole `Section("mflux Binary") { … }` with `PythonSettingsSection()`.

**`Stores/AppSettings.swift`:**
- Delete the `mfluxBinaryDir` property, its `init` assignment, and `mfluxBinaryPath()`.
- In `saveNow`, delete the `mfluxBinaryDir: mfluxBinaryDir,` argument. The key then drops out of `settings.json` on the next save.
- Keep `Stored.mfluxBinaryDir`, documented:

```swift
        /// Read-only legacy key: migrated into `customPython` at launch
        /// (``ToolchainMigration``) and never written again.
        var mfluxBinaryDir: String?
```

- [ ] **Step 2: Write `PythonSettingsSection`**

`Views/Settings/PythonSettingsSection.swift`:

```swift
import AppKit
import SwiftUI

/// Settings → Advanced → Python (spec §3): the bundled runtime the app runs
/// on, and, in the DMG build, the Custom Python override for mflux.
struct PythonSettingsSection: View {
    private enum CustomStatus: Equatable {
        case unchecked
        case checking
        case found(String)
        case noMflux
    }

    @Environment(AppSettings.self) private var settings
    @State private var customStatus = CustomStatus.unchecked

    var body: some View {
        Section("Python") {
            bundledRow
            if !BuildFlavor.isAppStore {
                customPythonRow
            }
        }
        .task(id: settings.toolchain.customPython) { await checkCustomPython() }
    }

    private var bundledRow: some View {
        HStack(spacing: 6) {
            if let manifest = RuntimeManifest.bundled {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Bundled Python \(manifest.python) · mflux \(manifest.version(of: "mflux") ?? "unknown")")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(ToolchainError.runtimeMissing.localizedDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var customPythonRow: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 4) {
            Text("Custom Python (advanced)")
            HStack {
                TextField("Bundled (default)", text: $s.customPythonPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { browse() }
                if !s.customPythonPath.isEmpty {
                    Button("Use Bundled") { s.customPythonPath = "" }
                }
            }
            Text(
                "Runs mflux and the warm model driver with another interpreter, such as a dev "
                    + "checkout's .venv/bin/python. Captions and the Scenario Generator always use the bundled Python."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            customStatusRow
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var customStatusRow: some View {
        if case let .customPythonMissing(path)? = settings.toolchain.problem {
            statusLine(ok: false, ToolchainError.customPythonMissing(path).localizedDescription)
        } else {
            switch customStatus {
            case .unchecked:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
            case let .found(version):
                statusLine(ok: true, "mflux \(version)")
            case .noMflux:
                statusLine(ok: false, "No mflux in this Python. Install it there, or use the bundled one.")
            }
        }
    }

    private func statusLine(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
        }
    }

    private func checkCustomPython() async {
        let toolchain = settings.toolchain
        let python = toolchain.customPython
        guard !python.isEmpty, (try? toolchain.mfluxInterpreter()) == python else {
            customStatus = .unchecked
            return
        }
        customStatus = .checking
        let version = await Task.detached(priority: .utility) { MfluxProbes.mfluxVersion(python: python) }.value
        customStatus = version.map(CustomStatus.found) ?? .noMflux
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Python Interpreter"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true // .venv is hidden
        panel.treatsFilePackagesAsDirectories = true
        // A venv's bin/python is a symlink to its base interpreter; resolving
        // it would drop the venv, and the mflux installed in it.
        panel.resolvesAliases = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.customPythonPath = url.path
        }
    }
}
```

- [ ] **Step 3: Write `ToolchainBanner`**

`Views/Shared/ToolchainBanner.swift`:

```swift
import SwiftUI

/// Shown under the top bar when Python can't run: a build without its runtime,
/// or a Custom Python that no longer exists. Generation fails until it's fixed.
struct ToolchainBanner: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let problem = settings.toolchain.problem {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(problem.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if case .customPythonMissing = problem {
                    Button("Open Settings") {
                        openSettings()
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .openSettingsAdvancedTab, object: nil)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
```

- [ ] **Step 4: Build, run the tests, grep**

```bash
xcodegen generate && git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
# full test command
grep -rn "BinaryDetector\|MfluxInstaller\|UvInstaller\|mfluxBinaryDir\|mfluxBinaryPath\|uvNotFound" \
  --include='*.swift' App Models Runner Stores Utilities Views Tests
```

Expected:
- **Tests:** all pass, minus the deleted `MfluxInstallerTests`.
- **grep:** matches only `Stores/AppSettings.swift` (`Stored.mfluxBinaryDir` and the migration line in `init`) and the two test fixtures with a legacy `"mfluxBinaryDir"` key (`ProfileStoredMigrationTests`, `ProfileBootstrapTests`). Those fixtures stay: old files still carry the key.

Also build the App Store flavor, so the `BuildFlavor` branches compile there:

```bash
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore -derivedDataPath "$DD" build BUNDLE_PYTHON_RUNTIME=NO CODE_SIGNING_ALLOWED=NO -quiet
```

Expected: `** BUILD SUCCEEDED **`, or no output with `-quiet` and exit 0.

- [ ] **Step 5: Lint and commit**

```bash
git add -A App Views Stores Utilities Tests "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: Python settings and banner; delete the uv and mflux installers"
```

---

### Task 8: `--runtime-self-test`, Help ▸ Acknowledgements, no update checks in the App Store build

**Files:**
- Create: `Utilities/RuntimeSelfTest.swift`, `App/AppMain.swift`, `Tests/RuntimeSelfTestTests.swift`
- Modify:
  - `App/MLXBitsImageStudioApp.swift:3` (drop `@main`), `:55-58` (commands)
  - `Utilities/UpdateChecker.swift` (`:46-70`)
  - `Views/Shared/AboutView.swift:35-38`
  - `Tests/UpdateCheckerTests.swift`

**Interfaces:**
- **Consumes:** `Toolchain`, `PythonTool`, `BuildFlavor` (Task 1).
- **Produces:**
  - `RuntimeSelfTest.flag`
  - `RuntimeSelfTest.run(toolchain:environment:report:) -> Int32`
  - `UpdateChecker(isEnabled:)` and `UpdateChecker.isEnabled`

- [ ] **Step 1: Write the failing tests**

`Tests/RuntimeSelfTestTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// `--runtime-self-test` imports the heavy packages and runs every tool's
/// `--help` on the bundled interpreter, and fails if any of them fails.
struct RuntimeSelfTestTests {
    private func run(_ runtime: FakeRuntime) -> (status: Int32, lines: [String]) {
        var lines: [String] = []
        let status = RuntimeSelfTest.run(toolchain: runtime.toolchain(), environment: [:]) { lines.append($0) }
        return (status, lines)
    }

    @Test func everyToolAndTheImportsPass() throws {
        let (status, lines) = try run(FakeRuntime())
        #expect(status == 0)
        #expect(lines.filter { $0.hasPrefix("ok ") }.count == PythonTool.allCases.count + 1)
        #expect(lines.last == "Runtime self-test passed")
    }

    @Test func oneFailingToolFailsTheRunAndSaysWhy() throws {
        // $1 is run_tool.py (or -c), $2 the tool name (or the import line).
        let runtime = try FakeRuntime(python: """
        #!/bin/sh
        if [ "$2" = "mflux-save" ]; then echo "boom" >&2; exit 3; fi
        exit 0
        """)
        let (status, lines) = run(runtime)
        #expect(status == 1)
        #expect(lines.contains { $0.hasPrefix("FAIL mflux-save") && $0.contains("exit 3") && $0.contains("boom") })
        #expect(lines.last == "Runtime self-test: 1 failed")
    }

    @Test func missingRuntimeFails() throws {
        let (status, lines) = try run(FakeRuntime(python: nil))
        #expect(status == 1)
        #expect(lines.first?.hasPrefix("FAIL runtime") == true)
    }
}
```

Append to `Tests/UpdateCheckerTests.swift`:

```swift
    /// App Store apps update through the store (spec §3), so the App Store
    /// build never asks GitHub.
    @Test func disabledCheckerNeverChecks() async {
        let checker = UpdateChecker(isEnabled: false)
        await checker.check()
        #expect(checker.latestVersion == nil)
        #expect(checker.lastError == nil)
        #expect(!checker.isUpdateAvailable)
    }
```

- [ ] **Step 2: Run them to see them fail**

Expected: `cannot find 'RuntimeSelfTest' in scope`, and `extra argument 'isEnabled' in call`.

- [ ] **Step 3: Implement the self-test**

`Utilities/RuntimeSelfTest.swift`:

```swift
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
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-self-test-\(UUID().uuidString).log")
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
```

- [ ] **Step 4: Add the entry point**

`App/AppMain.swift`:

```swift
import Foundation

/// The process entry point. `--runtime-self-test` runs before any app state
/// exists (no settings, profiles or windows), so a release workflow can run it
/// on a fresh runner and a developer can run it beside their real data.
@main
enum AppMain {
    static func main() {
        if CommandLine.arguments.contains(RuntimeSelfTest.flag) {
            let toolchain = Toolchain(resourcesURL: Bundle.main.resourceURL, customPython: "")
            var environment = Toolchain.environment(
                base: ProcessInfo.processInfo.environment, cachesURL: Toolchain.cachesURL
            )
            environment["HF_HUB_OFFLINE"] = "1" // --help never needs the network
            exit(RuntimeSelfTest.run(toolchain: toolchain, environment: environment) { print($0) })
        }
        MLXBitsImageStudioApp.main()
    }
}
```

Remove `@main` from `struct MLXBitsImageStudioApp: App`.

In its `.commands { … }`, after `AboutCommands()`, add:

```swift
            CommandGroup(after: .help) {
                // The bundled runtime's third-party notices (spec §2).
                Button("Acknowledgements") {
                    if let url = settings.toolchain.acknowledgementsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(settings.toolchain.acknowledgementsURL == nil)
            }
```

- [ ] **Step 5: Turn update checks off in the App Store build**

In `UpdateChecker`, add an instance property above `init`:

```swift
    /// False in the App Store build: App Store apps update through the store
    /// (spec §3), so no GitHub check, badge or About status.
    let isEnabled: Bool
```

Change `init()` to `init(isEnabled: Bool = !BuildFlavor.isAppStore)`, with `self.isEnabled = isEnabled` added to its body. In `check()`, change the first guard to `guard isEnabled, !isChecking else { return }`.

In `AboutView`, wrap the release-only status:

```swift
            #if !DEBUG
                if updates.isEnabled {
                    Divider()
                    updateStatus
                }
            #endif
```

`ContentView`'s toolbar badge reads `isUpdateAvailable`, which stays false when checks never run, so it needs no change.

- [ ] **Step 6: Run the tests and try the flag**

```bash
xcodegen generate && git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
# full test command (BUNDLE_PYTHON_RUNTIME=NO)
"$DD/Build/Products/Debug/MLXBits Image Studio.app/Contents/MacOS/MLXBits Image Studio" --runtime-self-test; echo "exit $?"
```

Expected:
- **Tests:** all pass (4 new).
- **The flag:** the test build has no runtime, so it prints `FAIL runtime: Python runtime missing from this build. Reinstall the app.` and `exit 1`, opens no window, and touches no settings. Task 9 runs it on a build with the runtime.

- [ ] **Step 7: Lint and commit**

```bash
git add App Utilities Views/Shared/AboutView.swift Tests "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: --runtime-self-test, Help ▸ Acknowledgements, no update checks in the App Store build"
```

---

### Task 9: Bundle the runtime in the DMG; release workflow; docs

**Files:**
- Modify:
  - `project.yml:117-160`
  - `.github/workflows/release.yml`
  - `README.md`, `AGENTS.md`
  - `docs/specs/2026-10-03-app-store-build-design.md` (§1, §2, §3, §7)

**Interfaces:**
- **Consumes:** `--runtime-self-test` (Task 8).

- [ ] **Step 1: Turn the runtime on for every configuration, arm64 only**

`project.yml`, app target `settings.base`. Replace the `BUNDLE_PYTHON_RUNTIME` comment and the two runtime lines with:

```yaml
        # Read by scripts/embed-python-runtime.sh. Every configuration bundles
        # the runtime; CI's test and compile-only jobs pass NO to stay fast.
        BUNDLE_PYTHON_RUNTIME: YES
        PYTHON_RUNTIME_SANDBOXED: NO
        # The bundled runtime is arm64 only, and MLX needs Apple silicon.
        ARCHS: arm64
```

In both App Store configurations, delete `ARCHS: arm64` and its comment, and `BUNDLE_PYTHON_RUNTIME: YES`. They inherit both. They keep `PYTHON_RUNTIME_SANDBOXED: YES`.

```bash
xcodegen generate && git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
for c in Debug Release Debug-AppStore Release-AppStore; do
  xcodebuild -project "MLXBits Image Studio.xcodeproj" -target "MLXBits Image Studio" -configuration "$c" \
    -showBuildSettings 2>/dev/null | grep -E "^\s+(ARCHS|BUNDLE_PYTHON_RUNTIME|PYTHON_RUNTIME_SANDBOXED) =" | tr -s ' ' | tr '\n' ' '
  echo "← $c"
done
```

Expected:
- every configuration shows `ARCHS = arm64` and `BUNDLE_PYTHON_RUNTIME = YES`
- `PYTHON_RUNTIME_SANDBOXED` is `YES` only for the two App Store configurations

- [ ] **Step 2: Build the DMG flavor with the runtime and self-test it**

```bash
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio" -configuration Debug \
  -derivedDataPath "$DD" build -quiet
APP="$DD/Build/Products/Debug/MLXBits Image Studio.app"
ls "$APP/Contents/Resources/python/bin"; lipo -archs "$APP/Contents/MacOS/MLXBits Image Studio"
"$APP/Contents/MacOS/MLXBits Image Studio" --runtime-self-test; echo "exit $?"
```

Expected:
- `python3.14` is listed, and `lipo` prints `arm64`.
- 12 `ok` lines (`imports` plus the 11 tools), then `Runtime self-test passed` and `exit 0`.
- The first build runs `scripts/build-python-runtime.sh`, or reuses `build/python-runtime/` when its cache key matches.

- [ ] **Step 3: Release workflow**

`.github/workflows/release.yml`:

1. **Test (Debug):** add `BUNDLE_PYTHON_RUNTIME=NO \` after `CODE_SIGNING_ALLOWED=NO`, matching `ci.yml`'s test job.

2. **Before "Archive (Release, manual Developer ID signing)",** insert the same runtime steps `appstore.yml` uses:

   ```yaml
      - uses: astral-sh/setup-uv@v10.2.0  # setup-uv publishes no floating major tag

      # Same key as runtime.yml and appstore.yml, so a runtime that already passed there is reused.
      - name: Restore Python runtime
        uses: actions/cache@v6
        with:
          path: build/python-runtime
          key: python-runtime-${{ hashFiles('Runtime/**', 'scripts/build-python-runtime.sh', 'scripts/runtime_tools.py', 'Resources/run_tool.py') }}

      - name: Build Python runtime (license guard + smoke test)
        run: scripts/build-python-runtime.sh
   ```

3. **After "Export archive with Developer ID",** add:

   ```yaml
      # The runtime inside the exported app is signed with Developer ID and the
      # hardened runtime. Prove it still imports and runs every tool before the
      # DMG is built and notarized (spec §2).
      - name: Self-test the signed runtime
        run: |
          APP="build/export/$APP_NAME.app"
          "$APP/Contents/MacOS/$APP_NAME" --runtime-self-test
   ```

```bash
build/python-runtime/python/bin/python3.14 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' .github/workflows/release.yml && echo YAML ok
```

Expected: `YAML ok`.

`appstore.yml` gets no self-test. An app signed for App Store distribution is refused at launch outside the store, because its provisioning profile doesn't authorize the runner. Its existing static checks stay, and the local `Debug-AppStore` self-test (Task 10) and TestFlight cover the sandboxed runtime. Record this as a ruling in the ledger.

- [ ] **Step 4: Docs**

**`README.md`:**
- **Requirements:** replace the "mflux and uv are installed automatically…" paragraph with:

  > Everything the app runs (Python, mflux, and the local Gemma tools) ships inside the app (about 1.6 GB installed), so there is nothing to install on first launch and nothing is downloaded except model weights.
  >
  > **Upgrading from 0.15 or earlier:** the app no longer uses the mflux that earlier versions installed with uv. To reclaim its space, run `uv tool uninstall mflux`. If you pointed the app at your own mflux checkout, 0.16.0 keeps using it as **Settings → Advanced → Python → Custom Python**.

- **Ideogram 4 caption editor:** "(`mlx_lm` runs locally via `uv`; no API key)" becomes "(`mlx_lm` runs locally on the bundled Python; no API key)".
- **"mflux support" note:** replace its second sentence on with:

  > The bundled mflux carries every family. With a Custom Python, any model whose CLI is missing from that install is disabled in the model picker with a note saying so, rather than failing when you hit Generate.

- **Building from source:** `brew install xcodegen swiftlint swiftformat uv`. Add: "The first build also builds the bundled Python runtime into `build/python-runtime/`. That takes several minutes, and later builds reuse it."
- **"Python runtime and the App Store flavor":** first paragraph:

  > Both flavors bundle their own Python with mflux and every dependency, pinned in `Runtime/`.

  Add a paragraph:

  > **Developing against an mflux checkout:** set **Settings → Advanced → Python → Custom Python** (DMG build only) to the checkout's `.venv/bin/python`. mflux and the warm driver then run on it; everything else stays on the bundled runtime. To check a built app's runtime: `"<app>/Contents/MacOS/MLXBits Image Studio" --runtime-self-test`.

**`AGENTS.md`:**
- **Repo map, `Utilities/`:** "installers" becomes "the Python toolchain".
- **Recipe step 10:** replace `Utilities/BinaryDetector.swift` with "`Utilities/PythonTool.swift` (a case for the new CLI) plus `Runtime/tools.txt` (same name), and the catalog's `generateTool`".
- **After "Architecture in one paragraph",** add:

  > Every Python tool runs through `Utilities/Toolchain.swift`: `<interpreter> Resources/run_tool.py <tool> <args>`, on the bundled runtime or the DMG's Custom Python (mflux tools and the warm driver only). Add new tools to `PythonTool` and `Runtime/tools.txt` together; a test keeps them equal.

**Spec, `docs/specs/2026-10-03-app-store-build-design.md`:**
- **§1:** replace the "Open item: app name collision" block with:

  > **App name collision, resolved by the first TestFlight install (2026-10-04).** The App Store installer renames rather than refusing or replacing: next to a DMG copy, the TestFlight build installed as `MLXBits Image Studio 2.app`, and the DMG copy kept its name, so dragging a new DMG over it still replaces only the DMG copy. No rename needed.

- **§1, runtime build step paragraph:** "default `YES`" stays. Add: "Both flavors are arm64 only."
- **§2, release workflows bullet list:** add:

  > `appstore.yml` can't run `--runtime-self-test`: an app signed for App Store distribution won't launch outside the store. It keeps its static checks (signature, python entitlements, arm64); the sandboxed runtime is exercised by the `Debug-AppStore` self-test and TestFlight.

- **§3, capability probes:** "Results are cached per interpreter path and mflux version" becomes "Results are cached per interpreter path for the launch; choosing another Custom Python asks again".
- **§3, tool names:** add "Tool names are the `PythonTool` enum, kept equal to `Runtime/tools.txt` by a test."
- **§7, manual checklist item 10:** add " Done 2026-10-04: installs side by side (see §1)."

- [ ] **Step 5: Lint, run the tests, commit**

```bash
# lint gate; full test command
git add project.yml "MLXBits Image Studio.xcodeproj" .github/workflows/release.yml README.md AGENTS.md docs/specs/2026-10-03-app-store-build-design.md
git commit -m "build: bundle the Python runtime in the DMG; release workflow self-tests it"
```

---

### Task 10: Verify, merge, release v0.16.0

**Files:** none changed, unless a check fails. A failure gets its own fix commit with a test, and a ruling in the ledger.

- [ ] **Step 1: Back up the owner's real data** (spec §7, data safety)

```bash
B="$HOME/Backups/MLXBits Image Studio pre-0.16.0"
mkdir -p "$B"
ditto "$HOME/Library/Application Support/MLXBits Image Studio" "$B/Application Support"
defaults export com.mlxbits.image-studio "$B/defaults.plist"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("mfluxBinaryDir =", s.get("mfluxBinaryDir"))' \
  "$HOME/Library/Application Support/MLXBits Image Studio/settings.json"
```

Expected: the backup exists, and the current `mfluxBinaryDir` is printed. That value predicts the migration: a dev checkout becomes the Custom Python, and a uv-managed path or none means the bundled runtime.

- [ ] **Step 2: Signed Release DMG build, self-tested locally**

Codesign may ask once for keychain access; the owner clicks Always Allow. The Team ID comes from the gitignored `Config/Local.xcconfig`; never write it into a tracked file.

```bash
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig)
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio" -configuration Release \
  -derivedDataPath "$DD" -archivePath "$DD/Release.xcarchive" archive -quiet \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application"
APP="$DD/Release.xcarchive/Products/Applications/MLXBits Image Studio.app"
codesign --verify --deep --strict "$APP" && echo "signature ok"
codesign -dv "$APP/Contents/Resources/python/bin/python3.14" 2>&1 | grep -E "^flags"
"$APP/Contents/MacOS/MLXBits Image Studio" --runtime-self-test; echo "exit $?"
```

Expected:
- `signature ok`
- `flags=0x10000(runtime)`
- `Runtime self-test passed` and `exit 0`

If torch or another import fails under the hardened runtime, apply the spec's risk-table fallback: the narrowest hardened-runtime exception the error names, on `python3.14` only. That gets its own commit.

- [ ] **Step 3: Sandboxed self-test** (App Store flavor, Apple Development signing from `Config/Local.xcconfig`)

```bash
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore -derivedDataPath "$DD" build -quiet
"$DD/Build/Products/Debug-AppStore/MLXBits Image Studio.app/Contents/MacOS/MLXBits Image Studio" --runtime-self-test; echo "exit $?"
```

Expected: `Runtime self-test passed` and `exit 0`. Here the tools run as children of a sandboxed process.

- [ ] **Step 4: Owner's manual checks on the DMG Debug build**

The owner quits their running copy first. Both use the same bundle ID and data.

```bash
open "$DD/Build/Products/Debug/MLXBits Image Studio.app"
```

1. **Migration.**
   - Settings → Advanced → Python shows "Bundled Python 3.14.7 · mflux 0.21.0".
   - If the old setting was a dev checkout, Custom Python shows its interpreter with a green "mflux <version>".
   - `settings.json` now has `customPython` and no `mfluxBinaryDir`.
2. **Browse….** Pick `~/Git/mflux/.venv/bin/python`. The field keeps the `.venv/bin/python` path; it must not be resolved to the base interpreter.
3. **Custom Python.** One Flux generation with the warm driver: its log shows mflux running from the checkout. Then **Use Bundled**, and generate again with the model warm: the driver restarts, and the job runs on the bundled runtime.
4. **Each family on the bundled runtime** (Flux2, Krea 2, Ideogram 4, Z-Image, SeedVR2 upscale), once through the warm driver and once with "Keep model warm" off (the one-shot CLI).
5. **Scenario Generator** with local Gemma, and an **Ideogram 4 caption** from a plain description.
6. **Settings → Models:** one pre-quantized download (`hf`) and one `mflux-save` quantization.
7. **Broken Custom Python.** Set it to `/nonexistent/python`: the banner shows "Custom Python not found …", Open Settings lands on Advanced, and a generation fails with the same message. Then click Use Bundled.
8. **Help ▸ Acknowledgements** opens the notices file.
9. **Not launched:** no "Installing mflux…" banner and no uv anywhere.

- [ ] **Step 5: Final review, PR, merge**

Run the final whole-branch review (executing-plans), apply the fix pass, then:

Write the PR body to `$DD/pr-body.md`. It follows the repo's earlier PRs: what changed, why, how it was verified (Tasks 9–10 results), plus the rulings list. It carries no AI attribution.

```bash
git push -u origin feature/toolchain
gh pr create --title "Bundled Python toolchain (App Store milestone 4)" --body-file "$DD/pr-body.md"
gh pr checks --watch
```
 Once CI is green, squash-merge (`gh pr merge --squash --delete-branch`), then update the local `main`.

- [ ] **Step 6: Release v0.16.0. Owner's go-ahead required: this publishes a release.**

```bash
git tag v0.16.0 && git push origin v0.16.0
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
```

Expected:
- the run succeeds, including "Self-test the signed runtime" and notarization
- the release `v0.16.0` has a DMG of roughly 600 MB

Then put the upgrade note at the top of the release notes:

```bash
gh release view v0.16.0 --json body -q .body > "$DD/notes.md"
{ printf '%s\n\n' "**Upgrading:** the app now ships its own Python, mflux and Gemma tools; nothing is installed on first launch. The mflux that earlier versions installed with uv is no longer used: \`uv tool uninstall mflux\` frees its space. A custom mflux folder you had set carries over as Settings → Advanced → Python → Custom Python."; cat "$DD/notes.md"; } > "$DD/notes-new.md"
gh release edit v0.16.0 --notes-file "$DD/notes-new.md"
```

- [ ] **Step 7 (optional, owner's call): TestFlight build of `main`**

```bash
gh workflow run appstore.yml -f ref=main
```

This gives TestFlight the Scenario Generator and the bundled runtime in the sandbox. Models still live in the container until milestone 5 adds the models-folder grant.
