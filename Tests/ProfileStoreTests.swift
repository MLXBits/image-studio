import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers removing a profile. Removal acts on the active profile — you remove
/// the profile you're in — so it switches to the default profile first, then
/// deletes the removed profile's app data. Its library folder stays on disk.
final class ProfileStoreTests {
    private let root: URL
    private let paths: ProfilePaths
    private let defaults = MemoryDefaults()
    private let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        paths = ProfilePaths(
            appSupport: root.appendingPathComponent("AppSupport", isDirectory: true),
            thumbnailsRoot: root.appendingPathComponent("Thumbnails", isDirectory: true)
        )
        library = root.appendingPathComponent("WorkLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    private func makeStore() -> ProfileStore {
        let settings = AppSettings()
        // Never write the real settings.json from a test.
        settings.suspendPersistence()
        return ProfileStore(
            settings: settings, jobStores: [], gallery: GalleryStore(),
            coordinator: GenerationCoordinator(), paths: paths, defaults: defaults
        )
    }

    /// Creates "Work" and switches into it, as New Profile does.
    private func storeInWork() throws -> (ProfileStore, UUID) {
        let store = makeStore()
        let id = try store.createProfile(name: "Work", libraryPath: library.path).get()
        store.requestSwitch(to: id)
        store.completePendingSwitch()
        #expect(store.activeProfileID == id)
        return (store, id)
    }

    @Test func removingTheActiveProfileSwitchesToTheDefault() throws {
        let (store, workID) = try storeInWork()
        let defaultID = try #require(store.profiles.first?.id)
        try FileManager.default.createDirectory(at: paths.dataDirectory(for: workID), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.profileFile(for: workID))
        try FileManager.default.createDirectory(at: paths.thumbnailDirectory(for: workID), withIntermediateDirectories: true)

        store.removeActiveProfile()
        store.completePendingSwitch()

        #expect(store.activeProfileID == defaultID)
        #expect(!store.profiles.contains { $0.id == workID })
        #expect(!FileManager.default.fileExists(atPath: paths.dataDirectory(for: workID).path))
        #expect(!FileManager.default.fileExists(atPath: paths.thumbnailDirectory(for: workID).path))
        #expect(FileManager.default.fileExists(atPath: library.path))
    }

    @Test func theDefaultProfileCannotBeRemoved() {
        let store = makeStore()
        #expect(!store.canRemoveActiveProfile)

        store.removeActiveProfile()

        #expect(store.phase == .ready)
        #expect(store.profiles.count == 1)
    }

    @Test func anotherProfileCanBeRemovedWhileActive() throws {
        let (store, _) = try storeInWork()
        #expect(store.canRemoveActiveProfile)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
