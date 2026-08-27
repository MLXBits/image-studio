import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers the two pure parsing helpers that clean up Gemma's raw output. These
/// carry the most edge-case logic in the caption pipeline and run without the
/// `uv`/`mlx_lm` subprocess.
@MainActor
struct IdeogramCaptionGeneratorTests {
    private let gen = IdeogramCaptionGenerator()
    // MARK: - extractJSONString

    @Test func extractsPlainJSON() {
        #expect(gen.extractJSONString(from: "{\"a\":1}") == "{\"a\":1}")
    }

    @Test func stripsMarkdownFences() {
        let raw = "```json\n{\"a\":1}\n```"
        #expect(gen.extractJSONString(from: raw) == "{\"a\":1}")
    }

    @Test func ignoresBracesInsideStrings() {
        let raw = "{\"desc\":\"a } weird { value\"}"
        #expect(gen.extractJSONString(from: raw) == raw)
    }

    @Test func picksModelReplyBetweenSeparators() throws {
        // mlx_lm echoes the prompt (with example JSON) before the first separator,
        // the reply between separators, and stats after the last.
        let raw = """
        {"example":1}
        ==========
        {"real":2}
        ==========
        Prompt: 5 tokens
        """
        let extracted = try #require(gen.extractJSONString(from: raw))
        #expect(extracted.contains("\"real\""))
        #expect(!extracted.contains("\"example\""))
    }

    @Test func returnsNilWhenNoJSON() {
        #expect(gen.extractJSONString(from: "no braces at all") == nil)
    }

    // MARK: - sanitizeJSON

    @Test func normalizesCompositionalKeyVariants() {
        #expect(gen.sanitizeJSON("{\"compositional_breakdown\":{}}")
            == "{\"compositional_deconstruction\":{}}")
        #expect(gen.sanitizeJSON("{\"compositional_analysis\":{}}")
            == "{\"compositional_deconstruction\":{}}")
    }

    @Test func fillsLeadingEmptyArraySlot() {
        #expect(gen.sanitizeJSON("[,100,200,300]") == "[0,100,200,300]")
    }

    @Test func fillsMiddleEmptyArraySlots() {
        #expect(gen.sanitizeJSON("[1,,3]") == "[1, 0,3]")
    }

    @Test func fillsTrailingEmptyArraySlot() {
        #expect(gen.sanitizeJSON("[1,2,]") == "[1,2, 0]")
    }

    // MARK: - truncated repair

    @Test func truncationMidValueString() {
        let raw = #"{"prompt":"a cat sitting","tail":"he"#
        #expect(gen.extractJSONString(from: raw) == #"{"prompt":"a cat sitting"}"#)
    }

    @Test func truncationMidKeyString() {
        let raw = #"{"a":"v","b"#
        #expect(gen.extractJSONString(from: raw) == #"{"a":"v"}"#)
    }

    @Test func truncationAfterCompleteNestedValues() {
        let raw = #"{"a":{"b":1,"c":[1,2]"#
        #expect(gen.extractJSONString(from: raw) == #"{"a":{"b":1,"c":[1,2]}}"#)
    }

    @Test func truncationDanglingKeyNoColon() {
        let raw = #"{"prompt":"x","compositional_deconstruction""#
        #expect(gen.extractJSONString(from: raw) == #"{"prompt":"x"}"#)
    }

    @Test func truncationClippedScalarValue() {
        let raw = #"{"a":{"b":12"#
        #expect(gen.extractJSONString(from: raw) == #"{"a":{"b":12}}"#)
    }

    @Test func truncationTrailingCommaWhitespace() {
        let raw = """
        {"prompt":"x", \n
        """
        #expect(gen.extractJSONString(from: raw) == #"{"prompt":"x"}"#)
    }
}
