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
        let items = paths.compactMap(item(forPath:))
        guard !items.isEmpty else { return 0 }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items) ? items.count : 0
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
