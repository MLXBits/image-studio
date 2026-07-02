import Foundation

/// A detail category the scenario generator may invent. `instruction` is the
/// phrase injected into the request's "Invent freely" / "Only if the outline
/// specifies them" lists — the wording is mirrored in the few-shot examples
/// inside `scenario_prompt.md`, so changes here must be reflected there.
enum ScenarioCategory: String, CaseIterable, Codable, Identifiable {
    case participants
    case hairEyeColor
    case clothing
    case environment
    case bodyType
    case posePosition
    case lightingCameraMood

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .participants: "Participants"
        case .hairEyeColor: "Hair & eyes"
        case .clothing: "Clothing"
        case .environment: "Environment"
        case .bodyType: "Body type"
        case .posePosition: "Pose / position"
        case .lightingCameraMood: "Light & camera"
        }
    }

    var instruction: String {
        switch self {
        case .participants:
            "number of participants and their roles"
        case .hairEyeColor:
            "hair and eye color"
        case .clothing:
            "clothing, including any discarded items in the scene"
        case .environment:
            "environment and setting details"
        case .bodyType:
            "body type and physical characteristics"
        case .posePosition:
            "pose and positioning, spatially grounded (who is where, facing which way, limb placement)"
        case .lightingCameraMood:
            "lighting, camera angle, and mood"
        }
    }
}

enum ScenarioGeneratorError: LocalizedError {
    case promptFileNotFound
    case uvNotFound
    case subprocessFailed(Int32, String)
    case emptyReply(String)

    var errorDescription: String? {
        switch self {
        case .promptFileNotFound:
            "scenario_prompt.md not found in app bundle"
        case .uvNotFound:
            "uv not found at ~/.local/bin/uv. Install from https://docs.astral.sh/uv/"
        case let .subprocessFailed(code, output):
            // The tail, not the head — Python tracebacks put the actual
            // exception on the last lines.
            "mlx_lm.generate failed (exit \(code)):\n…\(output.suffix(600))"
        case let .emptyReply(raw):
            "Model produced no prompt text.\n\nRaw output:\n\(raw.prefix(2000))"
        }
    }
}

// MARK: - Prompt config

/// The editable system-prompt file for the scenario generator. What the model
/// will and won't write is governed entirely by this file — users tune it in
/// Application Support (see the "Edit System Prompt…" button in the UI).
struct ScenarioPromptConfig {
    var system: String
    var exampleAInput: String
    var exampleAOutput: String
    var exampleBInput: String
    var exampleBOutput: String
}

extension ScenarioPromptConfig {
    static var userConfigURL: URL {
        AppSettings.appSupportURL.appendingPathComponent("scenario_prompt.md")
    }

    /// Copies the bundled default to Application Support if not already present.
    static func seedIfNeeded() throws {
        let dest = userConfigURL
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard let bundleURL = Bundle.main.url(forResource: "scenario_prompt", withExtension: "md") else {
            throw ScenarioGeneratorError.promptFileNotFound
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundleURL, to: dest)
    }

    static func load() throws -> Self {
        let dest = userConfigURL
        if !FileManager.default.fileExists(atPath: dest.path) {
            try seedIfNeeded()
        }
        guard let raw = try? String(contentsOf: dest, encoding: .utf8) else {
            throw ScenarioGeneratorError.promptFileNotFound
        }
        return Self(
            system: GemmaChatRunner.section("System Prompt", in: raw),
            exampleAInput: GemmaChatRunner.section("Example A Input", in: raw),
            exampleAOutput: GemmaChatRunner.section("Example A Output", in: raw),
            exampleBInput: GemmaChatRunner.section("Example B Input", in: raw),
            exampleBOutput: GemmaChatRunner.section("Example B Output", in: raw)
        )
    }
}

// MARK: - Generator

