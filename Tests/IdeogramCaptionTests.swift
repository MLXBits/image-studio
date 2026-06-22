import Foundation
@testable import MLXBits_Image_Studio
import Testing

struct IdeogramCaptionTests {
    // MARK: - isBBoxValid

    @Test func bboxValidityRules() {
        #expect(IdeogramCaptionElement(type: .obj, bbox: [100, 100, 400, 400], desc: "x").isBBoxValid)
        #expect(!IdeogramCaptionElement(type: .obj, bbox: [], desc: "x").isBBoxValid)
        #expect(!IdeogramCaptionElement(type: .obj, bbox: [400, 100, 100, 400], desc: "x").isBBoxValid) // y2<=y1
        #expect(!IdeogramCaptionElement(type: .obj, bbox: [0, 0, 1001, 400], desc: "x").isBBoxValid) // out of range
    }

    // MARK: - toJSON key ordering & omission

    @Test func toJSONOrdersKeysAndOmitsInvalidBBox() throws {
        let caption = IdeogramCaption(
            highLevelDescription: "a cat on a mat",
            styleDescription: nil,
            compositionalDeconstruction: IdeogramCaptionComposition(
                background: "plain",
                elements: [IdeogramCaptionElement(type: .obj, bbox: [100, 100, 400, 400], desc: "a cat")]
            )
        )
        let json = try #require(caption.toJSON())
        // Root key order: high_level_description before compositional_deconstruction.
        let hld = try #require(json.range(of: "high_level_description"))
        let cd = try #require(json.range(of: "compositional_deconstruction"))
        #expect(hld.lowerBound < cd.lowerBound)
        // No style block emitted when nil.
        #expect(!json.contains("style_description"))
        // Element key order: type before bbox before desc.
        let t = try #require(json.range(of: "\"type\""))
        let b = try #require(json.range(of: "\"bbox\""))
        let d = try #require(json.range(of: "\"desc\""))
        #expect(t.lowerBound < b.lowerBound)
        #expect(b.lowerBound < d.lowerBound)
    }

    @Test func toJSONOmitsInvalidBBoxAndEmptyText() throws {
        let caption = IdeogramCaption(
            highLevelDescription: "scene",
            styleDescription: nil,
            compositionalDeconstruction: IdeogramCaptionComposition(
                background: "",
                elements: [IdeogramCaptionElement(type: .text, bbox: [], text: "", desc: "label")]
            )
        )
        let json = try #require(caption.toJSON())
        #expect(!json.contains("\"bbox\":")) // empty bbox omitted
        #expect(!json.contains("\"text\":")) // empty text omitted (key, not the "text" type value)
        #expect(json.contains("\"desc\":\"label\""))
    }

    // MARK: - from(jsonString:)

    @Test func parsesRoundTrippedJSON() throws {
        let original = IdeogramCaption(
            highLevelDescription: "a fox",
            styleDescription: nil,
            compositionalDeconstruction: IdeogramCaptionComposition(
                background: "forest",
                elements: [IdeogramCaptionElement(type: .obj, bbox: [10, 20, 300, 400], desc: "a fox")]
            )
        )
        let json = try #require(original.toJSON())
        let parsed = try #require(IdeogramCaption.from(jsonString: json))
        #expect(parsed.highLevelDescription == "a fox")
        #expect(parsed.compositionalDeconstruction.background == "forest")
        #expect(parsed.compositionalDeconstruction.elements.count == 1)
        #expect(parsed.compositionalDeconstruction.elements[0].bbox == [10, 20, 300, 400])
        #expect(parsed.compositionalDeconstruction.elements[0].desc == "a fox")
    }

    @Test func fromJSONRejectsGarbage() {
        #expect(IdeogramCaption.from(jsonString: "not json") == nil)
    }
}
