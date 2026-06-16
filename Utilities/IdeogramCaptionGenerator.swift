import Foundation

enum IdeogramCaptionGeneratorError: LocalizedError {
    case uvNotFound
    case subprocessFailed(Int32, String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .uvNotFound:
            "uv not found at ~/.local/bin/uv. Install from https://docs.astral.sh/uv/"
        case let .subprocessFailed(code, output):
            "mlx_lm.generate failed (exit \(code)): \(output.prefix(200))"
        case let .invalidJSON(raw):
            "Could not parse JSON from model output. Raw: \(raw.prefix(2000))"
        }
    }
}

@MainActor
final class IdeogramCaptionGenerator {
    // MARK: - System prompt

    private static let systemPrompt = """
    You are an expert at writing structured JSON captions for the Ideogram 4 diffusion model.
    Given a plain text description, output ONLY valid JSON — no markdown, no explanation, nothing else.

    SCHEMA RULES:
    - "high_level_description": one or two sentence summary (recommended)
    - "style_description": optional; omit the key entirely if not needed
    - "compositional_deconstruction": REQUIRED — always include with "background" and "elements"
    - bbox is [y_min, x_min, y_max, x_max] as integers 0–1000; omit bbox if layout is not constrained

    CRITICAL — style_description uses EXACTLY ONE of "photo" or "art_style", never both:
      Photo key order:     aesthetics → lighting → photo → medium → color_palette
      Art-style key order: aesthetics → lighting → medium → art_style → color_palette

    Element key order — obj:  type, bbox, desc, color_palette
    Element key order — text: type, bbox, text, desc, color_palette

    EXAMPLE A — photographic image:
    {
      "high_level_description": "A golden retriever leaping to catch a tennis ball on a sunny beach.",
      "style_description": {
        "aesthetics": "warm, joyful, vibrant",
        "lighting": "golden hour sunlight, long shadows",
        "photo": "eye-level, 85mm lens, shallow depth of field",
        "medium": "photograph",
        "color_palette": ["#FF8C00", "#FFD700", "#4A90D9"]
      },
      "compositional_deconstruction": {
        "background": "sandy beach with gentle waves and an orange-pink sunset sky",
        "elements": [
          { "type": "obj", "bbox": [200, 150, 800, 650], "desc": "golden retriever mid-leap, tongue out, paws extended" },
          { "type": "obj", "bbox": [300, 490, 390, 570], "desc": "yellow tennis ball in mid-air" }
        ]
      }
    }

    EXAMPLE B — illustrated / non-photographic image:
    {
      "high_level_description": "A cozy coffee shop scene with a teddy bear and rabbit as customers.",
      "style_description": {
        "aesthetics": "warm, whimsical, storybook",
        "lighting": "soft, diffused interior light",
        "medium": "illustration",
        "art_style": "flat vector illustration, bold outlines, pastel palette"
      },
      "compositional_deconstruction": {
        "background": "warm coffee shop interior with wooden furniture and hanging pendant lights",
        "elements": [
          { "type": "obj", "bbox": [150, 100, 750, 500], "desc": "brown teddy bear at a table, holding a coffee cup" },
          { "type": "obj", "bbox": [200, 520, 800, 900], "desc": "white rabbit barista behind the counter, operating an espresso machine" }
        ]
      }
    }

    Rules:
    - "obj" for visual elements; "text" only for literal visible lettering or signage in the scene
    - "text" field only present on type "text" elements
    - hex colors uppercase #RRGGBB
    - Output ONLY the JSON for the given description, nothing else
    """

    private static let uvPath = NSHomeDirectory() + "/.local/bin/uv"

    // MARK: - State

    private(set) var lastLog: String = ""

    // MARK: - Public

    func generate(from description: String, settings: AppSettings) async throws -> IdeogramCaption {
        guard FileManager.default.fileExists(atPath: Self.uvPath) else {
            throw IdeogramCaptionGeneratorError.uvNotFound
        }

        let modelPath = settings.gemmaModelPath.isEmpty
            ? "mlx-community/gemma-3-12b-it-4bit"
            : settings.gemmaModelPath

        let fullPrompt = "<start_of_turn>system\n\(Self.systemPrompt)<end_of_turn>\n"
            + "<start_of_turn>user\n\(description)<end_of_turn>\n<start_of_turn>model\n"

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

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let rawOutput = try await collectOutput(from: outPipe)
        process.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""

        var logParts = [
            "=== PROMPT ===", fullPrompt,
            "=== MODEL OUTPUT ===", rawOutput.isEmpty ? "(no output)" : rawOutput,
        ]
        if !errText.isEmpty { logParts += ["=== STDERR ===", errText] }
        lastLog = logParts.joined(separator: "\n\n")

        guard process.terminationStatus == 0 else {
            throw IdeogramCaptionGeneratorError.subprocessFailed(process.terminationStatus, errText)
        }

        let extractedJSON = extractJSONString(from: rawOutput)
        guard let extractedJSON, var caption = IdeogramCaption.from(jsonString: extractedJSON) else {
            throw IdeogramCaptionGeneratorError.invalidJSON(extractedJSON ?? rawOutput)
        }
        // Drop elements the model emitted as zero-area placeholders
        caption.compositionalDeconstruction.elements =
            caption.compositionalDeconstruction.elements.filter(\.isBBoxValid)
        return caption
    }

    // MARK: - Private

    private func collectOutput(from pipe: Pipe) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let text = String(data: buffer, encoding: .utf8) ?? ""
                    continuation.resume(returning: text)
                } else {
                    buffer.append(data)
                }
            }
        }
    }

    private func extractJSONString(from text: String) -> String? {
        // Strip markdown code fences the model sometimes adds despite being told not to
        var cleaned = text
        if let fenceStart = cleaned.range(of: "```json") {
            cleaned.removeSubrange(fenceStart.lowerBound ..< fenceStart.upperBound)
        } else if let fenceStart = cleaned.range(of: "```") {
            cleaned.removeSubrange(fenceStart.lowerBound ..< fenceStart.upperBound)
        }
        if let fenceEnd = cleaned.range(of: "```", options: .backwards) {
            cleaned.removeSubrange(fenceEnd.lowerBound ..< fenceEnd.upperBound)
        }

        // Find the outermost { } block
        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var current = start
        while current < cleaned.endIndex {
            let ch = cleaned[current]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { end = current; break }
            }
            current = cleaned.index(after: current)
        }
        guard let endIdx = end else { return nil }
        return sanitizeJSON(String(cleaned[start ... endIdx]))
    }

    private func extractCaption(from text: String) -> IdeogramCaption? {
        guard let json = extractJSONString(from: text) else { return nil }
        return IdeogramCaption.from(jsonString: json)
    }

    /// Fixes common model-output JSON defects before decoding.
    private func sanitizeJSON(_ json: String) -> String {
        var s = json
        // Model often abbreviates "compositional_deconstruction" → "compositional_description"
        s = s.replacingOccurrences(
            of: "\"compositional_description\"",
            with: "\"compositional_deconstruction\""
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
}
