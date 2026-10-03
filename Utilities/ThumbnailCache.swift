import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Disk-backed thumbnail cache for the gallery.
///
/// Entries are keyed by SHA-256 of the source image's absolute path and stored as
/// JPEG under `~/Library/Caches/<bundle>/Thumbnails/<profile id>/` — one folder per
/// profile, so one library's sweep never touches another's thumbnails. Every
/// call names its folder explicitly rather than reading a shared "current" one:
/// a scan or thumbnail load still running for the previous profile then writes
/// to and sweeps that profile's folder, never the new one's.
///
/// ``read(for:in:)`` returns the cached data only when the source file has not
/// been modified since the cache entry was written; otherwise the caller
/// regenerates via ``makeThumbnailData(forSourcePath:maxPixelSize:)`` and writes
/// back with ``store(data:for:in:)``.
///
/// Cache lifecycle is owned by ``GalleryStore``: every delete, move, and rename
/// path must call ``purge(path:in:)`` / ``purge(paths:in:)`` so stale entries do
/// not outlive their sources. ``sweep(validPaths:in:)`` runs after each scan as a
/// safety net for files that disappear outside the app (e.g., via Finder).
enum ThumbnailCache {
    /// Generated thumbnails fit within this pixel size on the long edge.
    /// 400px covers @2x display at the gallery's typical 180–200pt cell width.
    nonisolated static let defaultMaxPixelSize: CGFloat = 400

    /// Parent of the per-profile cache folders (see ``ProfilePaths``).
    nonisolated static let rootDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "MLXBitsImageStudio"
        return base.appendingPathComponent(bundleID).appendingPathComponent("Thumbnails", isDirectory: true)
    }()

    nonisolated static func cacheURL(for sourcePath: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(sourcePath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).jpg")
    }

    /// Returns cached thumbnail data when present and at least as new as the
    /// source file. Returns `nil` if the cache is missing or stale.
    nonisolated static func read(for sourcePath: String, in directory: URL) -> Data? {
        let url = cacheURL(for: sourcePath, in: directory)
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

    nonisolated static func store(data: Data, for sourcePath: String, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(for: sourcePath, in: directory), options: .atomic)
    }

    nonisolated static func purge(path: String, in directory: URL) {
        try? FileManager.default.removeItem(at: cacheURL(for: path, in: directory))
    }

    nonisolated static func purge(paths: [String], in directory: URL) {
        for path in paths {
            purge(path: path, in: directory)
        }
    }

    /// Removes any cache entry in `directory` whose hash isn't present in
    /// ``validPaths``. Pairs with the in-app purge calls to catch files deleted
    /// outside the app. Only `.jpg` entries are considered.
    nonisolated static func sweep(validPaths: Set<String>, in directory: URL) {
        let fm = FileManager.default
        let validNames = Set(validPaths.map { cacheURL(for: $0, in: directory).lastPathComponent })
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.pathExtension == "jpg" && !validNames.contains(entry.lastPathComponent) {
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
        guard let cgImage = makeThumbnailCGImage(forSourcePath: path, maxPixelSize: maxPixelSize) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    /// The ImageIO downscale-decode shared by ``makeThumbnailData(forSourcePath:maxPixelSize:)``
    /// and ``RunnerSupport/loadThumbnail(at:)``.
    nonisolated static func makeThumbnailCGImage(
        forSourcePath path: String,
        maxPixelSize: CGFloat = defaultMaxPixelSize
    ) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
