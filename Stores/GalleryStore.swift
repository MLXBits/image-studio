import AppKit
import Foundation

struct GalleryItem: Identifiable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    let id: UUID
    let path: String
    let board: String
    let modifiedAt: Date
    var thumbnailData: Data?
    var thumbnailImage: NSImage? // decoded from thumbnailData; not persisted
    var metadata: GenerationMetadata?
    var ideogram4Metadata: Ideogram4Metadata?

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var filename: String {
        url.lastPathComponent
    }
}

/// Manages the image gallery by scanning the output directory for image files.
///
/// The gallery is filesystem-driven: ``scan(outputDir:)`` enumerates the output directory and
/// updates ``items`` accordingly. Thumbnails are generated lazily on demand via
/// ``loadThumbnail(for:)``. Sidecar `.json` files are read alongside each image to populate
/// metadata shown in the gallery detail view.
@Observable
@MainActor
final class GalleryStore {
    private static let imageExtensions = Set(["png", "jpg", "jpeg", "webp"])

    var items: [GalleryItem] = []
    var boards: [String] = []
    var selectedBoard: String = "All"
    private(set) var isScanning: Bool = false
    private var scanGeneration = 0
    /// Set when a deletion fails; cleared by the next successful delete operation.
    /// Observed by ``GenerationGalleryView`` to display an alert.
    var deleteError: String?

    var displayedItems: [GalleryItem] {
        if selectedBoard == "All" { return items }
        return items.filter { $0.board == selectedBoard }
    }

    func scan(outputDir: String) {
        guard !outputDir.isEmpty else { return }
        isScanning = true
        scanGeneration += 1
        let myGeneration = scanGeneration
        let exts = Self.imageExtensions
        // Snapshot existing items so the detached task can preserve UUIDs and cached thumbnails.
        let existing = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        Task.detached(priority: .userInitiated) {
            let found = scanDirectory(outputDir, imageExtensions: exts, existing: existing)
            // Folders are first-class boards even when empty, so list subdirectories
            // directly rather than deriving boards solely from the images found.
            let folders = scanBoardFolders(outputDir)
            // Safety net for files deleted outside the app (Finder, scripts).
            ThumbnailCache.sweep(validPaths: Set(found.map(\.path)))
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == myGeneration else { return }
                self.items = found
                self.boards = Array(Set(found.map(\.board) + folders)).sorted()
                self.isScanning = false
                // Proactively load thumbnails for items new to this scan.
                for item in found where existing[item.path] == nil {
                    self.loadThumbnail(for: item)
                }
            }
        }
    }

    func loadThumbnail(for item: GalleryItem) {
        guard item.thumbnailImage == nil else { return }
        let path = item.path
        let existingData = item.thumbnailData
        Task.detached(priority: .background) {
            let thumbnailData: Data?
            if let data = existingData {
                thumbnailData = data
            } else if let cached = ThumbnailCache.read(for: path) {
                thumbnailData = cached
            } else {
                guard let generated = ThumbnailCache.makeThumbnailData(forSourcePath: path) else { return }
                ThumbnailCache.store(data: generated, for: path)
                thumbnailData = generated
            }
            let nsImage = thumbnailData.flatMap { NSImage(data: $0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let idx = self.items.firstIndex(where: { $0.path == path }) {
                    self.items[idx].thumbnailData = thumbnailData
                    self.items[idx].thumbnailImage = nsImage
                }
            }
        }
    }

    func moveItem(_ item: GalleryItem, toBoard board: String, outputDir: String) {
        let src = URL(fileURLWithPath: item.path)
        let destDir = board == "Default"
            ? URL(fileURLWithPath: outputDir)
            : URL(fileURLWithPath: outputDir).appendingPathComponent(board)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.moveItem(at: src, to: dest)
        let srcJson = MetadataSidecar.sidecarURL(for: item.path)
        if FileManager.default.fileExists(atPath: srcJson.path) {
            let destJson = destDir.appendingPathComponent(srcJson.lastPathComponent)
            try? FileManager.default.moveItem(at: srcJson, to: destJson)
        }
        // Cache is keyed by absolute path; the moved file regenerates under the new key.
        ThumbnailCache.purge(path: item.path)
        scan(outputDir: outputDir)
    }

    func delete(_ item: GalleryItem, outputDir: String) {
        do {
            try FileManager.default.removeItem(atPath: item.path)
        } catch {
            deleteError = "Could not delete \(item.filename): \(error.localizedDescription)"
        }
        try? FileManager.default.removeItem(at: MetadataSidecar.sidecarURL(for: item.path))
        ThumbnailCache.purge(path: item.path)
        scan(outputDir: outputDir)
    }

    /// Deletes a folder (board) and everything inside it — images and sidecars alike.
    /// The "Default" board maps to the output root and is never deleted.
    func deleteBoard(_ board: String, outputDir: String) {
        guard board != "Default" else { return }
        let dir = URL(fileURLWithPath: outputDir).appendingPathComponent(board)
        // Purge cache entries for every image we know lives under this board
        // before the folder goes away. The post-scan sweep then catches any we
        // didn't know about (e.g., images added externally since the last scan).
        ThumbnailCache.purge(paths: items.filter { $0.board == board }.map(\.path))
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            deleteError = "Could not delete folder \(board): \(error.localizedDescription)"
        }
        scan(outputDir: outputDir)
    }

    func renameBoard(_ oldName: String, to newName: String, outputDir: String) {
        guard oldName != "Default", !newName.trimmingCharacters(in: .whitespaces).isEmpty,
              newName != oldName else { return }
        let outputURL = URL(fileURLWithPath: outputDir)
        let oldDir = outputURL.appendingPathComponent(oldName)
        let newDir = outputURL.appendingPathComponent(newName)
        // Every image under the board changes path, so its cache key changes too.
        ThumbnailCache.purge(paths: items.filter { $0.board == oldName }.map(\.path))
        try? FileManager.default.moveItem(at: oldDir, to: newDir)
        scan(outputDir: outputDir)
    }

    func moveItems(_ items: [GalleryItem], toBoard board: String, outputDir: String) {
        var purgedPaths: [String] = []
        for item in items {
            guard item.board != board else { continue }
            let src = URL(fileURLWithPath: item.path)
            let destDir = board == "Default"
                ? URL(fileURLWithPath: outputDir)
                : URL(fileURLWithPath: outputDir).appendingPathComponent(board)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.moveItem(at: src, to: dest)
            let srcJson = MetadataSidecar.sidecarURL(for: item.path)
            if FileManager.default.fileExists(atPath: srcJson.path) {
                let destJson = destDir.appendingPathComponent(srcJson.lastPathComponent)
                try? FileManager.default.moveItem(at: srcJson, to: destJson)
            }
            purgedPaths.append(item.path)
        }
        ThumbnailCache.purge(paths: purgedPaths)
        scan(outputDir: outputDir)
    }

    func deleteItems(_ items: [GalleryItem], outputDir: String) {
        var failures: [String] = []
        for item in items {
            do {
                try FileManager.default.removeItem(atPath: item.path)
            } catch {
                failures.append(item.filename)
            }
            try? FileManager.default.removeItem(at: MetadataSidecar.sidecarURL(for: item.path))
        }
        ThumbnailCache.purge(paths: items.map(\.path))
        if !failures.isEmpty {
            deleteError = "Could not delete: \(failures.joined(separator: ", "))"
        }
        scan(outputDir: outputDir)
    }
}