/// Expands a rough scenario outline into a full image-generation prompt via
/// local Gemma (same mlx_lm pipeline as ``IdeogramCaptionGenerator``, plain
/// text output instead of caption JSON).
@MainActor
final class ScenarioGenerator {
    /// Request lines sent as the final user turn. The template wording is
    /// mirrored in scenario_prompt.md's example inputs — keep them in sync.
    /// Exposed (non-private) for unit testing; pure, so `nonisolated`.
    nonisolated static func buildUserTurn(
        outline: String,
        categories: Set<ScenarioCategory>,
        wildcardMode: Bool
    ) -> String {
        var lines = ["Outline: \(outline)"]
        let invent = ScenarioCategory.allCases.filter { categories.contains($0) }
        let restrict = ScenarioCategory.allCases.filter { !categories.contains($0) }
        if !invent.isEmpty {
            lines.append("Invent freely: " + invent.map(\.instruction).joined(separator: "; "))
        }
        if !restrict.isEmpty {
            lines.append("Only if the outline specifies them: " + restrict.map(\.instruction).joined(separator: "; "))
        }
        lines.append(
            wildcardMode
                ? "Output mode: include {option a|option b|option c} wildcard groups on details that diversify the image"
                : "Output mode: a single fully-resolved prompt"
        )
        return lines.joined(separator: "\n")
    }

    /// Few-shot examples for the request. The wildcard example is included
    /// ONLY in wildcard mode — otherwise the model imitates its {a|b|c} groups
    /// (and its invented categories) even when the request asks for a single
    /// resolved prompt with those categories restricted.
    /// Exposed (non-private) for unit testing; pure, so `nonisolated`.
    nonisolated static func fewShotExamples(
        _ config: ScenarioPromptConfig,
        wildcardMode: Bool
    ) -> [(input: String, output: String)] {
        var examples = [(config.exampleAInput, config.exampleAOutput)]
        if wildcardMode {
            examples.append((config.exampleBInput, config.exampleBOutput))
        }
        return examples
    }

    /// The model's reply as plain prompt text: reply region between mlx_lm's
    /// separators, stray code fences stripped, trimmed. Nil when empty.
    /// Exposed (non-private) for unit testing; pure, so `nonisolated`.
    nonisolated static func extractReply(from raw: String) -> String? {
        var reply = GemmaChatRunner.replyRegion(from: raw)
        reply = reply.replacingOccurrences(of: "```", with: "")
        // mlx-vlm (and some models) continue the few-shot pattern past their
        // answer — keep only the first turn's text.
        reply = GemmaChatRunner.firstTurn(of: reply)
        return reply.isEmpty ? nil : reply
    }

    private(set) var lastLog: String = ""

    func generate(
        outline: String,
        categories: Set<ScenarioCategory>,
        wildcardMode: Bool,
        settings: AppSettings
    ) async throws -> String {
        let config = try ScenarioPromptConfig.load()
        let modelPath = settings.gemmaModelPath.isEmpty
            ? "mlx-community/gemma-3-12b-it-8bit"
            : settings.gemmaModelPath

        let fullPrompt = GemmaChatRunner.chatPrompt(
            system: config.system,
            examples: Self.fewShotExamples(config, wildcardMode: wildcardMode),
            finalUser: Self.buildUserTurn(outline: outline, categories: categories, wildcardMode: wildcardMode)
        )

        let rawOutput: String
        let exitCode: Int32
        do {
            // Hotter than the caption generator's JSON-tuned 0.3 — invention
            // benefits from temperature.
            (rawOutput, exitCode) = try await GemmaChatRunner.run(
                modelPath: modelPath, prompt: fullPrompt, maxTokens: 8192, temp: 0.7,
                environment: settings.buildEnvironment()
            )
        } catch GemmaChatRunnerError.uvNotFound {
            throw ScenarioGeneratorError.uvNotFound
        }

        lastLog = [
            "=== PROMPT ===", fullPrompt,
            "=== MODEL OUTPUT ===", rawOutput.isEmpty ? "(no output)" : rawOutput,
        ].joined(separator: "\n\n")

        guard exitCode == 0 else {
            throw ScenarioGeneratorError.subprocessFailed(exitCode, String(rawOutput.suffix(2000)))
        }
        guard let reply = Self.extractReply(from: rawOutput) else {
            throw ScenarioGeneratorError.emptyReply(rawOutput)
        }
        return reply
    }
}
