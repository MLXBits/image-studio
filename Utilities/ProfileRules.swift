import Foundation

/// How a candidate library folder sits relative to another profile's folder.
enum LibraryPathRelation: Equatable {
    case same
    /// The candidate is a subfolder of the other library.
    case inside
    /// The candidate is a parent of the other library.
    case contains
    case unrelated
}

/// Why a library folder can't be used for a profile.
enum LibraryPathProblem: Equatable {
    case empty
    case notAbsolute
    case conflict(LibraryPathRelation, profileName: String)

    var message: String {
        switch self {
        case .empty:
            "Choose a library folder."
        case .notAbsolute:
            "Enter a full folder path, starting with / or ~."
        case let .conflict(.inside, name):
            "That folder is inside the library for “\(name)”."
        case let .conflict(.contains, name):
            "That folder contains the library for “\(name)”."
        case let .conflict(_, name):
            "That folder is already the library for “\(name)”."
        }
    }
}

/// Why a name can't be used for a profile.
enum ProfileNameProblem: Equatable {
    case empty
    case duplicate(String)

    var message: String {
        switch self {
        case .empty: "Enter a name."
        case let .duplicate(name): "A profile named “\(name)” already exists."
        }
    }
}

/// Pure validation for profile names and library folders.
///
/// Folders are compared lexically, component by component, after expanding `~`
/// and `.`/`..` and folding case (APFS is case-insensitive by default). Callers
/// resolve symlinks first — that needs the disk, so it stays out of here.
enum ProfileRules {
    static func relation(of candidate: String, to other: String) -> LibraryPathRelation {
        let a = components(candidate)
        let b = components(other)
        if a == b {
            return .same
        }
        if a.count > b.count, Array(a.prefix(b.count)) == b {
            return .inside
        }
        if b.count > a.count, Array(b.prefix(a.count)) == a {
            return .contains
        }
        return .unrelated
    }

    /// The first rule `path` breaks against `profiles`, or `nil` when it's usable.
    /// `excluding` skips the profile being edited, so Change Folder doesn't clash
    /// with its own current library. Profiles with no folder yet are skipped.
    static func libraryProblem(
        path: String, profiles: [Profile], excluding: UUID?
    ) -> LibraryPathProblem? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard (trimmed as NSString).expandingTildeInPath.hasPrefix("/") else { return .notAbsolute }
        for profile in profiles where profile.id != excluding && !profile.libraryPath.isEmpty {
            let rel = relation(of: trimmed, to: profile.libraryPath)
            if rel != .unrelated {
                return .conflict(rel, profileName: profile.name)
            }
        }
        return nil
    }

    /// Whether a library folder sits on the volume it should. Older builds
    /// recreated a missing library on the boot disk, so an unplugged drive can
    /// leave a real `/Volumes/<drive>/…` folder behind; a library under
    /// /Volumes only counts when the volume it's on is mounted under /Volumes.
    /// `volumePath` is the mount point of the volume holding `path`.
    static func isOnExpectedVolume(path: String, volumePath: String) -> Bool {
        !path.hasPrefix("/Volumes/") || volumePath.hasPrefix("/Volumes/")
    }

    static func nameProblem(
        _ name: String, profiles: [Profile], excluding: UUID?
    ) -> ProfileNameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let clash = profiles.first {
            $0.id != excluding && $0.name.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return clash.map { .duplicate($0.name) }
    }

    private static func components(_ path: String) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.pathComponents
            .filter { $0 != "/" }
            .map { $0.lowercased() }
    }
}

/// Decides whether the active profile can change right now. Output paths are
/// resolved when a job *starts*, so anything running or queued would land in
/// the next profile's library.
enum ProfileSwitchGate {
    /// `nil` when switching is allowed; otherwise why not, for the menu.
    static func blockReason(isGenerating: Bool, queuedCount: Int) -> String? {
        if isGenerating {
            return "Finish or cancel the current generation to switch profiles."
        }
        if queuedCount > 0 {
            let jobs = queuedCount == 1 ? "1 queued job" : "\(queuedCount) queued jobs"
            return "Run or cancel \(jobs) to switch profiles."
        }
        return nil
    }
}
