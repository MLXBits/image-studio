import Foundation

/// One gallery file or folder moved to the Trash, with where it came from, so
/// ``GalleryTrash/restore(_:)`` can put it back. An image's settings sidecar
/// travels with it.
nonisolated struct TrashedItem: Equatable, Sendable {
    nonisolated struct File: Equatable, Sendable {
        let original: URL
        let trashed: URL
    }

    let original: URL
    let trashed: URL
    var sidecar: File?
}

/// Moves gallery images and folders to the Trash and back. The Trash call is
/// injectable so tests can stand a temp folder in for it.
nonisolated enum GalleryTrash {
    typealias Mover = (URL) throws -> URL

    /// Moves an image to the Trash, then its sidecar if it has one. When the image
    /// cannot be moved, the sidecar stays put: a kept image keeps its settings. A
    /// sidecar that fails to follow is left behind, as the old permanent delete did.
    static func trashImage(_ image: URL, using trash: Mover = systemTrash) throws -> TrashedItem {
        let trashedImage = try trash(image)
        var item = TrashedItem(original: image, trashed: trashedImage)
        let sidecar = MetadataSidecar.sidecarURL(for: image.path)
        if FileManager.default.fileExists(atPath: sidecar.path), let trashedSidecar = try? trash(sidecar) {
            item.sidecar = TrashedItem.File(original: sidecar, trashed: trashedSidecar)
        }
        return item
    }

    /// Moves a whole folder to the Trash.
    static func trashFolder(_ folder: URL, using trash: Mover = systemTrash) throws -> TrashedItem {
        try TrashedItem(original: folder, trashed: trash(folder))
    }

    /// Moves each item back to where it was, recreating its folder if needed.
    /// Returns the names that could not come back — the name is taken again, or
    /// the item is no longer in the Trash. Those stay where they are. A sidecar
    /// whose name is taken stays in the Trash; the image still comes back.
    static func restore(_ items: [TrashedItem]) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for item in items {
            guard move(item.trashed, to: item.original, fm: fm) else {
                failures.append(item.original.lastPathComponent)
                continue
            }
            if let sidecar = item.sidecar {
                _ = move(sidecar.trashed, to: sidecar.original, fm: fm)
            }
        }
        return failures
    }

    /// `FileManager.trashItem`, returning where the item landed.
    static func systemTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    private static func move(_ from: URL, to dest: URL, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: dest.path) else { return false }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: dest)
            return true
        } catch {
            return false
        }
    }
}
