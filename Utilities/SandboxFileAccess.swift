import Foundation

/// The App Store build's ``FileAccess`` (spec §4).
///
/// A folder or file chosen in an open panel is remembered as a security-scoped
/// bookmark in a ``GrantStore``. A path is reachable through the deepest grant
/// at or above it. Grants are started on demand and reference-counted, so
/// overlapping leases share one start. A stale bookmark is re-created quietly.
/// A bookmark that no longer resolves to the path it was made for (the file was
/// deleted, or the folder moved) isn't used.
final class SandboxFileAccess: FileAccess {
    private struct Started {
        let url: URL
        var holders: Int
    }

    private enum Outcome {
        case started(String)
        /// No grant needed: the app's container, or Pictures (its entitlement).
        case notNeeded
        case lost
    }

    private let store: GrantStore
    private let codec: BookmarkCodec
    private var started: [String: Started] = [:]

    /// The grants started right now, by the path each was made for. For tests.
    var startedGrantPaths: [String] {
        started.keys.sorted()
    }

    init(storeURL: URL, codec: BookmarkCodec = .securityScoped) {
        store = GrantStore(url: storeURL)
        self.codec = codec
    }

    func remember(_ url: URL) {
        guard let bookmark = try? codec.make(url) else { return }
        store.set(bookmark, for: FileAccessPath.normalized(url.path))
    }

    func forget(_ path: String) {
        store.remove(FileAccessPath.normalized(path))
    }

    func canReach(_ path: String) -> Bool {
        guard FileAccessPath.isLocal(path) else { return false }
        let normalized = FileAccessPath.normalized(path)
        guard FileManager.default.fileExists(atPath: normalized) else { return false }
        return store.grant(covering: normalized) != nil || FileAccessPath.isReadable(normalized)
    }

    func beginAccess(to paths: [String]) throws -> FileAccessLease {
        var keys: [String] = []
        for path in paths where FileAccessPath.isLocal(path) {
            switch start(path) {
            case let .started(key):
                keys.append(key)
            case .notNeeded:
                break
            case .lost:
                keys.forEach(stop)
                throw FileAccessError.accessLost(path)
            }
        }
        return lease(for: keys)
    }

    func beginAccess(toAvailable paths: [String]) -> FileAccessLease {
        var keys: [String] = []
        for path in paths where FileAccessPath.isLocal(path) {
            if case let .started(key) = start(path) {
                keys.append(key)
            }
        }
        return lease(for: keys)
    }

    func adoptSourceImage(_ path: String, library: String, inputs: URL?) -> String {
        guard let inputs, FileAccessPath.isLocal(path) else { return path }
        return (try? SourceImageImport.adopt(path, library: library, inputs: inputs)) ?? path
    }

    private func lease(for keys: [String]) -> FileAccessLease {
        FileAccessLease { [weak self] in
            keys.forEach { self?.stop($0) }
        }
    }

    private func start(_ path: String) -> Outcome {
        let normalized = FileAccessPath.normalized(path)
        if let grant = store.grant(covering: normalized) {
            if started[grant.path] != nil {
                started[grant.path]?.holders += 1
                return .started(grant.path)
            }
            if let resolved = try? codec.resolve(grant.bookmark),
               FileAccessPath.normalized(resolved.url.path) == grant.path,
               resolved.url.startAccessingSecurityScopedResource() {
                // Re-created while accessing, as a stale security-scoped bookmark requires.
                if resolved.isStale, let fresh = try? codec.make(resolved.url) {
                    store.set(fresh, for: grant.path)
                }
                started[grant.path] = Started(url: resolved.url, holders: 1)
                return .started(grant.path)
            }
        }
        let reachable = FileManager.default.fileExists(atPath: normalized) && FileAccessPath.isReadable(normalized)
        return reachable ? .notNeeded : .lost
    }

    private func stop(_ key: String) {
        guard var entry = started[key] else { return }
        entry.holders -= 1
        if entry.holders > 0 {
            started[key] = entry
        } else {
            entry.url.stopAccessingSecurityScopedResource()
            started[key] = nil
        }
    }
}
