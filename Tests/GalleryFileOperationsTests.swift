import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The disk-level helpers behind gallery moves and board deletes, run against a temp folder.
@Suite("Gallery file operations")
struct GalleryFileOperationsTests {
    private let root: URL
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("GalleryFileOps-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ name: String, in dir: URL, _ text: String = "x") throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: moveImageWithSidecar

    @Test func movesTheImageAndItsSidecarTogether() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root)
        _ = try write("a.json", in: root, "settings")
        let board = root.appendingPathComponent("Board")

        try GalleryStore.moveImageWithSidecar(image, to: board)

        #expect(fm.fileExists(atPath: board.appendingPathComponent("a.png").path))
        #expect(try text(board.appendingPathComponent("a.json")) == "settings")
        #expect(!fm.fileExists(atPath: image.path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("a.json").path))
    }

    @Test func movesAnImageWithoutASidecar() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root)
        let board = root.appendingPathComponent("Board")

        try GalleryStore.moveImageWithSidecar(image, to: board)

        #expect(fm.fileExists(atPath: board.appendingPathComponent("a.png").path))
    }

    @Test func aTakenImageNameMovesNothing() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root, "source")
        _ = try write("a.json", in: root, "source settings")
        let board = root.appendingPathComponent("Board")
        _ = try write("a.png", in: board, "other")

        #expect(throws: GalleryMoveError.nameTaken("a.png")) {
            try GalleryStore.moveImageWithSidecar(image, to: board)
        }
        // The source keeps its settings, and the other image gets none.
        #expect(try text(root.appendingPathComponent("a.json")) == "source settings")
        #expect(!fm.fileExists(atPath: board.appendingPathComponent("a.json").path))
        #expect(try text(board.appendingPathComponent("a.png")) == "other")
    }

    @Test func aLeftoverSidecarAtTheDestinationMovesNothing() throws {
        defer { try? fm.removeItem(at: root) }
        let image = try write("a.png", in: root)
        let board = root.appendingPathComponent("Board")
        _ = try write("a.json", in: board, "stale")

        #expect(throws: GalleryMoveError.nameTaken("a.json")) {
            try GalleryStore.moveImageWithSidecar(image, to: board)
        }
        #expect(fm.fileExists(atPath: image.path))
        #expect(!fm.fileExists(atPath: board.appendingPathComponent("a.png").path))
    }

    // MARK: pickName(under:)

    @Test func findsAPickTheScanNeverSaw() throws {
        defer { try? fm.removeItem(at: root) }
        let board = root.appendingPathComponent("Board")
        _ = try write("plain.png", in: board)
        let pick = try write("kept.png", in: board.appendingPathComponent("nested"))
        GalleryCulling.writeFlag(.pick, path: pick.path)

        #expect(GalleryStore.pickName(under: board) == "kept.png")
    }

    @Test func aBoardWithoutPicksHasNone() throws {
        defer { try? fm.removeItem(at: root) }
        let board = root.appendingPathComponent("Board")
        _ = try write("plain.png", in: board)

        #expect(GalleryStore.pickName(under: board) == nil)
        #expect(GalleryStore.pickName(under: root.appendingPathComponent("Missing")) == nil)
    }
}
