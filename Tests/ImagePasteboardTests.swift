import AppKit
@testable import MLXBits_Image_Studio
import Testing

/// Library ▸ Copy Image / ⌘C: one pasteboard item per selected image, each with
/// the file URL and the pixels. Uses a private pasteboard, never the general one.
struct ImagePasteboardTests {
    /// A 1×1 lossy WebP.
    private static let webp = Data(base64Encoded: "UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA=")

    private let root = FakeRuntime.tempDirectory("ImagePasteboardTests")
    private let pasteboard = NSPasteboard(name: .init("ImagePasteboardTests-\(UUID().uuidString)"))

    private func file(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A real 1×1 image in `format`.
    private func image(_ format: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: format, properties: [:]))
    }

    @Test func everyImageBecomesOneItemWithItsFileAndBytes() throws {
        let pngBytes = try image(.png)
        let jpegBytes = try image(.jpeg)
        let png = try file("a.png", pngBytes)
        let jpeg = try file("b.jpg", jpegBytes)

        #expect(ImagePasteboard.copyImages(atPaths: [png.path, jpeg.path], to: pasteboard) == 2)

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(items.map { $0.string(forType: .fileURL) } == [png.absoluteString, jpeg.absoluteString])
        #expect(items[0].data(forType: .png) == pngBytes)
        #expect(items[1].data(forType: .init("public.jpeg")) == jpegBytes)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls == [png, jpeg])
    }

    /// The pasteboard type comes from the file's contents, not its extension.
    @Test func aMislabelledFileIsDeclaredAsWhatItIs() throws {
        let jpegBytes = try image(.jpeg)
        let named = try file("really-a-jpeg.png", jpegBytes)

        #expect(ImagePasteboard.copyImages(atPaths: [named.path], to: pasteboard) == 1)

        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.data(forType: .init("public.jpeg")) == jpegBytes)
        #expect(item.data(forType: .png) == nil)
    }

    @Test func webpIsReencodedAsTIFF() throws {
        let webp = try file("c.webp", #require(Self.webp))

        #expect(ImagePasteboard.copyImages(atPaths: [webp.path], to: pasteboard) == 1)

        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.string(forType: .fileURL) == webp.absoluteString)
        #expect(item.data(forType: .init("org.webmproject.webp")) == nil)
        let tiff = try #require(item.data(forType: .tiff))
        #expect(NSBitmapImageRep(data: tiff)?.pixelsWide == 1)
    }

    @Test func unreadableImagesAreSkipped() throws {
        let png = try file("a.png", image(.png))
        let missing = root.appendingPathComponent("gone.png").path
        let corruptPNG = try file("d.png", Data("not-an-image".utf8))
        let corruptWebP = try file("e.webp", Data("not-an-image".utf8))

        let paths = [missing, png.path, corruptPNG.path, corruptWebP.path]
        #expect(ImagePasteboard.copyImages(atPaths: paths, to: pasteboard) == 1)
        #expect(pasteboard.pasteboardItems?.map { $0.string(forType: .fileURL) } == [png.absoluteString])
    }

    @Test func nothingReadableLeavesThePasteboardAlone() throws {
        let corrupt = try file("d.png", Data("not-an-image".utf8))
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        #expect(ImagePasteboard.copyImages(atPaths: [corrupt.path], to: pasteboard) == 0)
        #expect(pasteboard.string(forType: .string) == "before")
    }
}
