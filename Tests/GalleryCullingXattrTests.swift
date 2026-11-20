import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Flags and star ratings stored as extended attributes on the image file.
struct GalleryCullingXattrTests {
    private func tempFile() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("culling-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        return url.path
    }

    /// Writes an attribute the way another tool (or an older build) might.
    private func plant(_ value: String, as name: String, on path: String) {
        let data = Data(value.utf8)
        let result = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        #expect(result == 0)
    }

    private func hasAttribute(_ name: String, _ path: String) -> Bool {
        getxattr(path, name, nil, 0, 0, 0) >= 0
    }

    /// The stored value, read without `GalleryCulling`'s own clamping.
    private func rawAttribute(_ name: String, _ path: String) -> String? {
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length >= 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, 0) }
        return read >= 0 ? String(data: data.prefix(read), encoding: .utf8) : nil
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

    @Test func ratingsOutsideOneToFiveAreClampedOnWrite() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Checked on the stored value too: readRating clamps as well, and would hide a bad write.
        #expect(GalleryCulling.writeRating(9, path: path))
        #expect(rawAttribute(GalleryCulling.ratingAttr, path) == "5")
        #expect(GalleryCulling.readRating(path: path) == 5)
        #expect(GalleryCulling.writeRating(-2, path: path))
        #expect(!hasAttribute(GalleryCulling.ratingAttr, path))
        #expect(GalleryCulling.readRating(path: path) == 0)
    }

    /// Zero stars is no attribute at all, not a stored "0".
    @Test func zeroStarsRemovesTheAttribute() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        GalleryCulling.writeRating(3, path: path)
        #expect(hasAttribute(GalleryCulling.ratingAttr, path))
        GalleryCulling.writeRating(0, path: path)
        #expect(!hasAttribute(GalleryCulling.ratingAttr, path))
    }

    @Test func foreignValuesReadSafely() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        plant("42", as: GalleryCulling.ratingAttr, on: path)
        #expect(GalleryCulling.readRating(path: path) == 5)
        plant("lots", as: GalleryCulling.ratingAttr, on: path)
        #expect(GalleryCulling.readRating(path: path) == 0)
        plant("maybe", as: GalleryCulling.flagAttr, on: path)
        #expect(GalleryCulling.readFlag(path: path) == nil)
        plant("", as: GalleryCulling.flagAttr, on: path)
        #expect(GalleryCulling.readFlag(path: path) == nil)
    }

    /// The gallery sorts by modification date, so culling must not change it.
    @Test func cullingLeavesTheModificationDateAlone() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)

        GalleryCulling.writeFlag(.pick, path: path)
        GalleryCulling.writeRating(4, path: path)
        GalleryCulling.writeFlag(nil, path: path)

        let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(modified == past)
    }

    /// Moving an image to another board keeps its flag and rating.
    @Test func cullingTravelsWithAMovedFile() throws {
        let path = try tempFile()
        let moved = path + ".moved.png"
        defer { try? FileManager.default.removeItem(atPath: moved) }
        GalleryCulling.writeFlag(.reject, path: path)
        GalleryCulling.writeRating(2, path: path)

        try FileManager.default.moveItem(atPath: path, toPath: moved)

        #expect(GalleryCulling.readFlag(path: moved) == .reject)
        #expect(GalleryCulling.readRating(path: moved) == 2)
    }
}
