@testable import MLXBits_Image_Studio
import Testing

@Suite("GemmaChatRunner")
struct GemmaChatRunnerTests {
    private let markdown = """
    # Header explainer

    ## System Prompt

    You are a writer.

    ## Example A Input

    outline one

    ## Example A Output

    prose one
    """

    @Test func extractsSections() {
        #expect(GemmaChatRunner.section("System Prompt", in: markdown) == "You are a writer.")
        #expect(GemmaChatRunner.section("Example A Input", in: markdown) == "outline one")
        #expect(GemmaChatRunner.section("Example A Output", in: markdown) == "prose one")
        #expect(GemmaChatRunner.section("Missing Heading", in: markdown).isEmpty)
    }

    @Test func replyRegionBetweenSeparators() {
        let raw = "prompt echo with content\n==========\nthe reply\n==========\nstats: 42 tok/s"
        #expect(GemmaChatRunner.replyRegion(from: raw).trimmingCharacters(in: .whitespacesAndNewlines) == "the reply")
    }

    @Test func replyRegionAfterSingleSeparator() {
        let raw = "prompt echo\n==========\nthe reply only"
        #expect(GemmaChatRunner.replyRegion(from: raw).trimmingCharacters(in: .whitespacesAndNewlines) == "the reply only")
    }

    @Test func replyRegionWholeInputWithoutSeparators() {
        let raw = "just the reply"
        #expect(GemmaChatRunner.replyRegion(from: raw) == raw)
    }

    @Test func chatPromptStructure() {
        let prompt = GemmaChatRunner.chatPrompt(
            system: "SYS",
            examples: [("IN_A", "OUT_A")],
            finalUser: "REQUEST"
        )
        #expect(prompt.hasPrefix("<start_of_turn>system\nSYS<end_of_turn>\n"))
        #expect(prompt.contains("<start_of_turn>user\nIN_A<end_of_turn>\n<start_of_turn>model\nOUT_A<end_of_turn>\n"))
        #expect(prompt.hasSuffix("<start_of_turn>user\nREQUEST<end_of_turn>\n<start_of_turn>model\n"))
    }
}

@Suite("ScenarioGenerator")
struct ScenarioGeneratorTests {
    @Test func extractReplyStripsEchoAndFences() {
        let raw = "echo\n==========\n```\nA prose prompt.\n```\n==========\nstats"
        #expect(ScenarioGenerator.extractReply(from: raw) == "A prose prompt.")
    }

    @Test func extractReplyNilWhenEmpty() {
        let raw = "echo\n==========\n   \n==========\nstats"
        #expect(ScenarioGenerator.extractReply(from: raw) == nil)
    }

    @Test func extractReplyKeepsOnlyFirstTurn() {
        // The model continues the few-shot pattern into extra turns; only the
        // first turn's text is the answer.
        let raw = """
        echo
        ==========
        A vivid prose prompt.<end_of_turn>
        <start_of_turn>user
        Outline: something else
        ==========
        stats
        """
        #expect(ScenarioGenerator.extractReply(from: raw) == "A vivid prose prompt.")
    }

    @Test func extractReplyStripsUvPreambleWithoutSeparators() {
        // mlx_vlm --no-verbose one-shot: no `==========`, so replyRegion
        // returns the whole merged output with uv's install noise on top.
        let raw = """
        Resolved 71 packages in 12ms
        Installed 70 packages in 124ms
        A woman reads by a rain-streaked window.
        """
        #expect(ScenarioGenerator.extractReply(from: raw) == "A woman reads by a rain-streaked window.")
    }

    @Test func stripToolPreambleLeavesBodyMentionsAlone() {
        // Only leading uv lines are dropped — prose that later says "Installed"
        // survives untouched.
        let text = "A neon sign reads Installed.\nResolved to stay all night."
        #expect(GemmaChatRunner.stripToolPreamble(from: text) == text)
    }

    @Test func firstTurnStripsResidualTokens() {
        #expect(GemmaChatRunner.firstTurn(of: "model\nThe answer.<end_of_turn>trailing") == "The answer.")
        #expect(GemmaChatRunner.firstTurn(of: "Plain answer, no tokens.") == "Plain answer, no tokens.")
    }

    @Test func firstTurnStripsLeakedVLMTokens() {
        // VLM templates leak pipe-bearing angle tokens mid-text (e.g. <image|>).
        #expect(GemmaChatRunner.firstTurn(of: "The room is<image|>decorated.") == "The room isdecorated.")
        #expect(GemmaChatRunner.firstTurn(of: "a <|channel>b<turn|> c") == "a b c")
    }

    @Test func userTurnPlacesCategories() {
        let turn = ScenarioGenerator.buildUserTurn(
            outline: "a quiet cafe scene",
            categories: [.clothing, .environment],
            wildcardMode: false
        )
        #expect(turn.hasPrefix("Outline: a quiet cafe scene\n"))
        let lines = turn.components(separatedBy: "\n")
        let invent = lines.first { $0.hasPrefix("Invent freely: ") } ?? ""
        let restrict = lines.first { $0.hasPrefix("Only if the outline specifies them: ") } ?? ""
        #expect(invent.contains(ScenarioCategory.clothing.instruction))
        #expect(invent.contains(ScenarioCategory.environment.instruction))
        #expect(!invent.contains(ScenarioCategory.posePosition.instruction))
        #expect(restrict.contains(ScenarioCategory.posePosition.instruction))
        #expect(restrict.contains(ScenarioCategory.participants.instruction))
        #expect(turn.hasSuffix("Output mode: a single fully-resolved prompt"))
    }

    @Test func wildcardExampleOnlyInWildcardMode() {
        let config = ScenarioPromptConfig(
            system: "sys", exampleAInput: "A_IN", exampleAOutput: "A_OUT",
            exampleBInput: "B_IN", exampleBOutput: "B_OUT"
        )
        let plain = ScenarioGenerator.fewShotExamples(config, wildcardMode: false)
        #expect(plain.count == 1)
        #expect(plain[0].input == "A_IN")
        let wild = ScenarioGenerator.fewShotExamples(config, wildcardMode: true)
        #expect(wild.count == 2)
        #expect(wild[1].input == "B_IN")
    }

    @Test func userTurnWildcardModeLine() {
        let turn = ScenarioGenerator.buildUserTurn(
            outline: "x",
            categories: Set(ScenarioCategory.allCases),
            wildcardMode: true
        )
        #expect(turn.contains("Output mode: include {option a|option b|option c} wildcard groups"))
        // Every category invented → no restriction line at all.
        #expect(!turn.contains("Only if the outline specifies them:"))
    }

    @Test func userTurnMatchesShippedExampleTemplate() {
        // The .md example inputs mirror buildUserTurn's wording — this pins
        // the coupling so a template change breaks a test, not few-shot quality.
        let turn = ScenarioGenerator.buildUserTurn(
            outline: "a woman reading in a windowsill nook on a rainy evening",
            categories: [.hairEyeColor, .clothing, .environment, .lightingCameraMood],
            wildcardMode: false
        )
        #expect(turn == """
        Outline: a woman reading in a windowsill nook on a rainy evening
        Invent freely: hair and eye color; clothing, including any discarded items in the scene; \
        environment and setting details; lighting, camera angle, and mood
        Only if the outline specifies them: number of participants and their roles; \
        body type and physical characteristics; pose and positioning, spatially grounded \
        (who is where, facing which way, limb placement)
        Output mode: a single fully-resolved prompt
        """)
    }
}
