@testable import MLXBits_Image_Studio
import Testing

/// The culling keys the grid, the full-size viewer and Compare all read.
struct CullKeyTests {
    @Test func flagKeysInEitherCase() {
        #expect(CullKey(characters: "p", command: false) == .flag(.pick))
        #expect(CullKey(characters: "P", command: false) == .flag(.pick))
        #expect(CullKey(characters: "x", command: false) == .flag(.reject))
        #expect(CullKey(characters: "X", command: false) == .flag(.reject))
        #expect(CullKey(characters: "u", command: false) == .flag(nil))
        #expect(CullKey(characters: "U", command: false) == .flag(nil))
    }

    @Test func digitsZeroToFiveRate() {
        for stars in 0 ... 5 {
            #expect(CullKey(characters: "\(stars)", command: false) == .rating(stars))
        }
        #expect(CullKey(characters: "6", command: false) == nil)
    }

    @Test func otherKeysAreNotCullKeys() {
        #expect(CullKey(characters: "c", command: false) == nil)
        #expect(CullKey(characters: "pp", command: false) == nil)
        #expect(CullKey(characters: "", command: false) == nil)
        #expect(CullKey(characters: nil, command: false) == nil)
    }

    @Test func commandShortcutsPassThrough() {
        // ⌘X is Cut, ⌘P is Print.
        #expect(CullKey(characters: "x", command: true) == nil)
        #expect(CullKey(characters: "p", command: true) == nil)
    }
}
