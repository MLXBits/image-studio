import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    /// Which model family produced this image, used to filter the gallery to the
    /// currently selected model. Ideogram outputs are named with an "ideogram"
    /// prefix (e.g. `ideogram4_…`); everything else is treated as Flux.
    var modelFamily: ModelFamily {
        filename.lowercased().hasPrefix("ideogram") ? .ideogram4 : .flux
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
    /// Set when a metadata strip fails. Observed by ``GenerationGalleryView``.
    var stripError: String?

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

    /// Removes embedded metadata (EXIF/IPTC/XMP, including mflux's prompt and
    /// generation-parameter comments) from the image files in place. The pixel
    /// data and the app's sidecar `.json` are left untouched, so Remix / Apply
    /// Settings still work — only the shareable file is sanitized. The file's
    /// modification date is preserved so gallery ordering does not shift.
    /// Returns the number of files successfully stripped. Failures populate
    /// ``stripError`` for the caller to surface.
    @discardableResult
    func stripMetadata(from items: [GalleryItem]) -> Int {
        var failures: [String] = []
        var succeeded = 0
        for item in items {
            if stripImageMetadata(atPath: item.path) {
                succeeded += 1
            } else {
                failures.append(item.filename)
            }
        }
        stripError = failures.isEmpty
            ? nil
            : "Could not strip metadata from: \(failures.joined(separator: ", "))"
        return succeeded
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

// MARK: - Metadata stripping

/// Strips embedded metadata from an image file in place, preserving its
/// modification date. Returns `true` on success. PNGs are filtered chunk-by-chunk
/// (lossless); other formats are re-emitted via ImageIO without recompression.
nonisolated private func stripImageMetadata(atPath path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    let originalDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date

    let stripped = url.pathExtension.lowercased() == "png"
        ? stripPNGMetadata(at: url)
        : stripMetadataViaImageIO(at: url)

    if stripped, let originalDate {
        try? FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: path)
    }
    return stripped
}

/// Removes the ancillary text/metadata chunks (`tEXt`, `zTXt`, `iTXt`, `eXIf`)
/// that carry XMP, IPTC, and EXIF data. Pixel (`IDAT`) and color chunks are copied
/// verbatim, so the image is bit-for-bit identical apart from the removed metadata.
nonisolated private func stripPNGMetadata(at url: URL) -> Bool {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard let data = try? Data(contentsOf: url),
          data.count > signature.count,
          Array(data.prefix(signature.count)) == signature else { return false }

    let drop: Set = ["tEXt", "zTXt", "iTXt", "eXIf"]
    var out = Data(signature)
    var index = signature.count
    let count = data.count
    var sawMetadata = false

    while index + 12 <= count {
        let len = Int(data[index]) << 24 | Int(data[index + 1]) << 16
            | Int(data[index + 2]) << 8 | Int(data[index + 3])
        guard len >= 0, index + 12 + len <= count else { return false } // malformed — leave untouched
        let type = String(bytes: data[(index + 4) ..< (index + 8)], encoding: .ascii) ?? ""
        let chunkEnd = index + 12 + len
        if drop.contains(type) {
            sawMetadata = true
        } else {
            out.append(data[index ..< chunkEnd])
        }
        index = chunkEnd
        if type == "IEND" { break }
    }

    guard sawMetadata else { return true } // nothing to remove — succeed without a rewrite
    return (try? out.write(to: url, options: .atomic)) != nil
}

/// Strips EXIF/IPTC/GPS/XMP from non-PNG formats by copying the image source to a
/// fresh destination with those dictionaries excluded (no pixel recompression).
nonisolated private func stripMetadataViaImageIO(at url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let type = CGImageSourceGetType(source) else { return false }
    let tempURL = url.deletingLastPathComponent()
        .appendingPathComponent(".strip-\(UUID().uuidString).tmp")
    guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else { return false }

    let options: [CFString: Any] = [
        kCGImagePropertyExifDictionary: kCFNull,
        kCGImagePropertyGPSDictionary: kCFNull,
        kCGImagePropertyIPTCDictionary: kCFNull,
        kCGImageMetadataShouldExcludeXMP: kCFBooleanTrue as Any,
        kCGImageMetadataShouldExcludeGPS: kCFBooleanTrue as Any,
    ]
    let ok = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
    guard ok else {
        try? FileManager.default.removeItem(at: tempURL)
        return false
    }
    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        return true
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
        return false
    }
}
