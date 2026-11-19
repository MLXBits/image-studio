import AppKit
@testable import MLXBits_Image_Studio
import Testing

@Suite("Gallery drag payload")
struct GalleryDragPayloadTests {
    @Test func carriesTheImageAsAFileURL() throws {
        let item = GalleryDragPayload.item(for: "/Users/me/Pictures/Board/a.png")
        let raw = try #require(item.string(forType: .fileURL))
        #expect(URL(string: raw)?.isFileURL == true)
        // No plain-text copy: apps that read text first would paste the path, not the image.
        #expect(item.string(forType: .string) == nil)
    }

    @Test func pathRoundTripsThroughSpacesAndUnicode() {
        let path = "/Users/me/My Images/Fête board/café 01.png"
        #expect(GalleryDragPayload.path(from: GalleryDragPayload.item(for: path)) == path)
    }

    @Test func anItemWithoutAFileURLHasNoPath() {
        let item = NSPasteboardItem()
        item.setString("/just/text.png", forType: .string)
        #expect(GalleryDragPayload.path(from: item) == nil)
    }
}
