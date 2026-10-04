import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers the per-profile thumbnail cache. Each profile caches in its own
/// folder, and the post-scan sweep — which deletes entries for images no longer
/// in the library — must only ever touch the folder of the library it scanned.
struct ThumbnailCacheTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func cached(_ path: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: ThumbnailCache.cacheURL(for: path, in: dir).path)
    }

    @Test func sweepOnlyTouchesItsOwnDirectory() {
        let dirA = tempDir()
        let dirB = tempDir()
        ThumbnailCache.store(data: Data([1]), for: "/lib-a/keep.png", in: dirA)
        ThumbnailCache.store(data: Data([1]), for: "/lib-a/gone.png", in: dirA)
        ThumbnailCache.store(data: Data([1]), for: "/lib-b/other.png", in: dirB)

        ThumbnailCache.sweep(validPaths: ["/lib-a/keep.png"], in: dirA)

        #expect(cached("/lib-a/keep.png", in: dirA))
        #expect(!cached("/lib-a/gone.png", in: dirA))
        #expect(cached("/lib-b/other.png", in: dirB))
    }

    @Test func readReturnsWhatWasStoredInThatDirectory() {
        let dirA = tempDir()
        ThumbnailCache.store(data: Data([7, 7]), for: "/lib/x.png", in: dirA)
        #expect(ThumbnailCache.read(for: "/lib/x.png", in: dirA) == Data([7, 7]))
        #expect(ThumbnailCache.read(for: "/lib/x.png", in: tempDir()) == nil)
    }

    /// An unplugged drive scans as an empty library; sweeping then would wipe
    /// every thumbnail and force a full regenerate when the drive comes back.
    @Test func scanningAMissingLibraryKeepsTheCache() async throws {
        let thumbs = tempDir()
        ThumbnailCache.store(data: Data([1]), for: "/Volumes/Gone/a.png", in: thumbs)
        let gallery = GalleryStore()
        gallery.activate(thumbnailDirectory: thumbs)

        gallery.scan(outputDir: "/Volumes/Gone-\(UUID().uuidString)")
        while gallery.isScanning {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(cached("/Volumes/Gone/a.png", in: thumbs))
    }

    @Test func activatingClearsThePreviousLibrary() {
        let gallery = GalleryStore()
        gallery.boards = ["Portraits"]
        gallery.selectedBoard = "Portraits"
        gallery.lockedPaths = ["/lib-a/x.png"]

        gallery.activate(thumbnailDirectory: tempDir())

        #expect(gallery.items.isEmpty)
        #expect(gallery.boards.isEmpty)
        #expect(gallery.selectedBoard == "All")
        #expect(gallery.lockedPaths.isEmpty)
    }

    /// Changing the active profile's folder keeps the same form state, so the
    /// images attached to it must stay protected from delete/move/rename.
    @Test func changingTheFolderInPlaceKeepsAttachedImageLocks() {
        let gallery = GalleryStore()
        gallery.lockedPaths = ["/lib-a/source.png"]

        gallery.activate(thumbnailDirectory: tempDir(), preservingLocks: true)

        #expect(gallery.lockedPaths == ["/lib-a/source.png"])
    }

    /// A scan of the old library still in flight when the profile changes must
    /// not land its items in the new profile's gallery.
    @Test func lateScanOfThePreviousLibraryIsDiscarded() async throws {
        let library = tempDir()
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data().write(to: library.appendingPathComponent("old.png"))
        let gallery = GalleryStore()
        gallery.activate(thumbnailDirectory: tempDir())

        gallery.scan(outputDir: library.path)
        gallery.activate(thumbnailDirectory: tempDir())
        try await Task.sleep(for: .milliseconds(500))

        #expect(gallery.items.isEmpty)
    }
}
