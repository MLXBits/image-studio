@testable import MLXBits_Image_Studio
import Testing

struct PromptTokenEstimatorTests {
    @Test func emptyIsZero() {
        #expect(PromptTokenEstimator.estimate("  \n ") == 0)
    }

    @Test func englishUsesWordAndCharacterEstimate() {
        // 6 words → 8 by words; 20 chars → 5 by chars. The larger wins.
        #expect(PromptTokenEstimator.estimate("a red fox at dawn ok") == 8)
    }

    @Test func cjkCountsOnePerCharacter() {
        // 10 kana and ideographs with no spaces: the old word count saw one "word" (≈ 1–2 tokens).
        #expect(PromptTokenEstimator.estimate("夕暮れの赤い狐が走る") == 10)
        #expect(PromptTokenEstimator.estimate("한국어문장") == 5)
    }

    @Test func mixedScriptsAddUp() {
        // 3 ideographs + "neon sign" (2 words → 3 by words, 9 chars → 3 by chars).
        #expect(PromptTokenEstimator.estimate("霓虹灯 neon sign") == 6)
    }

    @Test func denseRunsAddNoCharactersOfTheirOwn() {
        // 100 ideographs between two words: 100 + "red fox" (2 words → 3 by words, 7 chars → 2).
        let text = "red" + String(repeating: "狐", count: 100) + "fox"
        #expect(PromptTokenEstimator.estimate(text) == 103)
    }
}
