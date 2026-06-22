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
            "mlx_lm.generate failed (exit \(code)): \(output.prefix(200))"
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

        func extract(_ heading: String) -> String {
            let marker = "## \(heading)"
            guard let markerRange = raw.range(of: marker) else { return "" }
            let afterMarker = raw[markerRange.upperBound...]
            let content: Substring = if let nextHeading = afterMarker.range(of: "\n## ") {
                afterMarker[..<nextHeading.lowerBound]
            } else {
                afterMarker
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return Self(
            system: extract("System Prompt"),
            exampleAInput: extract("Example A Input"),
            exampleAOutput: extract("Example A Output"),
            exampleBInput: extract("Example B Input"),
            exampleBOutput: extract("Example B Output")
        )
    }
}

// MARK: - Generator

@MainActor
final class IdeogramCaptionGenerator {
    private static let uvPath = NSHomeDirectory() + "/.local/bin/uv"

    private(set) var lastLog: String = ""

    // MARK: - Public

    func generate(from description: String, settings: AppSettings) async throws -> IdeogramCaption {
        guard FileManager.default.fileExists(atPath: Self.uvPath) else {
            throw IdeogramCaptionGeneratorError.uvNotFound
        }

        let config = try IdeogramPromptConfig.load()
        let modelPath = settings.gemmaModelPath.isEmpty
            ? "mlx-community/gemma-3-12b-it-8bit"
            : settings.gemmaModelPath

        // Few-shot prompt: examples live in prior user/model turns so the model sees them
        // as conversation history, not as content in the system prompt to copy from.
        let fullPrompt =
            "<start_of_turn>system\n\(config.system)<end_of_turn>\n"
                + "<start_of_turn>user\n\(config.exampleAInput)<end_of_turn>\n"
                + "<start_of_turn>model\n\(config.exampleAOutput)<end_of_turn>\n"
                + "<start_of_turn>user\n\(config.exampleBInput)<end_of_turn>\n"
                + "<start_of_turn>model\n\(config.exampleBOutput)<end_of_turn>\n"
                + "<start_of_turn>user\nDescription to convert: \"\(description)\"<end_of_turn>\n"
                + "<start_of_turn>model\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.uvPath)
        process.arguments = [
            "run", "--with", "mlx-lm>=0.31.3", "--",
            "mlx_lm.generate",
            "--model", modelPath,
            "--prompt", fullPrompt,
            "--max-tokens", "8192",
            "--temp", "0.3",
        ]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env

        let rawOutput = try await runProcessCollectingOutput(process)

        lastLog = [
            "=== PROMPT ===", fullPrompt,
            "=== MODEL OUTPUT ===", rawOutput.isEmpty ? "(no output)" : rawOutput,
        ].joined(separator: "\n\n")

        guard process.terminationStatus == 0 else {
            throw IdeogramCaptionGeneratorError.subprocessFailed(
                process.terminationStatus, String(rawOutput.suffix(2000))
            )
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

    /// Runs `process`, draining a single merged stdout+stderr pipe incrementally, and
    /// returns the full combined output. Merging avoids the classic two-pipe deadlock
    /// (child blocks writing stderr while we block reading stdout). Cancelling the
    /// enclosing Task terminates the subprocess so a hung or long-running generation
    /// can actually be stopped (otherwise the model stays resident on the GPU).
    private func runProcessCollectingOutput(_ process: Process) async throws -> String {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let stream = AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                } else if let text = String(data: data, encoding: .utf8) {
                    continuation.yield(text)
                }
            }
            process.terminationHandler = { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }

        try process.run()

        return try await withTaskCancellationHandler {
            var output = ""
            for await chunk in stream {
                output += chunk
            }
            process.waitUntilExit() // already exited once the pipe hit EOF; returns immediately
            if Task.isCancelled {
                throw CancellationError()
            }
            return output
        } onCancel: {
            process.terminate()
        }
    }

    /// Exposed (non-private) for unit testing; pure, so `nonisolated`.
    nonisolated func extractJSONString(from text: String) -> String? {
        // mlx_lm.generate echoes the full prompt before the generated text, separated by
        // "==========". The prompt contains example JSON, so searching from the start grabs
        // example content instead of the model's reply. Skip past the last separator.
        var searchText = text
        if let sepRange = searchText.range(of: "==========", options: .backwards) {
            let candidate = String(searchText[sepRange.upperBound...])
            // The trailing separator precedes the stats block (no JSON there), so use the
            // region between the first and last separator if both exist.
            if let firstSep = searchText.range(of: "=========="),
               firstSep.lowerBound != sepRange.lowerBound {
                searchText = String(searchText[firstSep.upperBound ..< sepRange.lowerBound])
            } else {
                searchText = candidate
            }
        }

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
