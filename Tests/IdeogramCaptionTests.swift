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

    @Test func toJSONEscapesEveryControlCharacter() throws {
        // "\r\n" is a single Character in Swift; a per-Character escape let it through raw.
        // \u{01} and \u{1F} have no short escape and need the \uXXXX form.
        let raw = "line one\r\nline two\u{01}end\u{1F}"
        let caption = IdeogramCaption(
            highLevelDescription: raw,
            styleDescription: nil,
            compositionalDeconstruction: IdeogramCaptionComposition(background: "", elements: [])
        )
        let json = try #require(caption.toJSON())
        #expect(json.contains(#""line one\r\nline two\u0001end\u001f""#))
        #expect(!json.unicodeScalars.contains { $0.value < 0x20 })
        // And it is valid JSON that decodes back to the same text.
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["high_level_description"] as? String == raw)
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

    /// Foreign JSON can carry an empty `photo` beside an `art_style`. That is an
    /// art-style caption, so the art style survives a round trip.
    @Test func anEmptyPhotoBesideAnArtStyleKeepsTheArtStyle() throws {
        let foreign = #"{"aesthetics":"moody","photo":"","art_style":"ukiyo-e woodblock"}"#
        let style = try JSONDecoder().decode(IdeogramCaptionStyle.self, from: Data(foreign.utf8))
        let reencoded = try #require(try String(bytes: JSONEncoder().encode(style), encoding: .utf8))
        #expect(reencoded.contains(#""art_style":"ukiyo-e woodblock""#))
        // The editor's own empty camera field still means photo mode.
        #expect(IdeogramCaptionStyle(photo: "").isPhotoMode)
    }

    @Test func fromJSONRejectsGarbage() {
        #expect(IdeogramCaption.from(jsonString: "not json") == nil)
    }

    // MARK: - Lenient

    /// A stored caption with one bad element and a wrongly typed style keeps everything else.
    @Test func lenientDecodeDropsOnlyTheBadParts() throws {
        let json = """
        {"high_level_description": "a fox", "style_description": 7,
         "compositional_deconstruction": {"background": "forest", "elements": [
           {"type": "obj", "bbox": [10, 20, 300, 400], "desc": "a fox"},
           {"type": "nope", "desc": "bad"},
           {"type": "text", "text": "Hi", "desc": "sign"}
         ]}}
        """
        #expect(IdeogramCaption.from(jsonString: json) == nil)
        let caption = try JSONDecoder().decode(LenientIdeogramCaption.self, from: Data(json.utf8)).caption
        #expect(caption.highLevelDescription == "a fox")
        #expect(caption.styleDescription == nil)
        #expect(caption.compositionalDeconstruction.background == "forest")
        #expect(caption.compositionalDeconstruction.elements.map(\.desc) == ["a fox", "sign"])
    }
}

struct Ideogram4BatchSeedParseTests {
    @Test func parsesWhitespaceSeparatedSeedsAndSkipsJunk() {
        #expect(Ideogram4ParamsPanelView.parseBatchSeeds("42  137\t8001 x 9.5\n7") == [42, 137, 8001, 7])
        #expect(Ideogram4ParamsPanelView.parseBatchSeeds("   ").isEmpty)
    }
}
