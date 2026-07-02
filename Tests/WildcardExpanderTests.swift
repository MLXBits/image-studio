@testable import MLXBits_Image_Studio
import Testing

@Suite("WildcardExpander")
struct WildcardExpanderTests {
    @Test func detectsWildcardGroups() {
        #expect(WildcardExpander.containsWildcards("a {red|blue} dress"))
        #expect(WildcardExpander.containsWildcards("{a|b}{c|d}"))
        #expect(!WildcardExpander.containsWildcards("no wildcards here"))
        #expect(!WildcardExpander.containsWildcards("plain {braces} only"))
        #expect(!WildcardExpander.containsWildcards("unclosed {red|blue dress"))
    }

    @Test func variantCountIsLargestGroup() {
        #expect(WildcardExpander.variantCount("no groups") == 1)
        #expect(WildcardExpander.variantCount("a {red|blue} dress") == 2)
        #expect(WildcardExpander.variantCount("{a|b} at the {beach|bar|park}") == 3)
        #expect(WildcardExpander.variantCount("plain {braces} only") == 1)
    }

    @Test func jsonLikeBracesPassThrough() {
        let json = "{\"scene\": \"a bar\", \"style\": {\"mood\": \"warm\"}}"
        #expect(!WildcardExpander.containsWildcards(json))
        #expect(WildcardExpander.expandVariant(json, index: 0) == json)
    }

    @Test func variantsWalkOptionsInOrder() {
        let prompt = "a {red|blue|green} dress"
        #expect(WildcardExpander.expandVariant(prompt, index: 0) == "a red dress")
        #expect(WildcardExpander.expandVariant(prompt, index: 1) == "a blue dress")
        #expect(WildcardExpander.expandVariant(prompt, index: 2) == "a green dress")
    }

    @Test func smallerGroupsCycle() {
        let prompt = "{a|b} at the {beach|bar|park}"
        #expect(WildcardExpander.expandVariant(prompt, index: 0) == "a at the beach")
        #expect(WildcardExpander.expandVariant(prompt, index: 1) == "b at the bar")
        #expect(WildcardExpander.expandVariant(prompt, index: 2) == "a at the park")
        // An explicit batch count larger than every group keeps cycling.
        #expect(WildcardExpander.expandVariant(prompt, index: 3) == "b at the beach")
    }

    @Test func nestedOpenBraceIsLiteral() {
        // Inner `{` disqualifies the group; the following simple group still expands.
        #expect(WildcardExpander.expandVariant("{outer {x|y} tail", index: 0) == "{outer x tail")
        #expect(WildcardExpander.expandVariant("{outer {x|y} tail", index: 1) == "{outer y tail")
    }

    @Test func emptyOptionAllowed() {
        let prompt = "photo{, close-up|}"
        #expect(WildcardExpander.variantCount(prompt) == 2)
        #expect(WildcardExpander.expandVariant(prompt, index: 0) == "photo, close-up")
        #expect(WildcardExpander.expandVariant(prompt, index: 1) == "photo")
    }

    @Test func textWithoutGroupsIsUnchanged() {
        let text = "sunset over the ocean"
        #expect(WildcardExpander.expandVariant(text, index: 5) == text)
    }
}