// MARK: - Free function (nonisolated, safe to call from Task.detached)

nonisolated private func scanDirectory(
    _ outputDir: String,
    imageExtensions: Set<String>,
    existing: [String: GalleryItem] = [:]
) -> [GalleryItem] {
    let root = URL(fileURLWithPath: outputDir)
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var result: [GalleryItem] = []
    for case let url as URL in enumerator {
        let ext = url.pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { continue }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast

        let relativePath = String(url.path.dropFirst(root.path.count + 1))
        let components = relativePath.split(separator: "/")
        let board = components.count > 1 ? String(components[0]) : "Default"

        let prior = existing[url.path]
        let fluxMeta = MetadataSidecar.read(for: url.path)
        let ideogramMeta = fluxMeta == nil ? MetadataSidecar.readIdeogram4(for: url.path) : nil
        result.append(GalleryItem(
            id: prior?.id ?? UUID(), path: url.path, board: board,
            modifiedAt: modDate, thumbnailData: prior?.thumbnailData,
            thumbnailImage: prior?.thumbnailImage,
            metadata: fluxMeta,
            ideogram4Metadata: ideogramMeta
        ))
    }
    return result.sorted { $0.modifiedAt > $1.modifiedAt }
}

/// Lists the top-level subdirectories of the output directory. Each becomes a board,
/// so empty folders remain visible in the gallery instead of silently disappearing.
nonisolated private func scanBoardFolders(_ outputDir: String) -> [String] {
    let root = URL(fileURLWithPath: outputDir)
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return contents.compactMap { url in
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        return url.lastPathComponent
    }
}
