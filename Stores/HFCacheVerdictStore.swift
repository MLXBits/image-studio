import Foundation

/// mflux's answer to "is this model downloaded?", per Hugging Face cache folder
/// (#19).
///
/// ``FluxModelVariant/isCompleteHFCache(at:verdicts:)`` is quick, but it can
/// only guess: which files make a download complete depends on what the
/// family's loader asks for. A refresh asks mflux itself, through the bundled
/// `hf_cache_probe.py`, about every built-in model's folder in the cache, and
/// the quick check defers to the answers. An answer holds while its folder's
/// `blobs/` and `snapshots/` are unchanged; after a download or a cleanup
/// there, the quick check decides again until the next refresh.
///
/// Refreshed at launch, and by Settings ▸ Models when it opens and after each
/// download or deletion. Views read it through `isOnDisk`, so they redraw
/// when the answers arrive.
@Observable
final class HFCacheVerdictStore {
    /// One cache folder to ask about: the repo ID its `models--org--name`
    /// spells, and the ``ModelFamily/id`` whose loader decides.
    nonisolated struct Request: Equatable, Sendable {
        let folder: URL
        let repo: String
        let family: String
    }

    nonisolated private struct Verdict: Sendable {
        let complete: Bool
        /// The folder's ``stamp(_:)`` when mflux was asked.
        let stamp: [String: Date]
    }

    static let shared = HFCacheVerdictStore()

    /// Every built-in model's cache folder in `hubDir`, at each precision,
    /// once each.
    static func requests(hubDir: URL) -> [Request] {
        var requests: [Request] = []
        for model in FluxModelVariant.allModels {
            for quantize in [0, 4, 8] {
                guard let folder = model.hubCacheFolder(quantize: quantize, hubDir: hubDir),
                      let repo = repoID(cacheFolder: folder.lastPathComponent),
                      !requests.contains(where: { $0.folder == folder }) else { continue }
                requests.append(Request(folder: folder, repo: repo, family: model.family.id))
            }
        }
        return requests
    }

    /// `models--org--name` → `org/name`, the inverse of
    /// ``ModelDownloadStore/cacheFolder(repo:hubDir:)``.
    static func repoID(cacheFolder name: String) -> String? {
        let prefix = "models--"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let separator = rest.range(of: "--") else { return nil }
        return rest.replacingCharacters(in: separator, with: "/")
    }

    nonisolated private static func key(_ folder: URL) -> String {
        folder.standardizedFileURL.path
    }

    /// The modification dates of what mflux's answer rests on: `blobs/`, and
    /// every folder under `snapshots/`, where hf links each revision's files.
    /// Adding or removing a blob or a link changes its parent folder's date.
    /// (mflux never reads `refs/`.)
    nonisolated private static func stamp(_ folder: URL) -> [String: Date] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let snapshots = folder.appendingPathComponent("snapshots", isDirectory: true)
        var dates: [String: Date] = [:]
        var folders = [folder.appendingPathComponent("blobs", isDirectory: true), snapshots]
        let walk = FileManager.default.enumerator(at: snapshots, includingPropertiesForKeys: Array(keys))
        while let url = walk?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: keys))?.isDirectory == true {
                folders.append(url)
            }
        }
        for url in folders {
            if let date = try? url.resourceValues(forKeys: keys).contentModificationDate {
                dates[url.path] = date
            }
        }
        return dates
    }

    /// Keyed by the folder's standardized path.
    private var verdicts: [String: Verdict] = [:]

    /// mflux's answer for the cache folder `folder`, or nil when there is none
    /// or its `blobs/` or `snapshots/` changed since.
    func isComplete(_ folder: URL) -> Bool? {
        guard let verdict = verdicts[Self.key(folder)],
              verdict.stamp == Self.stamp(folder) else { return nil }
        return verdict.complete
    }

    /// Asks the mflux that generation runs on about the models folder.
    func refresh(settings: AppSettings) async {
        guard let script = Bundle.main.url(forResource: "hf_cache_probe", withExtension: "py") else { return }
        await refresh(python: try? settings.toolchain.mfluxInterpreter(), script: script, hubDir: settings.hfHubDir)
    }

    /// Asks `python` running `script` about every built-in model's folder in
    /// `hubDir`. Folders it gives no answer for keep their previous one.
    func refresh(python: String?, script: URL, hubDir: URL) async {
        let requests = Self.requests(hubDir: hubDir)
        guard let python, !requests.isEmpty else { return }
        let answers = await Task.detached(priority: .utility) {
            // Stamped before asking, so a download that lands meanwhile makes the answer stale.
            let stamps = requests.map { Self.stamp($0.folder) }
            let complete = MfluxProbes.hfCacheCompleteness(
                python: python, script: script, hubDir: hubDir, requests: requests.map { ($0.family, $0.repo) }
            ) ?? [:]
            return zip(requests, stamps).compactMap { request, stamp in
                complete[request.repo].map { (Self.key(request.folder), Verdict(complete: $0, stamp: stamp)) }
            }
        }.value
        for (key, verdict) in answers {
            verdicts[key] = verdict
        }
    }
}
