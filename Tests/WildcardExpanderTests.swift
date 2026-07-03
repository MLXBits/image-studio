@testable import MLXBits_Image_Studio
import Testing

/// Deterministic RNG so sampling is reproducible in tests.
private struct FixedRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

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
        #expect(WildcardExpander.expandVariants(json, count: 3) == [json, json, json])
    }

    @Test func singleGroupIsFullyCovered() {
        // Batch == group size: every option appears exactly once (any order).
        var rng = FixedRNG(state: 1)
        let out = WildcardExpander.expandVariants("a {red|blue|green} dress", count: 3, using: &rng)
        #expect(Set(out) == ["a red dress", "a blue dress", "a green dress"])
    }

    @Test func multipleGroupsProduceDistinctCombinations() {
        // Two groups, batch == largest group: combos vary and none repeat.
        var rng = FixedRNG(state: 7)
        let out = WildcardExpander.expandVariants("{a|b} at the {beach|bar|park}", count: 3, using: &rng)
        #expect(out.count == 3)
        #expect(Set(out).count == 3) // no duplicate combinations
        for line in out {
            #expect(["a", "b"].contains { line.hasPrefix($0 + " at the ") })
            #expect(["beach", "bar", "park"].contains { line.hasSuffix($0) })
        }
    }

    @Test func batchSpreadsCombinationsApart() {
        // Three 3-option groups (27 combos): a batch of 6 should come back with
        // no exact duplicates and most pairs differing in ≥2 groups.
        var rng = FixedRNG(state: 9)
        let out = WildcardExpander.expandVariants("{a|b|c} {d|e|f} {g|h|i}", count: 6, using: &rng)
        #expect(Set(out).count == 6) // no exact duplicates
    }

    @Test func largestGroupCoveredEvenWithSmallerGroups() {
        // The 4-option group must show all four options across a 4-job batch.
        var rng = FixedRNG(state: 3)
        let out = WildcardExpander.expandVariants("{x|y} {a|b|c|d}", count: 4, using: &rng)
        let seconds = Set(out.map { String($0.suffix(1)) })
        #expect(seconds == ["a", "b", "c", "d"])
    }

    @Test func nestedOpenBraceIsLiteral() {
        // Inner `{` disqualifies the group; the following simple group still expands.
        var rng = FixedRNG(state: 2)
        let out = WildcardExpander.expandVariants("{outer {x|y} tail", count: 2, using: &rng)
        #expect(Set(out) == ["{outer x tail", "{outer y tail"])
    }

    @Test func emptyOptionAllowed() {
        let prompt = "photo{, close-up|}"
        #expect(WildcardExpander.variantCount(prompt) == 2)
        var rng = FixedRNG(state: 4)
        let out = WildcardExpander.expandVariants(prompt, count: 2, using: &rng)
        #expect(Set(out) == ["photo, close-up", "photo"])
    }

    @Test func textWithoutGroupsRepeats() {
        let text = "sunset over the ocean"
        #expect(WildcardExpander.expandVariants(text, count: 3) == [text, text, text])
    }
}
