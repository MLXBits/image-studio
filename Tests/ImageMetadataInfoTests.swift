import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The metadata panel's "Time" row, shared by every family's sidecar and job.
@MainActor
struct ImageMetadataInfoTests {
    private let start = Date(timeIntervalSince1970: 1000)

    @Test func elapsedIsMinutesAndSeconds() {
        #expect(ImageMetadataInfo.elapsed(from: start, to: start.addingTimeInterval(65)) == "1m 5s")
        #expect(ImageMetadataInfo.elapsed(from: start, to: start.addingTimeInterval(9.9)) == "0m 9s")
    }

    /// Sidecars from before start times were recorded have no row.
    @Test func elapsedNeedsBothEnds() {
        #expect(ImageMetadataInfo.elapsed(from: nil, to: start) == nil)
        #expect(ImageMetadataInfo.elapsed(from: start, to: nil) == nil)
    }
}
