import Foundation

/// How the app reaches folders and files outside its own (spec §4). The DMG
/// passes every path through. The App Store build keeps a security-scoped grant
/// for each folder or file the person chooses, and starts it while a lease
/// holds it. Both compile in every build; ``FileAccessFactory`` picks one.
protocol FileAccess: AnyObject {
    /// Remembers access to a folder or file the person just chose in an open panel.
    func remember(_ url: URL)
    /// Drops the grant for `path` (a removed profile's library).
    func forget(_ path: String)
    /// Whether the app can open `path` now. Always true in the DMG.
    func canReach(_ path: String) -> Bool
    /// Holds every local path in `paths` open for one job or run. Repo IDs,
    /// server names and empty strings are skipped. Throws
    /// ``FileAccessError/accessLost(_:)`` for the first path it can't reach.
    func beginAccess(to paths: [String]) throws -> FileAccessLease
    /// Like ``beginAccess(to:)``, for folders held all session: anything it
    /// can't reach is skipped, and that folder's own row or banner says so.
    func beginAccess(toAvailable paths: [String]) -> FileAccessLease
    /// The path a source image should be used from: in place when it's inside
    /// `library`; otherwise, in the App Store build, a copy in `inputs`, so a
    /// re-run still finds it after a relaunch.
    func adoptSourceImage(_ path: String, library: String, inputs: URL?) -> String
}

/// Holds grants started by ``FileAccess/beginAccess(to:)`` until ``end()``.
/// Ending twice is harmless; a lease never ended keeps its grants for the session.
final class FileAccessLease {
    private var onEnd: (() -> Void)?

    init(onEnd: (() -> Void)? = nil) {
        self.onEnd = onEnd
    }

    func end() {
        let action = onEnd
        onEnd = nil
        action?()
    }
}

enum FileAccessError: LocalizedError, Equatable {
    /// A file or folder the app had access to is gone, or its grant no longer resolves.
    case accessLost(String)

    var errorDescription: String? {
        switch self {
        case let .accessLost(path):
            "Access to \(URL(fileURLWithPath: path).lastPathComponent) was lost — locate the file again."
        }
    }
}

/// The DMG's ``FileAccess``: the app isn't sandboxed, so every path is used as given.
final class PassthroughFileAccess: FileAccess {
    func remember(_: URL) {}

    func forget(_: String) {}

    func canReach(_: String) -> Bool {
        true
    }

    func beginAccess(to _: [String]) throws -> FileAccessLease {
        FileAccessLease()
    }

    func beginAccess(toAvailable _: [String]) -> FileAccessLease {
        FileAccessLease()
    }

    func adoptSourceImage(_ path: String, library _: String, inputs _: URL?) -> String {
        path
    }
}

enum FileAccessFactory {
    /// This flavor's FileAccess. The App Store one keeps its grants in App
    /// Support's `grants.json`, inside the container.
    static func make() -> any FileAccess {
        BuildFlavor.isAppStore
            ? SandboxFileAccess(storeURL: AppSettings.appSupportURL.appendingPathComponent("grants.json"))
            : PassthroughFileAccess()
    }
}
