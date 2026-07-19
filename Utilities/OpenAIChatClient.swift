import Foundation

enum OpenAIChatClientError: LocalizedError {
    case invalidURL(String)
    case httpStatus(Int, String)
    case emptyResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(base):
            "Invalid endpoint URL: \(base). Expected something like http://localhost:1234/v1"
        case let .httpStatus(code, body):
            // The tail carries the server's error message (e.g. "model not loaded").
            "Endpoint returned status \(code):\n…\(body.suffix(600))"
        case .emptyResponse:
            "The endpoint returned no message content. Is a model loaded?"
        case let .decoding(detail):
            "Could not parse the endpoint's response: \(detail)"
        }
    }
}

/// Talks to an OpenAI-compatible chat endpoint (e.g. LM Studio) as an alternative
/// to running Gemma locally. Stateless namespace mirroring ``UpdateChecker``'s
/// `URLSession` + status-guard + `JSONDecoder` idiom; the ``ScenarioGenerator``
/// and ``IdeogramCaptionGenerator`` remote paths call ``chat(system:examples:…)``
/// and feed the returned text into their existing reply extractors.
enum OpenAIChatClient {
    /// First model load on the server can be slow, so allow a generous timeout.
    private static let requestTimeout: TimeInterval = 120

    /// Normalizes a user-entered base URL: trims trailing slashes and appends the
    /// `/v1` API prefix when absent (so `http://localhost:1234` and
    /// `http://localhost:1234/v1/` both resolve to `http://localhost:1234/v1`).
    static func normalizedBase(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        if !base.hasSuffix("/v1") { base += "/v1" }
        return base
    }

    /// Runs one chat completion and returns the assistant message text. The
    /// caller's own JSON/reply extraction remains the real safety net.
    static func chat(_ call: OpenAIChatCall) async throws -> String {
        let base = normalizedBase(call.baseURL)
        guard let url = URL(string: base + "/chat/completions") else {
            throw OpenAIChatClientError.invalidURL(call.baseURL)
        }

        let body = OpenAIChatRequest(
            model: call.model,
            messages: call.messages,
            maxTokens: call.maxTokens,
            temperature: call.temp,
            topP: call.topP,
            topK: call.topK > 0 ? call.topK : nil,
            stream: false,
            responseFormat: call.jsonMode ? .jsonObject : nil
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, apiKey: call.apiKey)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)

        let decoded: OpenAIChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        } catch {
            throw OpenAIChatClientError.decoding(error.localizedDescription)
        }
        guard let content = decoded.firstContent, !content.isEmpty else {
            throw OpenAIChatClientError.emptyResponse
        }
        return content
    }

    /// Fetches the endpoint's advertised model ids (`GET /v1/models`). Used to
    /// validate reachability and populate the model picker.
    static func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let base = normalizedBase(baseURL)
        guard let url = URL(string: base + "/models") else {
            throw OpenAIChatClientError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        applyAuth(&request, apiKey: apiKey)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)

        do {
            return try JSONDecoder().decode(OpenAIModelsResponse.self, from: data).ids
        } catch {
            throw OpenAIChatClientError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func applyAuth(_ request: inout URLRequest, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIChatClientError.httpStatus(0, "No HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIChatClientError.httpStatus(http.statusCode, body)
        }
    }
}
