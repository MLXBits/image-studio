@testable import MLXBits_Image_Studio
import Testing

@Suite("ScenarioQueueCounts")
struct ScenarioQueueCountsTests {
    @Test func optionsLeadWithOneAndMirrorTheGenerateButton() {
        // 1 is what makes a single roll-and-queue one click; the rest mirrors the
        // main Generate button's menu so the two stay consistent.
        #expect(ScenarioQueueCounts.options(preset: 5, customCount: 42) == [1, 3, 5, 10])
    }

    @Test func optionsAppendTheCustomCountOnlyForThePresetZeroSentinel() {
        #expect(ScenarioQueueCounts.options(preset: 0, customCount: 42) == [1, 3, 5, 10, 42])
        #expect(ScenarioQueueCounts.options(preset: 10, customCount: 42) == [1, 3, 5, 10])
    }

    @Test func resolveKeepsAStoredCountThatIsStillOnOffer() {
        let options = ScenarioQueueCounts.options(preset: 0, customCount: 42)
        #expect(ScenarioQueueCounts.resolve(stored: 42, options: options) == 42)
        #expect(ScenarioQueueCounts.resolve(stored: 3, options: options) == 3)
    }

    @Test func resolveFallsBackWhenTheStoredCountLeftTheMenu() {
        // Picking custom 42, then switching the preset away, must not strand the
        // button on a count its menu can no longer produce.
        let options = ScenarioQueueCounts.options(preset: 5, customCount: 42)
        #expect(ScenarioQueueCounts.resolve(stored: 42, options: options) == 1)
    }

    @Test func resolveHandlesAnEmptyMenu() {
        #expect(ScenarioQueueCounts.resolve(stored: 7, options: []) == 1)
    }
}

@Suite("ParamsPanelState.templatedPrompts")
struct TemplatedPromptsOverrideTests {
    private var template: PromptTemplate {
        PromptTemplate(
            name: "Cinematic",
            positiveTemplate: "{prompt}, cinematic lighting",
            negativeTemplate: "cartoon",
            category: .lighting
        )
    }

    private func makeState() -> ParamsPanelState {
        let state = ParamsPanelState()
        state.model = .flux2Klein9B
        state.prompt = "typed prompt"
        state.negativePrompt = "blurry"
        return state
    }

    @Test func overrideSubstitutesTheRolledPromptForTheField() {
        let state = makeState()
        let out = state.templatedPrompts(templates: [template], overriding: "a rolled scenario")
        #expect(out.positive == "a rolled scenario, cinematic lighting")
        // The field itself is untouched — Queue never writes back to the prompt box.
        #expect(state.prompt == "typed prompt")
    }

    @Test func overrideLeavesTheNegativePromptAlone() {
        let state = makeState()
        let templated = state.templatedPrompts(templates: [template], overriding: "a rolled scenario")
        let typed = state.templatedPrompts(templates: [template])
        #expect(templated.negative == typed.negative)
    }

    @Test func omittingTheOverrideKeepsTheOldBehavior() {
        let state = makeState()
        #expect(state.templatedPrompts(templates: [template]).positive == "typed prompt, cinematic lighting")
    }

    @Test func overrideAppliesEveryActiveTemplateInOrder() {
        let state = makeState()
        let second = PromptTemplate(
            name: "Film",
            positiveTemplate: "{prompt}, 35mm film",
            category: .lighting
        )
        let out = state.templatedPrompts(templates: [template, second], overriding: "rolled")
        #expect(out.positive == "rolled, cinematic lighting, 35mm film")
    }
}
