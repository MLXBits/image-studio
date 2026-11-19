import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Moving gallery images to the Trash and back, with a temp folder standing in for the Trash.
@Suite("Gallery trash and restore")
struct GalleryTrashTests {
    private let root: URL
    private let trashDir: URL
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("GalleryTrash-\(UUID().uuidString)")
        trashDir = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    private func write(_ name: String, in dir: URL, _ text: String = "x") throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Stand-in for `FileManager.trashItem`: moves into `trashDir` under a unique name.
    private func fakeTrash(_ url: URL) throws -> URL {
        let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    @Test func trashesTheImageAndItsSidecar() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root)
        let sidecar = try write("a.json", in: root, "settings")

        let item = try GalleryTrash.trashImage(image, using: fakeTrash)

        #expect(!fm.fileExists(atPath: image.path))
        #expect(!fm.fileExists(atPath: sidecar.path))
        #expect(item.original == image)
        #expect(item.sidecar?.original == sidecar)
        #expect(fm.fileExists(atPath: item.trashed.path))
    }

    @Test func trashesAnImageWithoutASidecar() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root)

        let item = try GalleryTrash.trashImage(image, using: fakeTrash)

        #expect(item.sidecar == nil)
        #expect(!fm.fileExists(atPath: image.path))
    }

    @Test func aFailedImageTrashKeepsTheSidecar() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root)
        let sidecar = try write("a.json", in: root, "settings")
        struct Refused: Error {}

        #expect(throws: Refused.self) {
            try GalleryTrash.trashImage(image) { _ in throw Refused() }
        }
        #expect(fm.fileExists(atPath: image.path))
        #expect(fm.fileExists(atPath: sidecar.path))
    }

    @Test func restorePutsTheImageAndSidecarBack() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root, "pixels")
        let sidecar = try write("a.json", in: root, "settings")
        let item = try GalleryTrash.trashImage(image, using: fakeTrash)

        let failures = GalleryTrash.restore([item])

        #expect(failures.isEmpty)
        #expect(try String(contentsOf: image, encoding: .utf8) == "pixels")
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "settings")
        #expect(!fm.fileExists(atPath: item.trashed.path))
    }

    @Test func restoreRecreatesAMissingFolder() throws {
        defer { try? fm.removeItem(at: root) }
        let board = root.appendingPathComponent("Board")
        let image = try write("a.png", in: board)
        let item = try GalleryTrash.trashImage(image, using: fakeTrash)
        try fm.removeItem(at: board)

        let failures = GalleryTrash.restore([item])

        #expect(failures.isEmpty)
        #expect(fm.fileExists(atPath: image.path))
    }

    @Test func restoreRefusesATakenName() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root, "old")
        let item = try GalleryTrash.trashImage(image, using: fakeTrash)
        _ = try write("a.png", in: root, "new")

        let failures = GalleryTrash.restore([item])

        #expect(failures == ["a.png"])
        #expect(try String(contentsOf: image, encoding: .utf8) == "new")
        #expect(fm.fileExists(atPath: item.trashed.path))
    }

    @Test func restoreSkipsAnItemEmptiedFromTheTrash() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root)
        let item = try GalleryTrash.trashImage(image, using: fakeTrash)
        try fm.removeItem(at: item.trashed)

        #expect(GalleryTrash.restore([item]) == ["a.png"])
    }

    @Test func restoreLeavesTheSidecarWhenItsNameIsTaken() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root)
        _ = try write("a.json", in: root, "settings")
        let item = try GalleryTrash.trashImage(image, using: fakeTrash)
        let stray = try write("a.json", in: root, "stray")

        let failures = GalleryTrash.restore([item])

        #expect(failures.isEmpty)
        #expect(fm.fileExists(atPath: image.path))
        #expect(try String(contentsOf: stray, encoding: .utf8) == "stray")
    }

    @Test func trashesAndRestoresAFolder() throws {
        defer { try? fm.removeItem(at: root) }
        let board = root.appendingPathComponent("Board")
        let image = try write("a.png", in: board)

        let item = try GalleryTrash.trashFolder(board, using: fakeTrash)
        #expect(!fm.fileExists(atPath: board.path))

        #expect(GalleryTrash.restore([item]).isEmpty)
        #expect(fm.fileExists(atPath: image.path))
    }
}
