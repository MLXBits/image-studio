import Foundation
import Observation

/// Compares the running app's version against the latest GitHub release and
/// exposes whether an update is available. Shared across the About window and
/// the toolbar update badge via the environment.
@MainActor
@Observable
final class UpdateChecker {
    /// `owner/repo` on GitHub whose releases are the source of truth for updates.
    static let repo = "MLXBits/image-studio"

    // MARK: - Version comparison

    /// Numeric, component-wise comparison of dot-separated versions, ignoring a
    /// leading "v" and any non-numeric suffix on each component (e.g. "1.2.0-rc").
    /// Returns true when `lhs` is a strictly newer release than `rhs`.
    static func compare(_ lhs: String, isNewerThan rhs: String) -> Bool {
        let a = components(lhs)
        let b = components(rhs)
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    // MARK: - State

    /// The bundled app version (CFBundleShortVersionString), e.g. "0.6.4".
    let currentVersion: String

    private(set) var latestVersion: String?
    private(set) var releaseURL: URL?
    private(set) var isChecking = false
    private(set) var lastError: String?

    /// True once the latest release is strictly newer than what's running.
    var isUpdateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.compare(latestVersion, isNewerThan: currentVersion)
    }

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Fetches the latest GitHub release and records its version + page URL.
    /// Concurrent calls are coalesced; failures surface via `lastError`.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            lastError = "Invalid update URL."
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "No response from GitHub."
                return
            }
            guard http.statusCode == 200 else {
                lastError = "GitHub returned status \(http.statusCode)."
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latestVersion = release.tagName
            releaseURL = URL(string: release.htmlURL)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// The subset of the GitHub `releases/latest` payload the checker reads.
private struct GitHubRelease: Decodable {
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    let tagName: String
    let htmlURL: String
}
