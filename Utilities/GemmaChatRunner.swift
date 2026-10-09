import Foundation

enum GemmaChatRunnerError: LocalizedError {
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .modelNotFound(path):
            "Gemma model not found at \(path). Check the model path in Settings → Advanced "
                + "(it powers captions and the Scenario Generator)."
        }
    }
}

/// Shared plumbing for local Gemma generation on the bundled Python (`mlx_lm.generate` through run_tool.py),
/// used by ``IdeogramCaptionGenerator`` (structured captions) and
/// ``ScenarioGenerator`` (prompt writing): the subprocess runner with
/// task-cancellation → terminate, the `## Heading` prompt-config parser, the
/// mlx_lm output reply-region extractor, and the Gemma chat-template
/// assembler.
enum GemmaChatRunner {
    /// Extracts one `## Heading` section's body from an editable prompt
    /// config markdown file (content up to the next `## ` or EOF, trimmed;
    /// empty string when the heading is absent).
    nonisolated static func section(_ heading: String, in raw: String) -> String {
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

    /// The model's reply region in mlx_lm.generate output: mlx_lm echoes the
    /// prompt, then prints the reply between `==========` separators, then a
    /// stats block. Returns the text between the first and last separator,
    /// the text after a single separator, or the whole input when none exist.
    nonisolated static func replyRegion(from text: String) -> String {
        guard let lastSep = text.range(of: "==========", options: .backwards) else { return text }
        if let firstSep = text.range(of: "=========="),
           firstSep.lowerBound != lastSep.lowerBound {
            return String(text[firstSep.upperBound ..< lastSep.lowerBound])
        }
        return String(text[lastSep.upperBound...])
    }

    /// Trims a model reply to its first turn: cuts at the first
    /// `<end_of_turn>` (anything after is the model continuing the few-shot
    /// pattern into extra turns) and removes any residual Gemma control
    /// tokens / role labels. Plain-text consumers need this; the JSON caption
    /// path finds its `{ }` block regardless.
    nonisolated static func firstTurn(of reply: String) -> String {
        var text = reply
        if let end = text.range(of: "<end_of_turn>") {
            text = String(text[..<end.lowerBound])
        }
        for token in ["<start_of_turn>", "<end_of_turn>"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        // Strip stray special tokens that leak from VLM templates — angle-bracket
        // tokens containing a pipe, e.g. <image|>, <|channel>, <turn|>. Real
        // prose never puts a | inside <…>, so this is safe.
        text = text.replacingOccurrences(
            of: "<[^>]*\\|[^>]*>", with: "", options: .regularExpression
        )
        // Drop a leading role label the model sometimes echoes (e.g. "model\n").
        for role in ["model\n", "assistant\n"] where text.hasPrefix(role) {
            text = String(text.dropFirst(role.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips leading package-manager status lines (e.g. "Installed 70
    /// packages in 124ms", "Resolved …", package `+ pkg==ver` lines) from a
    /// reply. Builds before 0.16 ran Gemma through `uv`, which printed these to
    /// stderr, merged into stdout; on the `mlx_vlm.generate --no-verbose` path
    /// no `==========` separators bound the reply for ``replyRegion``. Only
    /// leading lines are removed, so a prompt that mentions such words later is
    /// untouched. Kept for remote and older outputs; the bundled runtime prints
    /// none.
    nonisolated static func stripToolPreamble(from text: String) -> String {
        let pattern =
            "^(Resolved|Prepared|Installed|Downloaded|Uninstalled|Audited|Built|Building|Updated|Bytecode compiled)\\b.*$"
                + "|^[+-] \\S+.*$"
        let regex = try? NSRegularExpression(pattern: pattern)
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeFirst()
                continue
            }
            let range = NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
            guard let regex, regex.firstMatch(in: trimmed, range: range) != nil else { break }
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gemma chat-template few-shot prompt: examples live in prior user/model
    /// turns so the model sees them as conversation history, not as content
    /// in the system prompt to copy from.
    nonisolated static func chatPrompt(
        system: String,
        examples: [(input: String, output: String)],
        finalUser: String
    ) -> String {
        var prompt = "<start_of_turn>system\n\(system)<end_of_turn>\n"
        for example in examples {
            prompt += "<start_of_turn>user\n\(example.input)<end_of_turn>\n"
            prompt += "<start_of_turn>model\n\(example.output)<end_of_turn>\n"
        }
        prompt += "<start_of_turn>user\n\(finalUser)<end_of_turn>\n"
        prompt += "<start_of_turn>model\n"
        return prompt
    }

    /// Runs `mlx_lm.generate` on the bundled Python and returns the combined
    /// stdout+stderr plus the exit code (callers log the output before acting on
    /// a nonzero exit, so failures still surface the model's raw text).
    /// Cancelling the enclosing Task terminates the subprocess.
    ///
    /// `environment` should come from `AppSettings.buildEnvironment()` so the
    /// user's HF_HOME / HF_TOKEN / HF_HUB_OFFLINE settings apply to mlx_lm's
    /// model resolution exactly as they do to mflux.
    static func run( // swiftlint:disable:this function_parameter_count
        modelPath: String,
        prompt: String,
        maxTokens: Int,
        temp: Double,
        environment: [String: String],
        toolchain: Toolchain
    ) async throws -> (output: String, exitCode: Int32) {
        let mlxLM = try toolchain.command(.mlxLmGenerate)

        // A local path that doesn't exist would silently fall through to HF
        // repo-ID resolution inside mlx_lm and die with an opaque traceback —
        // catch it here with a clear message instead.
        let expandedModel = (modelPath as NSString).expandingTildeInPath
        if expandedModel.hasPrefix("/"), !FileManager.default.fileExists(atPath: expandedModel) {
            throw GemmaChatRunnerError.modelNotFound(expandedModel)
        }

        func arguments(_ command: ToolCommand, extra: [String]) -> [String] {
            command.arguments + [
                "--model", expandedModel,
                "--prompt", prompt,
                "--max-tokens", "\(maxTokens)",
            ] + extra
        }

        let first = try await spawn(
            mlxLM, arguments: arguments(mlxLM, extra: ["--temp", "\(temp)"]), environment: environment
        )
        // VLM-only architectures (e.g. gemma4_unified) aren't in mlx-lm's
        // model registry — retry through mlx-vlm's CLI. It spells the flag
        // --temperature, and (unlike mlx-lm) its default verbose mode echoes
        // the whole re-templated prompt into stdout; --no-verbose prints only
        // the generated text, so extraction gets clean output.
        if first.exitCode != 0, first.output.contains("Model type"), first.output.contains("not supported") {
            let mlxVLM = try toolchain.command(.mlxVlmGenerate)
            return try await spawn(
                mlxVLM,
                arguments: arguments(mlxVLM, extra: ["--temperature", "\(temp)", "--no-verbose"]),
                environment: environment
            )
        }
        return first
    }

    private static func spawn(
        _ command: ToolCommand,
        arguments: [String],
        environment: [String: String]
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = arguments
        process.environment = environment
        let output = try await runCollectingOutput(process)
        return (output, process.terminationStatus)
    }

    /// Runs `process`, draining a single merged stdout+stderr pipe incrementally, and
    /// returns the full combined output. Merging avoids the classic two-pipe deadlock
    /// (child blocks writing stderr while we block reading stdout). Cancelling the
    /// enclosing Task terminates the subprocess so a hung or long-running generation
    /// can actually be stopped (otherwise the model stays resident on the GPU).
    private static func runCollectingOutput(_ process: Process) async throws -> String {
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
}
