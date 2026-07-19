import Foundation

// MARK: - Backend selection

/// Which engine serves the prompt-writing LLM features (Scenario Generator and
/// Ideogram 4 captions): local Gemma via `uv`/`mlx_lm`, or a remote
/// OpenAI-compatible HTTP endpoint (e.g. LM Studio).
enum LLMBackendKind: String, Codable, CaseIterable, Identifiable {
    case local
    case remote

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .local: "Local Gemma"
        case .remote: "OpenAI-compatible endpoint"
        }
    }
}

// MARK: - Chat DTOs

/// One message in an OpenAI-style chat completion. Few-shot examples are sent as
/// prior `user`/`assistant` turns (mirroring the local Gemma chat template), so
/// the model sees them as conversation history rather than content to copy.
struct OpenAIChatMessage: Codable, Equatable {
    let role: String
    let content: String
}

/// The `response_format` object. Only `{ "type": "json_object" }` is used, and
/// only when the caller wants strict JSON (Ideogram captions).
struct OpenAIResponseFormat: Codable, Equatable {
    static let jsonObject = Self(type: "json_object")

    let type: String
}

/// Request body for `POST /v1/chat/completions`. Non-streaming only.
struct OpenAIChatRequest: Codable {
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case topP = "top_p"
        case topK = "top_k"
    }

    let model: String
    let messages: [OpenAIChatMessage]
    let maxTokens: Int
    let temperature: Double
    /// Nucleus-sampling cutoff. Nil is omitted from the payload.
    let topP: Double?
    /// Top-k sampling (non-standard OpenAI field, honored by LM Studio). Nil is
    /// omitted from the payload.
    let topK: Int?
    let stream: Bool
    let responseFormat: OpenAIResponseFormat?
}

/// The subset of the chat-completions response we read.
struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        let message: OpenAIChatMessage
    }

    let choices: [Choice]

    /// The assistant text of the first choice, or nil when the response carried
    /// no choices.
    var firstContent: String? {
        choices.first?.message.content
    }
}

/// The subset of `GET /v1/models` we read (an id list for the picker).
struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]

    var ids: [String] {
        data.map(\.id)
    }
}

// MARK: - Chat call

/// Everything needed to run one remote chat completion. Bundled into a value so
/// call sites (the two generators) and ``OpenAIChatClient/chat(_:)`` stay tidy.
struct OpenAIChatCall {
    let system: String
    let examples: [(input: String, output: String)]
    let finalUser: String
    let model: String
    let maxTokens: Int
    let temp: Double
    /// Nucleus-sampling cutoff (`top_p`).
    let topP: Double
    /// Top-k sampling; 0 omits the field from the request.
    let topK: Int
    /// Request `response_format: json_object` (used for Ideogram captions).
    let jsonMode: Bool
    let baseURL: String
    let apiKey: String

    /// The `messages` array: a leading `system` message, alternating
    /// `user`/`assistant` turns for each few-shot example, then the final `user`
    /// turn — mirroring the local Gemma path's `chatPrompt`.
    var messages: [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = []
        if !system.isEmpty {
            messages.append(OpenAIChatMessage(role: "system", content: system))
        }
        for example in examples {
            messages.append(OpenAIChatMessage(role: "user", content: example.input))
            messages.append(OpenAIChatMessage(role: "assistant", content: example.output))
        }
        messages.append(OpenAIChatMessage(role: "user", content: finalUser))
        return messages
    }
}
