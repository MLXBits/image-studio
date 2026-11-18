import Foundation
@testable import MLXBits_Image_Studio
import Testing

struct GalleryCullingXattrTests {
    private func tempFile() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("culling-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        return url.path
    }

    @Test func flagAndRatingRoundTrip() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(GalleryCulling.writeFlag(.pick, path: path))
        #expect(GalleryCulling.readFlag(path: path) == .pick)
        #expect(GalleryCulling.writeRating(4, path: path))
        #expect(GalleryCulling.readRating(path: path) == 4)
        #expect(GalleryCulling.writeFlag(nil, path: path))
        #expect(GalleryCulling.readFlag(path: path) == nil)
    }

    @Test func removingAbsentAttributeSucceeds() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(GalleryCulling.writeFlag(nil, path: path))
        #expect(GalleryCulling.writeRating(0, path: path))
    }

    @Test func missingFileReportsFailure() {
        let path = "/nonexistent-\(UUID().uuidString)/x.png"
        #expect(!GalleryCulling.writeFlag(.reject, path: path))
        #expect(!GalleryCulling.writeRating(3, path: path))
        #expect(!GalleryCulling.writeFlag(nil, path: path))
    }
}
