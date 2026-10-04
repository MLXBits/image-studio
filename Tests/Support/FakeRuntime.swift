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
