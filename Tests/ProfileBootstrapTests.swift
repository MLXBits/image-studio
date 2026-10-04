import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers the one-time move to profiles and the per-launch cleanup, against a
/// throwaway App Support folder. Migration runs on the user's real data, so
/// each crash point must leave something the next launch can recover from.
/// In-memory stand-in for the UserDefaults calls migration makes.
final class MemoryDefaults: LegacyDefaults {
    var values: [String: [String]] = [:]

    func stringArray(forKey defaultName: String) -> [String]? {
        values[defaultName]
    }

    func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }
}

final class ProfileBootstrapTests {
    private let fm = FileManager.default
    private let root: URL
    private let paths: ProfilePaths
    private let defaults = MemoryDefaults()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        paths = ProfilePaths(
            appSupport: root.appendingPathComponent("AppSupport", isDirectory: true),
            thumbnailsRoot: root.appendingPathComponent("Thumbnails", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func writeLegacyInstall() throws {
        try write("""
        {"mfluxBinaryDir": "/opt/bin", "outputDir": "/Users/me/Pictures/Gen",
         "notepadText": "my notes", "defaultBoard": "Keepers"}
        """, to: paths.appSupport.appendingPathComponent("settings.json"))
        try write("[]", to: paths.appSupport.appendingPathComponent("jobs.json"))
        try write("[]", to: paths.appSupport.appendingPathComponent("krea2-jobs.json"))
        defaults.values[ProfileBootstrap.legacyCollapsedBoardsKey] = ["Drafts"]
    }

    private func migratedRegistry() throws -> ProfileRegistry {
        guard case let .migrated(registry) = ProfileBootstrap.loadOrMigrate(paths: paths, defaults: defaults) else {
            Issue.record("expected a migration")
            throw CancellationError()
        }
        return registry
    }

    // MARK: - Migration

    @Test func legacyInstallBecomesADefaultProfile() throws {
        try writeLegacyInstall()

        let registry = try migratedRegistry()

        let profile = try #require(registry.activeProfile)
        #expect(registry.profiles.count == 1)
        #expect(profile.name == "Default")
        #expect(profile.libraryPath == "/Users/me/Pictures/Gen")
        let dir = paths.dataDirectory(for: profile.id)
        let stored = AppSettings.ProfileStored.load(from: dir.appendingPathComponent("profile.json"))
        #expect(stored.notepadText == "my notes")
        #expect(stored.defaultBoard == "Keepers")
        #expect(stored.galleryCollapsedBoards == ["Drafts"])
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("jobs.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("krea2-jobs.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("legacy-settings.json").path))
        #expect(fm.fileExists(atPath: paths.registry.path))
    }

    /// Until the registry is written nothing is removed, so a crash mid-way
    /// still has the originals for the next launch to migrate again.
    @Test func migrationCopiesRatherThanMoves() throws {
        try writeLegacyInstall()
        _ = try migratedRegistry()
        #expect(fm.fileExists(atPath: paths.appSupport.appendingPathComponent("jobs.json").path))
    }

    @Test func freshInstallGetsADefaultProfileWithNoFolder() throws {
        let registry = try migratedRegistry()
        #expect(registry.activeProfile?.libraryPath == "")
    }

    /// Profile folders without a registry are left over from a migration that
    /// crashed before committing; they are discarded and the migration redone.
    @Test func leftoversFromAnInterruptedMigrationAreDiscarded() throws {
        try writeLegacyInstall()
        let leftover = paths.dataDirectory(for: UUID())
        try write("{}", to: leftover.appendingPathComponent("profile.json"))

        let registry = try migratedRegistry()

        #expect(!fm.fileExists(atPath: leftover.path))
        #expect(registry.profiles.count == 1)
    }

    // MARK: - Existing registry

    @Test func existingRegistryLoadsWithoutMigrating() throws {
        let profile = Profile(id: UUID(), name: "Work", libraryPath: "/w")
        try ProfileBootstrap.write(ProfileRegistry(activeProfileID: profile.id, profiles: [profile]), to: paths.registry)
        try writeLegacyInstall()

        let outcome = ProfileBootstrap.loadOrMigrate(paths: paths, defaults: defaults)

        #expect(outcome == .loaded(ProfileRegistry(activeProfileID: profile.id, profiles: [profile])))
    }

    /// A registry that exists but can't be read must never be treated as
    /// missing — that would migrate again and orphan every profile.
    @Test func unreadableRegistryFailsAndTouchesNothing() throws {
        try writeLegacyInstall()
        try write("{ broken", to: paths.registry)

        let outcome = ProfileBootstrap.loadOrMigrate(paths: paths, defaults: defaults)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!fm.fileExists(atPath: paths.profilesRoot.path))
        #expect(fm.fileExists(atPath: paths.appSupport.appendingPathComponent("jobs.json").path))
    }

    // MARK: - Cleanup

    @Test func cleanupRemovesLegacyFilesAndOrphans() throws {
        try writeLegacyInstall()
        let registry = try migratedRegistry()
        let orphanID = UUID()
        try write("{}", to: paths.dataDirectory(for: orphanID).appendingPathComponent("profile.json"))
        try write("x", to: paths.thumbnailDirectory(for: orphanID).appendingPathComponent("a.jpg"))
        let keptThumbs = try #require(registry.activeProfile).id

        try write("x", to: paths.thumbnailDirectory(for: keptThumbs).appendingPathComponent("b.jpg"))
        ProfileBootstrap.cleanUp(registry: registry, paths: paths, defaults: defaults)

        #expect(!fm.fileExists(atPath: paths.appSupport.appendingPathComponent("jobs.json").path))
        #expect(!fm.fileExists(atPath: paths.appSupport.appendingPathComponent("krea2-jobs.json").path))
        #expect(defaults.values[ProfileBootstrap.legacyCollapsedBoardsKey] == nil)
        #expect(!fm.fileExists(atPath: paths.dataDirectory(for: orphanID).path))
        #expect(!fm.fileExists(atPath: paths.thumbnailDirectory(for: orphanID).path))
        #expect(fm.fileExists(atPath: paths.thumbnailDirectory(for: keptThumbs).appendingPathComponent("b.jpg").path))
    }

    @Test func looseThumbnailsMoveIntoTheProfileFolder() throws {
        try write("x", to: paths.thumbnailsRoot.appendingPathComponent("abc.jpg"))
        let target = paths.thumbnailDirectory(for: UUID())

        ProfileBootstrap.adoptLooseThumbnails(from: paths.thumbnailsRoot, into: target)

        #expect(fm.fileExists(atPath: target.appendingPathComponent("abc.jpg").path))
        #expect(!fm.fileExists(atPath: paths.thumbnailsRoot.appendingPathComponent("abc.jpg").path))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
