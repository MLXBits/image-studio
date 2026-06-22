@testable import MLXBits_Image_Studio
import SwiftUI
import Testing

/// Covers the hex round-trip behind the new editable palette field — typing an
/// exact hex must parse and survive a re-encode so the same color reuses cleanly.
struct ColorHexTests {
    @Test func roundTripPreservesHex() {
        #expect(Color(hexString: "#1A2B3C")?.hexString == "#1A2B3C")
        #expect(Color(hexString: "#FFFFFF")?.hexString == "#FFFFFF")
        #expect(Color(hexString: "#000000")?.hexString == "#000000")
    }

    @Test func parsesWithoutLeadingHash() {
        #expect(Color(hexString: "808080")?.hexString == "#808080")
    }

    @Test func parseIsCaseInsensitive() {
        #expect(Color(hexString: "#abcdef")?.hexString == "#ABCDEF")
    }

    @Test func rejectsMalformedInput() {
        #expect(Color(hexString: "xyz") == nil)
        #expect(Color(hexString: "#12345") == nil) // 5 digits
        #expect(Color(hexString: "#1234567") == nil) // 7 digits
        #expect(Color(hexString: "") == nil)
    }
}
