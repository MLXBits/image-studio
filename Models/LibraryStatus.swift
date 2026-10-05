/// Whether the active profile's library folder can take new images (spec §4).
enum LibraryStatus: Equatable {
    /// No folder chosen yet; the first-run prompt is up.
    case unset
    case available
    /// The folder isn't there: an unplugged drive, or moved in Finder.
    case missing
    /// App Store build: the folder is there, but the app has no grant for it.
    /// It was chosen by an older build, or its bookmark stopped resolving.
    /// Choosing it again re-grants.
    case noAccess

    init(path: String, exists: Bool, reachable: Bool) {
        if path.isEmpty {
            self = .unset
        } else if !exists {
            self = .missing
        } else if !reachable {
            self = .noAccess
        } else {
            self = .available
        }
    }

    /// Why a generation can't save into the library, or nil when it can.
    func jobFailureReason(path: String) -> String? {
        switch self {
        case .available: nil
        case .unset: "No library folder chosen — choose one in Settings"
        case .missing: "Library folder not found: \(path) — reconnect its drive or choose a folder in Settings"
        case .noAccess: "No access to the library folder \(path) — choose it again in Settings"
        }
    }
}
