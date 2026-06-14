import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Disk-backed thumbnail cache for the gallery.
///
/// Entries are keyed by SHA-256 of the source image's absolute path and stored as
/// JPEG under `~/Library/Caches/<bundle>/Thumbnails`. ``read(for:)`` returns the
/// cached data only when the source file has not been modified since the cache
/// entry was written; otherwise the caller regenerates via
/// ``makeThumbnailData(forSourcePath:maxPixelSize:)`` and writes back with
/// ``store(data:for:)``.
///
/// Cache lifecycle is owned by ``GalleryStore``: every delete, move, and rename
/// path must call ``purge(path:)`` / ``purge(paths:)`` so stale entries do not
/// outlive their sources. ``sweep(validPaths:)`` runs after each scan as a
/// safety net for files that disappear outside the app (e.g., via Finder).
enum ThumbnailCache {
    /// Generated thumbnails fit within this pixel size on the long edge.
    /// 400px covers @2x display at the gallery's typical 180–200pt cell width.
    nonisolated static let defaultMaxPixelSize: CGFloat = 400

    nonisolated private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "MLXBitsImageStudio"
        let dir = base.appendingPathComponent(bundleID).appendingPathComponent("Thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static func cacheURL(for sourcePath: String) -> URL {
        let digest = SHA256.hash(data: Data(sourcePath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).jpg")
    }

    /// Returns cached thumbnail data when present and at least as new as the
    /// source file. Returns `nil` if the cache is missing or stale.
    nonisolated static func read(for sourcePath: String) -> Data? {
        let url = cacheURL(for: sourcePath)
        let fm = FileManager.default
        guard let cacheAttrs = try? fm.attributesOfItem(atPath: url.path),
              let cacheDate = cacheAttrs[.modificationDate] as? Date else {
            return nil
        }
        if let srcAttrs = try? fm.attributesOfItem(atPath: sourcePath),
           let srcDate = srcAttrs[.modificationDate] as? Date,
           srcDate > cacheDate {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    nonisolated static func store(data: Data, for sourcePath: String) {
        let url = cacheURL(for: sourcePath)
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func purge(path: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: path))
    }

    nonisolated static func purge(paths: [String]) {
        for path in paths {
            purge(path: path)
        }
    }

    /// Removes any cache entry whose hash isn't present in ``validPaths``.
    /// Pairs with the in-app purge calls to catch files deleted outside the app.
    nonisolated static func sweep(validPaths: Set<String>) {
        let fm = FileManager.default
        let validNames = Set(validPaths.map { cacheURL(for: $0).lastPathComponent })
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where !validNames.contains(entry.lastPathComponent) {
            try? fm.removeItem(at: entry)
        }
    }

    /// Decodes a thumbnail straight from the source via ImageIO, which is
    /// dramatically faster than `NSImage(contentsOfFile:)` + `lockFocus` because
    /// it skips a full-resolution decode of the original.
    nonisolated static func makeThumbnailData(
        forSourcePath path: String,
        maxPixelSize: CGFloat = defaultMaxPixelSize
    ) -> Data? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}
