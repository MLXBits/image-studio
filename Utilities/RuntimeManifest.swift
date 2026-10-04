import Foundation

/// `python/runtime-manifest.json`, written by the runtime build: the Python
/// version and every package's version and license.
nonisolated struct RuntimeManifest: Decodable, Equatable, Sendable {
    struct Package: Decodable, Equatable, Sendable {
        let version: String
        let license: String?
    }

    /// This app's own runtime. Read once: a bundle doesn't change while it runs.
    static let bundled: Self? = load(from: Toolchain(
        resourcesURL: Bundle.main.resourceURL, customPython: ""
    ).runtimeURL)

    /// The manifest inside `runtimeURL`, or nil when it's absent or unreadable.
    static func load(from runtimeURL: URL?) -> Self? {
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
