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
    /// Whether a path can be read without a grant: the app's container, or
    /// Pictures. Tests pass `{ _ in false }` to stand in for the sandbox.
    private let isReadable: (String) -> Bool
    private var started: [String: Started] = [:]
    /// Grants that failed to start: their bookmark no longer resolves to the
    /// path it was made for. They stop counting as access until chosen again.
    private var unusable: Set<String> = []

    /// The grants started right now, by the path each was made for. For tests.
    var startedGrantPaths: [String] {
        started.keys.sorted()
    }

    init(
        storeURL: URL, codec: BookmarkCodec = .securityScoped,
        isReadable: @escaping (String) -> Bool = FileAccessPath.isReadable
    ) {
        store = GrantStore(url: storeURL)
        self.codec = codec
        self.isReadable = isReadable
    }

    func remember(_ url: URL) {
        guard let bookmark = try? codec.make(url) else { return }
        let path = FileAccessPath.normalized(url.path)
        store.set(bookmark, for: path)
        unusable.remove(path)
    }

    func forget(_ path: String) {
        let normalized = FileAccessPath.normalized(path)
        store.remove(normalized)
        unusable.remove(normalized)
    }

    func canReach(_ path: String) -> Bool {
        guard FileAccessPath.isLocal(path) else { return false }
        let normalized = FileAccessPath.normalized(path)
        guard FileManager.default.fileExists(atPath: normalized) else { return false }
        if let grant = store.grant(covering: normalized), !unusable.contains(grant.path) {
            return true
        }
        return isReadable(normalized)
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
        // Never resolve a bookmark for a path that isn't there: resolving one on
        // an offline network share can try to mount it.
        guard FileManager.default.fileExists(atPath: normalized) else { return .lost }
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
                unusable.remove(grant.path)
                return .started(grant.path)
            }
            unusable.insert(grant.path)
        }
        return isReadable(normalized) ? .notNeeded : .lost
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
