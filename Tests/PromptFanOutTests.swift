@testable import MLXBits_Image_Studio
import Testing

/// How one Generate press becomes jobs for Flux, Krea 2, Z-Image and Qwen-Image 2.1.
struct PromptFanOutTests {
    private var rng = SystemRandomNumberGenerator()

    private mutating func jobs(
        _ prompt: String,
        negative: String = "",
        scenario: [String]? = nil,
        count: Int = 1
    ) -> [PromptFanOut.Job] {
        PromptFanOut.jobs(prompt: prompt, scenarioPrompts: scenario, count: count, resolve: { ($0, negative) }, using: &rng)
    }

    // MARK: - The prompt field

    @Test mutating func aPlainPromptIsOneJobOfTheBatchCount() {
        let result = jobs("a heron", negative: "blurry", count: 4)
        #expect(result == [PromptFanOut.Job(positive: "a heron", negative: "blurry", ratio: nil, count: 4)])
    }

    @Test mutating func anAspectDirectiveSetsTheRatioAndLeavesThePrompt() {
        let result = jobs("@aspect 3:2\na heron")
        #expect(result.count == 1)
        #expect(result.first?.positive == "a heron")
        #expect(result.first?.ratio == 1.5)
    }

    @Test mutating func aWildcardGroupFansOutOneJobPerOption() {
        let result = jobs("a {red|green|blue} kite", count: 1)
        #expect(Set(result.map(\.positive)) == ["a red kite", "a green kite", "a blue kite"])
        #expect(result.allSatisfy { $0.count == 1 })
    }

    @Test mutating func aBatchCountOverridesTheOptionCount() {
        let result = jobs("a {red|blue} kite", count: 5)
        #expect(result.count == 5)
        #expect(result.allSatisfy { $0.count == 1 && !$0.positive.contains("{") })
    }

    @Test mutating func fanOutStopsAtTenJobs() {
        let options = (1 ... 12).map(String.init).joined(separator: "|")
        #expect(jobs("kite {\(options)}").count == PromptFanOut.maxVariants)
    }

    @Test mutating func theNegativeFansOutAlongsideThePrompt() {
        let result = jobs("a {red|blue} kite", negative: "{fog|rain}")
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.negative == "fog" || $0.negative == "rain" })
    }

    @Test mutating func aWildcardInTheResolvedPromptFansOutToo() {
        // Flux's templates can add a group the field itself does not have.
        let result = PromptFanOut.jobs(
            prompt: "a kite", scenarioPrompts: nil, count: 1,
            resolve: { ("\($0), {dawn|dusk}", "") }, using: &rng
        )
        #expect(Set(result.map(\.positive)) == ["a kite, dawn", "a kite, dusk"])
    }

    @Test mutating func aSingleJobCollapsesAStrayGroupInTheNegative() {
        let result = jobs("a kite", negative: "{fog|rain}", count: 3)
        #expect(result.count == 1 && result.first?.count == 3)
        #expect(result.first?.negative == "fog" || result.first?.negative == "rain")
    }

    // MARK: - Scenario batches

    @Test mutating func aScenarioBatchIsOneSingleImageJobPerPrompt() {
        let result = jobs("ignored {a|b|c}", scenario: ["a heron", "@aspect 2:3\na fox"], count: 9)
        #expect(result.map(\.positive) == ["a heron", "a fox"])
        #expect(result.map(\.ratio) == [nil, 2.0 / 3.0])
        #expect(result.allSatisfy { $0.count == 1 })
    }

    @Test mutating func aScenarioPromptsGroupIsCollapsedNotFannedOut() {
        let result = jobs("", scenario: ["a {red|blue} kite"])
        #expect(result.count == 1)
        #expect(result.first?.positive == "a red kite" || result.first?.positive == "a blue kite")
    }

    @Test mutating func anEmptyScenarioListFallsBackToTheField() {
        #expect(jobs("a heron", scenario: []).map(\.positive) == ["a heron"])
    }
}
