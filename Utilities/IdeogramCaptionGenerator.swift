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
                model: settings.openAIModel, maxTokens: 8192, temp: settings.llmTemperature,
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

        // Walk the text to find the outermost { } block. A container stack
        // (push on openers, pop on matchers) tracks nesting so braces and brackets
        // inside JSON string values don't corrupt it; if EOF is reached with open
        // containers left over, the output was truncated mid-object and we try a
        // bounded repair instead of failing outright.
        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var stack: [Character] = []
        var current = start
        var inString = false
        var escaped = false
        var stringStart: String.Index? // opening quote of an unterminated string at EOF
        while current < cleaned.endIndex {
            let ch = cleaned[current]
            if escaped {
                escaped = false
            } else if inString {
                if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                    stringStart = nil
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                    stringStart = current
                case "{", "[": stack.append(ch)
                case "}", "]":
                    guard let open = stack.last,
                          (open == "{" && ch == "}") || (open == "[" && ch == "]") else { break }
                    _ = stack.popLast()
                    if stack.isEmpty {
                        // The outermost object is closed; anything after it is not part of the JSON.
                        return sanitizeJSON(String(cleaned[start ... current]))
                    }
                default: break
                }
            }
            current = cleaned.index(after: current)
        }
        // Truncation: at least one container is still open at EOF (a lone `{` with no closer).
        guard !stack.isEmpty else { return nil }
        var s = String(cleaned[start...])
        if let stringStart {
            // EOF landed inside an unterminated string (tracked by `stringStart`): drop from
            // its opening quote so a half-emitted value or key is dropped whole, never kept
            // partially.
            s = String(cleaned[start ..< stringStart])
        }
        return repairTruncatedJSON(s).map { sanitizeJSON($0) }
    }

    /// Bounded repair of a JSON object whose outermost `}` never arrived (truncated model
    /// output). Repairs only by structure, never inventing values: an unterminated string
    /// tail and any dangling `"key"` or `"key":` fragment are dropped, then the still-open
    /// containers are closed. If the loop has not converged after a few passes (malformed
    /// rather than merely truncated input), returns nil so the caller's existing `.noJSONFound`
    /// path handles it.
    nonisolated private func repairTruncatedJSON(_ json: String) -> String? {
        let closers = unclosedContainerClosers(in: json)

        // Bounded tail repair: repeatedly trim trailing whitespace/commas and drop a dangling
        // `"key"` / `"key":` fragment until the last character is a valid token terminal.
        // Values are never invented — only incomplete tokens at the cut edge go away.
        var chars = Array(json)
        for _ in 0 ..< 32 {
            while let last = chars.last, last.isWhitespace || last == "," {
                chars.removeLast()
            }
            guard let last = chars.last else { break }

            // Truncated number or container edge: the clipped value (if any) is accepted as-is;
            // structural validity plus `JSONDecoder` are the real gates downstream.
            if "0123456789.+-eE".contains(last) || "{}[]".contains(last) {
                return String(chars) + closers
            }

            let tail5 = String(chars.suffix(5))
            if tail5.hasSuffix("null") || tail5.hasSuffix("true") || tail5.hasSuffix("false") {
                // Complete `true`/`false`/`null` literal at the edge.
                return String(chars) + closers
            }

            if last == ":" {
                chars = dropDanglingKeyTail(chars) ?? []
                guard !chars.isEmpty else { return nil }
            } else if last == "\"" {
                let openQuote = quoteStart(before: chars.count - 2, in: chars)
                var pre = openQuote - 1
                while pre >= 0 && chars[pre].isWhitespace {
                    pre -= 1
                }
                if pre >= 0 && chars[pre] == ":" {
                    // A complete value after its key — structurally done at this point.
                    return String(chars) + closers
                }
                // Dangling `"key"` (after `{`, `,`, or start of text): drop the token and any
                // immediately preceding comma so the next pass re-examines the new edge.
                if openQuote > 0 {
                    while chars.count > openQuote {
                        chars.removeLast()
                    }
                    while let l = chars.last, l == "," {
                        chars.removeLast()
                    }
                } else {
                    return nil
                }
            } else {
                // Anything else at the edge is not repairable without inventing a value; return
                // nil so `.noJSONFound` surfaces instead of fabricated JSON.
                return nil
            }
        }
        // Bounded loop exhausted without converging: malformed rather than merely truncated.
        return nil
    }

    /// Scans `json` with the same string-state rules as the main walk and returns the matching
    /// closers for every container still open at EOF, in closing order (innermost first).
    nonisolated private func unclosedContainerClosers(in json: String) -> String {
        var openers: [Character] = []
        var inString = false
        var escaped = false
        for ch in json {
            if escaped {
                escaped = false
            } else if inString {
                if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"": inString = true
                case "{", "[": openers.append(ch)
                case "}", "]": _ = openers.popLast()
                default: break
                }
            }
        }
        return String(openers.reversed().map { $0 == "{" ? "}" : "]" })
    }

    /// Given a buffer ending in a dangling `"key":` (with optional trailing whitespace before the
    /// colon), walks back to the key's opening quote and returns the buffer truncated there, or nil
    /// if the expected closing quote is not found.
    nonisolated private func dropDanglingKeyTail(_ charsIn: [Character]) -> [Character]? {
        var chars = charsIn
        // The last char is ":" (or whitespace after trimming — but we trimmed first). Walk back
        // over any whitespace to the key's closing quote.
        var i = chars.count - 2
        while i >= 0 && chars[i].isWhitespace {
            i -= 1
        }
        guard i >= 0, chars[i] == "\"" else { return nil }
        // Now walk back to the key's opening quote.
        let openQuote = quoteStart(before: i - 1, in: chars)
        while chars.count > openQuote {
            chars.removeLast()
        }
        return chars.isEmpty ? nil : chars
    }

    /// Finds the index of the opening quote of the string token whose closing quote sits at or just
    /// before `endIndex`, honoring backslash escapes. Returns that index; callers use it as a cut point.
    nonisolated private func quoteStart(before endIndex: Int, in chars: [Character]) -> Int {
        var openQuote = endIndex
        var esc = false
        while openQuote > 0 {
            let c = chars[openQuote]
            if esc {
                esc = false
            } else if c == "\\" {
                esc = true
            } else if c == "\"" {
                break
            }
            openQuote -= 1
        }
        return max(0, openQuote)
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
        // Middle empty slots:  ,,  →  , 0,  (iterate until stable)
        var prev = ""
        while prev != s {
            prev = s
            s = s.replacingOccurrences(of: #",\s*,+"#, with: ", 0,", options: .regularExpression)
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

/// Extracts, repairs (bounded), sanitizes, and decodes an Ideogram caption from a raw
/// string. Shared by the LLM generation flow and the paste-JSON path so both get
/// identical extraction + repair behavior without instantiating the generator class.
func parseCaptionJSON(from json: String) -> IdeogramCaption? {
    // Reuses the same nonisolated instance methods via a throwaway; the generator holds
    // no state that these pure helpers read, so this is zero-cost.
    let gen = IdeogramCaptionGenerator()
    guard let extracted = gen.extractJSONString(from: json) else { return nil }
    guard let data = extracted.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(IdeogramCaption.self, from: data)
}
