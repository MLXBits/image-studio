import AppKit

/// What a gallery drag carries: the image as a file URL. Finder copies the file,
/// apps that take images attach it, and the app's own image wells and boards
/// read the same URL back. A bare path string would arrive as text instead.
enum GalleryDragPayload {
    static func item(for path: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return item
    }

    /// The dragged image's path, or nil when the item carries no file URL.
    static func path(from item: NSPasteboardItem) -> String? {
        guard let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL else {
            return nil
        }
        return url.path
    }
}
