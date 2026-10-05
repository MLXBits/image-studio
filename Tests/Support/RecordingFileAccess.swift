import Foundation
@testable import MLXBits_Image_Studio

/// A FileAccess that records what the app asks of it, for tests of the callers:
/// ProfileStore, AppSettings. Paths in ``unreachable`` can't be reached.
final class RecordingFileAccess: FileAccess {
    var unreachable: Set<String> = []
    private(set) var remembered: [String] = []
    private(set) var forgotten: [String] = []
    /// How many unended leases hold each path.
    private var held: [String: Int] = [:]

    func isHeld(_ path: String) -> Bool {
        (held[path] ?? 0) > 0
    }

    func remember(_ url: URL) {
        remembered.append(url.path)
    }

    func forget(_ path: String) {
        forgotten.append(path)
    }

    func canReach(_ path: String) -> Bool {
        !unreachable.contains(path)
    }

    func beginAccess(to paths: [String]) throws -> FileAccessLease {
        if let lost = paths.first(where: { unreachable.contains($0) }) {
            throw FileAccessError.accessLost(lost)
        }
        return hold(paths)
    }

    func beginAccess(toAvailable paths: [String]) -> FileAccessLease {
        hold(paths.filter { !unreachable.contains($0) })
    }

    func adoptSourceImage(_ path: String, library _: String, inputs _: URL?) -> String {
        path
    }

    private func hold(_ paths: [String]) -> FileAccessLease {
        let kept = paths.filter(FileAccessPath.isLocal)
        kept.forEach { held[$0, default: 0] += 1 }
        return FileAccessLease { [weak self] in
            kept.forEach { self?.held[$0, default: 1] -= 1 }
        }
    }
}
