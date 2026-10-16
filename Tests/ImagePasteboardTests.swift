import AppKit
@testable import MLXBits_Image_Studio
import Testing

/// Library ▸ Copy Image / ⌘C: one pasteboard item per selected image, each with
/// the file URL and the pixels. Uses a private pasteboard, never the general one.
struct ImagePasteboardTests {
    private let root = FakeRuntime.tempDirectory("ImagePasteboardTests")
    private let pasteboard = NSPasteboard(name: .init("ImagePasteboardTests-\(UUID().uuidString)"))

    private func file(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A real 1×1 PNG, for the paths that decode the image.
    private func pngData() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func everyImageBecomesOneItemWithItsFileAndBytes() throws {
        let png = try file("a.png", Data("png-bytes".utf8))
        let jpeg = try file("b.jpg", Data("jpeg-bytes".utf8))

        #expect(ImagePasteboard.copyImages(atPaths: [png.path, jpeg.path], to: pasteboard) == 2)

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(items.map { $0.string(forType: .fileURL) } == [png.absoluteString, jpeg.absoluteString])
        #expect(items[0].data(forType: .png) == Data("png-bytes".utf8))
        #expect(items[1].data(forType: .init("public.jpeg")) == Data("jpeg-bytes".utf8))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls == [png, jpeg])
    }

    @Test func webpIsReencodedAsTIFF() throws {
        let webp = try file("c.webp", pngData())

        #expect(ImagePasteboard.copyImages(atPaths: [webp.path], to: pasteboard) == 1)

        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.string(forType: .fileURL) == webp.absoluteString)
        #expect(item.data(forType: .tiff) != nil)
        #expect(item.data(forType: .init("org.webmproject.webp")) == nil)
    }

    @Test func unreadableImagesAreSkipped() throws {
        let png = try file("a.png", Data("png-bytes".utf8))
        let missing = root.appendingPathComponent("gone.png").path
        let undecodable = try file("d.webp", Data("not-an-image".utf8))

        #expect(ImagePasteboard.copyImages(atPaths: [missing, png.path, undecodable.path], to: pasteboard) == 1)
        #expect(pasteboard.pasteboardItems?.map { $0.string(forType: .fileURL) } == [png.absoluteString])
    }

    @Test func nothingReadableLeavesThePasteboardAlone() {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        #expect(ImagePasteboard.copyImages(atPaths: [root.appendingPathComponent("gone.png").path], to: pasteboard) == 0)
        #expect(pasteboard.string(forType: .string) == "before")
    }
}
