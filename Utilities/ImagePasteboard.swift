import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Copies library images to a pasteboard, one pasteboard item per image.
///
/// Each item carries the image's file URL and its pixels. File-aware apps (Finder,
/// Mail, Messages, chat apps) take every item as a file, so a multi-selection
/// pastes in full. Image editors (Preview, Photoshop) paste only one image from
/// the pasteboard whatever is on it; the pixels let them take the first instead
/// of nothing.
enum ImagePasteboard {
    /// Replaces the pasteboard's contents with the images at `paths`, in order.
    /// Paths that cannot be read as images are skipped; when none can be, the
    /// pasteboard is left as it was. Returns the number of images written, or 0
    /// when the pasteboard refuses them.
    @discardableResult
    static func copyImages(atPaths paths: [String], to pasteboard: NSPasteboard = .general) -> Int {
        let items = paths.compactMap { item(forPath: $0) }
        guard !items.isEmpty else { return 0 }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items) ? items.count : 0
    }

    /// The image on `pasteboard` as a path: an image file's own path (extension in
    /// `extensions`), else raw image data saved to a temp PNG named with `tempPrefix`.
    /// `nil` when it holds no image. Throws when the temp PNG can't be written, so
    /// the caller can say so rather than keep a path to a missing file.
    static func pastedImagePath(
        tempPrefix: String, extensions: Set<String>, from pasteboard: NSPasteboard = .general
    ) throws -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { extensions.contains($0.pathExtension.lowercased()) }) {
            return url.path
        }
        guard let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tempPrefix)-\(Int(Date().timeIntervalSince1970)).png")
        try png.write(to: tmp)
        return tmp.path
    }

    private static func item(forPath path: String) -> NSPasteboardItem? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return nil }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        // The type comes from the file's header, not its extension, so a
        // mislabelled file is declared as what it is.
        if type.conforms(to: .png) || type.conforms(to: .jpeg) {
            // Every image-pasting app reads PNG and JPEG, so the file's own bytes
            // go on as-is, with no decode.
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        } else if let tiff = NSImage(data: data)?.tiffRepresentation {
            // WebP and other formats many apps can't read: re-encode as TIFF, the
            // type `NSImage` itself writes to the pasteboard.
            item.setData(tiff, forType: .tiff)
        } else {
            return nil
        }
        return item
    }
}
