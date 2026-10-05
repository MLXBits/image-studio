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

    private func makeStore(access: RecordingFileAccess = RecordingFileAccess()) -> ProfileStore {
        let settings = AppSettings()
        // Never write the real settings.json from a test.
        settings.suspendPersistence()
        settings.fileAccess = access
        return ProfileStore(
            settings: settings, jobStores: [], gallery: GalleryStore(),
            coordinator: GenerationCoordinator(), paths: paths, defaults: defaults
        )
    }

    /// Creates "Work" and switches into it, as New Profile does.
    private func storeInWork(access: RecordingFileAccess = RecordingFileAccess()) throws -> (ProfileStore, UUID) {
        let store = makeStore(access: access)
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

    /// Spec §4: a profile's library grant starts when the profile activates and
    /// stops when it deactivates.
    @Test func theActiveLibraryIsHeldUntilTheProfileSwitchesAway() throws {
        let access = RecordingFileAccess()
        let work = ProfileStore.resolvedPath(library.path)
        let (store, _) = try storeInWork(access: access)
        #expect(access.isHeld(work))

        try store.requestSwitch(to: #require(store.defaultProfileID))
        store.completePendingSwitch()

        #expect(!access.isHeld(work))
    }

    @Test func aLibraryWithoutAccessShowsTheBanner() throws {
        let access = RecordingFileAccess()
        access.unreachable = [ProfileStore.resolvedPath(library.path)]
        let (store, _) = try storeInWork(access: access)
        #expect(store.libraryStatus == .noAccess)
        #expect(store.isLibraryMissing)
    }

    @Test func regainedAccessIsPickedUpOnRefresh() throws {
        let access = RecordingFileAccess()
        let work = ProfileStore.resolvedPath(library.path)
        access.unreachable = [work]
        let (store, _) = try storeInWork(access: access)

        access.unreachable = []
        store.refreshLibraryAvailability()

        #expect(store.libraryStatus == .available)
        #expect(access.isHeld(work))
    }

    /// A library whose drive comes back gets its grant started afresh: the old
    /// lease ends before the new one begins, so a grant started before the
    /// unplug isn't carried over to the remount.
    @Test func aLibraryThatComesBackGetsAFreshGrant() throws {
        let access = RecordingFileAccess()
        let work = ProfileStore.resolvedPath(library.path)
        let (store, _) = try storeInWork(access: access)
        let unplugged = root.appendingPathComponent("Unplugged", isDirectory: true)
        try FileManager.default.moveItem(at: library, to: unplugged)
        store.refreshLibraryAvailability()
        #expect(store.libraryStatus == .missing)

        try FileManager.default.moveItem(at: unplugged, to: library)
        let before = access.events.count
        store.refreshLibraryAvailability()

        #expect(store.libraryStatus == .available)
        #expect(Array(access.events[before...]) == ["end \(work)", "begin \(work)"])
    }

    /// The profile's Inputs/ copies live in its data folder, so they go with it.
    @Test func removingAProfileForgetsItsLibraryAndDeletesItsInputs() throws {
        let access = RecordingFileAccess()
        let (store, workID) = try storeInWork(access: access)
        let inputs = paths.dataDirectory(for: workID).appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)

        store.removeActiveProfile()
        store.completePendingSwitch()

        #expect(!FileManager.default.fileExists(atPath: inputs.path))
        #expect(access.forgotten == [ProfileStore.resolvedPath(library.path)])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
