import Foundation

enum IdeogramCaptionGeneratorError: LocalizedError {
    case promptFileNotFound
    case uvNotFound
    case subprocessFailed(Int32, String)
    /// No { } block was found in the model output at all.
    case noJSONFound(String)
    /// A { } block was found but JSONDecoder rejected it.
    case decodeFailed(json: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .promptFileNotFound:
            "ideogram_caption_prompt.md not found in app bundle"
        case .uvNotFound:
            "uv not found at ~/.local/bin/uv. Install from https://docs.astral.sh/uv/"
        case let .subprocessFailed(code, output):
            // The tail, not the head — Python tracebacks put the actual
            // exception on the last lines.
            "mlx_lm.generate failed (exit \(code)):\n…\(output.suffix(600))"
        case let .noJSONFound(raw):
            "Model output contained no JSON object.\n\nRaw output:\n\(raw.prefix(2000))"
        case let .decodeFailed(json, reason):
            "JSON decode failed: \(reason)\n\nExtracted JSON:\n\(json.prefix(2000))"
        }
    }
}

// MARK: - Prompt config

struct IdeogramPromptConfig {
    var system: String
    var exampleAInput: String
    var exampleAOutput: String
    var exampleBInput: String
    var exampleBOutput: String
}

extension IdeogramPromptConfig {
    static var userConfigURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("MLXBits Image Studio", isDirectory: true)
            .appendingPathComponent("ideogram_caption_prompt.md")
    }

    /// Copies the bundled default to Application Support if not already present.
    /// Called at app launch so the file is ready to edit before first use.
    static func seedIfNeeded() throws {
        let dest = userConfigURL
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard let bundleURL = Bundle.main.url(forResource: "ideogram_caption_prompt", withExtension: "md") else {
            throw IdeogramCaptionGeneratorError.promptFileNotFound
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundleURL, to: dest)
    }

    /// Parses the markdown file by splitting on `## Heading` markers.
    /// Reads from ~/Library/Application Support/MLXBits Image Studio/ideogram_caption_prompt.md.
    static func load() throws -> Self {
        let dest = userConfigURL
        if !FileManager.default.fileExists(atPath: dest.path) {
            try seedIfNeeded()
        }
        guard let raw = try? String(contentsOf: dest, encoding: .utf8) else {
            throw IdeogramCaptionGeneratorError.promptFileNotFound
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

@MainActor
final class IdeogramCaptionGenerator {
    private(set) var lastLog: String = ""

    // MARK: - Public

    func generate(from description: String, settings: AppSettings) async throws -> IdeogramCaption {
        let config = try IdeogramPromptConfig.load()
        let examples = [
            (config.exampleAInput, config.exampleAOutput),
            (config.exampleBInput, config.exampleBOutput),
        ]
        let finalUser = "Description to convert: \"\(description)\""

        // The raw model text comes from whichever backend is selected; the JSON
        // extraction/decode below is shared (extractJSONString tolerates fenced
        // or loose JSON, so it is the safety net regardless of response_format).
        let rawOutput: String
        if settings.llmBackend == .remote {
            rawOutput = try await OpenAIChatClient.chat(OpenAIChatCall(
                system: config.system, examples: examples, finalUser: finalUser,
                model: settings.openAIModel, maxTokens: 8192, temp: settings.openAITemperature,
                topP: settings.openAITopP, topK: settings.openAITopK, jsonMode: true,
                baseURL: settings.openAIBaseURL, apiKey: settings.openAIAPIKey
            ))
            lastLog = [
                "=== MESSAGES ===", finalUser,
                "=== MODEL OUTPUT (remote) ===", rawOutput.isEmpty ? "(no output)" : rawOutput,
            ].joined(separator: "\n\n")
        } else {
            let modelPath = settings.gemmaModelPath.isEmpty
                ? "mlx-community/gemma-3-12b-it-8bit"
                : settings.gemmaModelPath
            let fullPrompt = GemmaChatRunner.chatPrompt(
                system: config.system, examples: examples, finalUser: finalUser
            )
            let exitCode: Int32
            do {
                (rawOutput, exitCode) = try await GemmaChatRunner.run(
                    modelPath: modelPath, prompt: fullPrompt, maxTokens: 8192, temp: 0.3,
                    environment: settings.buildEnvironment()
                )
            } catch GemmaChatRunnerError.uvNotFound {
                throw IdeogramCaptionGeneratorError.uvNotFound
            }
            lastLog = [
                "=== PROMPT ===", fullPrompt,
                "=== MODEL OUTPUT ===", rawOutput.isEmpty ? "(no output)" : rawOutput,
            ].joined(separator: "\n\n")
            guard exitCode == 0 else {
                throw IdeogramCaptionGeneratorError.subprocessFailed(exitCode, String(rawOutput.suffix(2000)))
            }
        }

        guard let extractedJSON = extractJSONString(from: rawOutput) else {
            throw IdeogramCaptionGeneratorError.noJSONFound(rawOutput)
        }

        let caption: IdeogramCaption
        do {
            guard let data = extractedJSON.data(using: .utf8) else {
                throw IdeogramCaptionGeneratorError.decodeFailed(
                    json: extractedJSON, reason: "UTF-8 encoding failed"
                )
            }
            caption = try JSONDecoder().decode(IdeogramCaption.self, from: data)
        } catch let err as IdeogramCaptionGeneratorError {
            throw err
        } catch let err as DecodingError {
            throw IdeogramCaptionGeneratorError.decodeFailed(
                json: extractedJSON, reason: decodingErrorDescription(err)
            )
        } catch {
            throw IdeogramCaptionGeneratorError.decodeFailed(
                json: extractedJSON, reason: error.localizedDescription
            )
        }

        var result = caption
        result.compositionalDeconstruction.elements =
            result.compositionalDeconstruction.elements.filter(\.isBBoxValid)
        return result
    }

    // MARK: - Private

    /// Exposed (non-private) for unit testing; pure, so `nonisolated`.
    nonisolated func extractJSONString(from text: String) -> String? {
        // mlx_lm.generate echoes the full prompt (which contains example JSON) before
        // the reply, so restrict the search to the reply region between the separators.
        let searchText = GemmaChatRunner.replyRegion(from: text)

        // Strip markdown code fences the model sometimes adds despite being told not to
        var cleaned = searchText
        if let fenceStart = cleaned.range(of: "```json") {
            cleaned.removeSubrange(fenceStart.lowerBound ..< fenceStart.upperBound)
        } else if let fenceStart = cleaned.range(of: "```") {
            cleaned.removeSubrange(fenceStart.lowerBound ..< fenceStart.upperBound)
        }
        if let fenceEnd = cleaned.range(of: "```", options: .backwards) {
            cleaned.removeSubrange(fenceEnd.lowerBound ..< fenceEnd.upperBound)
        }

        // Walk the text to find the outermost { } block, tracking string contents so
        // braces inside JSON string values don't corrupt the depth counter.
        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var current = start
        var inString = false
        var escaped = false
        while current < cleaned.endIndex {
            let ch = cleaned[current]
            if escaped {
                escaped = false
            } else if inString {
                if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { end = current }
                default: break
                }
            }
            current = cleaned.index(after: current)
        }
        guard let endIdx = end else { return nil }
        return sanitizeJSON(String(cleaned[start ... endIdx]))
    }

    /// Fixes common model-output JSON defects before decoding.
    /// Exposed (non-private) for unit testing; pure, so `nonisolated`.
    nonisolated func sanitizeJSON(_ json: String) -> String {
        var s = json
        // Normalize any "compositional_<variant>" key to "compositional_deconstruction".
        // The model generates many wrong suffixes: compositional_description,
        // compositional_photo, compositional_breakdown, compositional_analysis, etc.
        s = s.replacingOccurrences(
            of: #""compositional_[a-z_]+""#,
            with: "\"compositional_deconstruction\"",
            options: .regularExpression
        )
        // Leading empty slot in array:  [,  →  [0,
        s = s.replacingOccurrences(of: #"\[\s*,"#, with: "[0,", options: .regularExpression)
        // Middle empty slots:  ,,  →  , 0,  (iterate until no more)
        var prev = ""
        while prev != s {
            prev = s
            s = s.replacingOccurrences(of: #",\s*,"#, with: ", 0,", options: .regularExpression)
        }
        // Trailing empty slot before ]:  ,]  →  , 0]
        s = s.replacingOccurrences(of: #",\s*\]"#, with: ", 0]", options: .regularExpression)
        return s
    }

    private func decodingErrorDescription(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, ctx):
            "missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case let .typeMismatch(type, ctx):
            "type mismatch — expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        case let .valueNotFound(type, ctx):
            "null/missing value — expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case let .dataCorrupted(ctx):
            "data corrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        @unknown default:
            error.localizedDescription
        }
    }
}
