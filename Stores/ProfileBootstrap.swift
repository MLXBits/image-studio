import Foundation

/// Where profile data lives on disk. Injected so the migration can be tested
/// against a throwaway folder; the app uses ``live``.
struct ProfilePaths: Equatable {
    static let live = Self(
        appSupport: AppSettings.appSupportURL,
        thumbnailsRoot: ThumbnailCache.rootDirectory
    )

    /// A fresh temporary location, for the app when it runs as the unit tests'
    /// host: a test run must never migrate or clean up the real profile data.
    static func throwaway() -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXBitsImageStudio-TestHost-\(UUID().uuidString)", isDirectory: true)
        return Self(
            appSupport: root.appendingPathComponent("AppSupport", isDirectory: true),
            thumbnailsRoot: root.appendingPathComponent("Thumbnails", isDirectory: true)
        )
    }

    /// `~/Library/Application Support/MLXBits Image Studio`
    let appSupport: URL
    /// `~/Library/Caches/<bundle>/Thumbnails`
    let thumbnailsRoot: URL

    var registry: URL {
        appSupport.appendingPathComponent("profiles.json")
    }

    var profilesRoot: URL {
        appSupport.appendingPathComponent("Profiles", isDirectory: true)
    }

    /// A profile's notepad, history, drafts and job history.
    func dataDirectory(for id: UUID) -> URL {
        profilesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func profileFile(for id: UUID) -> URL {
        dataDirectory(for: id).appendingPathComponent("profile.json")
    }

    func thumbnailDirectory(for id: UUID) -> URL {
        thumbnailsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

/// The two UserDefaults calls migration makes, behind a protocol so tests can
/// run it without leaving preference files behind.
protocol LegacyDefaults: AnyObject {
    func stringArray(forKey defaultName: String) -> [String]?
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: LegacyDefaults {}

/// The one-time move from a single library to profiles, plus the cleanup that
/// runs on every launch.
///
/// Migration only *copies* until `profiles.json` is written — that write is the
/// commit point. A crash before it leaves the originals in place and the next
/// launch starts over; a crash after it is finished by ``cleanUp(registry:paths:defaults:)``.
enum ProfileBootstrap {
    enum Outcome: Equatable {
        case loaded(ProfileRegistry)
        case migrated(ProfileRegistry)
        case failed(String)
    }

    /// Only `outputDir` is read from the old settings file; everything else
    /// per-profile decodes as ``AppSettings/ProfileStored``.
    private struct LegacyLibrary: Decodable {
        var outputDir: String?
    }

    static let legacyCollapsedBoardsKey = "gallery.collapsedBoards"
    /// The pre-profiles job histories in the App Support root. Each now lives in
    /// the profile's data folder under the same name (see ``JobHistoryFile``).
    static let legacyJobFiles = [
        "jobs.json", "ideogram4-jobs.json", "krea2-jobs.json", "zimage-jobs.json", "seedvr2-jobs.json",
    ]

    static func loadOrMigrate(paths: ProfilePaths, defaults: LegacyDefaults) -> Outcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.registry.path) {
            // An unreadable registry is never treated as missing: migrating again
            // would orphan every profile created since.
            guard let data = try? Data(contentsOf: paths.registry),
                  let registry = try? JSONDecoder().decode(ProfileRegistry.self, from: data),
                  !registry.profiles.isEmpty
            else {
                return .failed("The profile list at \(paths.registry.path) can't be read. "
                    + "Restore it from a backup, or move it aside to start over with a single profile.")
            }
            return .loaded(registry)
        }
        do {
            return try .migrated(migrate(paths: paths, defaults: defaults))
        } catch {
            return .failed("Couldn't set up profiles: \(error.localizedDescription)")
        }
    }

    private static func migrate(paths: ProfilePaths, defaults: LegacyDefaults) throws -> ProfileRegistry {
        let fm = FileManager.default
        // Leftovers from a run that crashed before committing.
        try? fm.removeItem(at: paths.profilesRoot)

        let id = UUID()
        let dir = paths.dataDirectory(for: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let settingsURL = paths.appSupport.appendingPathComponent("settings.json")
        let legacy = try? Data(contentsOf: settingsURL)
        var stored = legacy.flatMap { try? JSONDecoder().decode(AppSettings.ProfileStored.self, from: $0) }
            ?? AppSettings.ProfileStored()
        stored.galleryCollapsedBoards = defaults.stringArray(forKey: legacyCollapsedBoardsKey)
        let outputDir = legacy.flatMap { try? JSONDecoder().decode(LegacyLibrary.self, from: $0) }?.outputDir ?? ""

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(stored).write(to: paths.profileFile(for: id), options: .atomic)
        if legacy != nil {
            try fm.copyItem(at: settingsURL, to: dir.appendingPathComponent("legacy-settings.json"))
        }
        for name in legacyJobFiles {
            let src = paths.appSupport.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: dir.appendingPathComponent(name))
            }
        }

        let registry = ProfileRegistry(
            activeProfileID: id,
            profiles: [Profile(id: id, name: "Default", libraryPath: outputDir)]
        )
        try write(registry, to: paths.registry)
        return registry
    }

    static func write(_ registry: ProfileRegistry, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: url, options: .atomic)
    }

    /// Safe to repeat. Removes what migration copied, and the data and
    /// thumbnail folders of profiles no longer in the registry (finishing a
    /// removal that was interrupted).
    static func cleanUp(registry: ProfileRegistry, paths: ProfilePaths, defaults: LegacyDefaults) {
        let fm = FileManager.default
        for name in legacyJobFiles {
            try? fm.removeItem(at: paths.appSupport.appendingPathComponent(name))
        }
        defaults.removeObject(forKey: legacyCollapsedBoardsKey)

        let known = Set(registry.profiles.map(\.id.uuidString))
        for root in [paths.profilesRoot, paths.thumbnailsRoot] {
            let entries = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where !known.contains(entry.lastPathComponent) {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }

    /// Moves the pre-profiles thumbnails (loose `.jpg` files in the cache root)
    /// into a profile's folder, so a migrated library doesn't regenerate them.
    /// Anything that can't be moved — already present, say — is deleted.
    nonisolated static func adoptLooseThumbnails(from root: URL, into dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in entries where entry.pathExtension == "jpg" {
            do {
                try fm.moveItem(at: entry, to: dir.appendingPathComponent(entry.lastPathComponent))
            } catch {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Deletes loose pre-profiles thumbnails once a migration has adopted them.
    nonisolated static func removeLooseThumbnails(in root: URL) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries where entry.pathExtension == "jpg" {
            try? fm.removeItem(at: entry)
        }
    }
}
