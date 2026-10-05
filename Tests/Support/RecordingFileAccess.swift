import Foundation
@testable import MLXBits_Image_Studio

/// A FileAccess that records what the app asks of it, for tests of the callers:
/// ProfileStore, AppSettings. Paths in ``unreachable`` can't be reached.
final class RecordingFileAccess: FileAccess {
    var unreachable: Set<String> = []
    private(set) var remembered: [String] = []
    private(set) var forgotten: [String] = []
    /// Every lease start and end, in order: "begin <path>" / "end <path>".
    private(set) var events: [String] = []
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
        for item in kept {
            held[item, default: 0] += 1
            events.append("begin \(item)")
        }
        return FileAccessLease { [weak self] in
            for item in kept {
                self?.held[item, default: 1] -= 1
                self?.events.append("end \(item)")
            }
        }
    }
}
