import Foundation

/// Path helpers for sandbox file access (spec §4).
nonisolated enum FileAccessPath {
    /// The person's real home folder. Inside the sandbox `NSHomeDirectory()`
    /// is the app's container, which is never what a folder default means.
    static var realHome: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    /// The form grants are stored and looked up under: `~` expanded, `.`/`..`
    /// folded, symlinks resolved. One folder always has one key.
    static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether `path` names a place on disk rather than a Hugging Face repo ID,
    /// a ComfyUI server LoRA name, or nothing.
    static func isLocal(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~")
    }

    /// `~/.cache/huggingface` in the person's real home, when it exists. The
    /// sandbox can `stat` it without a grant, though not list it.
    static func existingHuggingFaceCache(home: String = realHome) -> URL? {
        let cache = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".cache/huggingface", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cache.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return cache
    }

    /// Where Skip for Now makes the library. The DMG uses the home folder (not
    /// iCloud-synced). The App Store build uses Pictures: the sandbox may write
    /// there, and Finder shows it.
    static func defaultLibrary(isAppStore: Bool, home: String) -> String {
        isAppStore ? "\(home)/Pictures/MLXBits Image Studio" : "\(home)/MLXBits Image Studio"
    }

    /// Whether this process can open `path` for reading now. The sandbox lets
    /// the app `stat` a folder it has no grant for, but not open it.
    static func isReadable(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}
