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
        if !base.hasSuffix("/v1") {
            base += "/v1"
        }
        return base
    }

    /// Runs one chat completion and returns the assistant message text. The
    /// caller's own JSON/reply extraction remains the real safety net.
    static func chat(_ call: OpenAIChatCall) async throws -> String {
        let base = normalizedBase(call.baseURL)
        guard let url = URL(string: base + "/chat/completions") else {
            throw OpenAIChatClientError.invalidURL(call.baseURL)
        }

        func body(responseFormat: OpenAIResponseFormat?) -> OpenAIChatRequest {
            OpenAIChatRequest(
                model: call.model,
                messages: call.messages,
                maxTokens: call.maxTokens,
                temperature: call.temp,
                topP: call.topP,
                topK: call.topK > 0 ? call.topK : nil,
                stream: false,
                responseFormat: responseFormat
            )
        }

        let data: Data
        do {
            let format: OpenAIResponseFormat? = call.jsonMode ? .jsonObject : nil
            data = try await post(url, body: body(responseFormat: format), apiKey: call.apiKey)
        } catch {
            // Not every OpenAI-compatible server implements `json_object` — some
            // (mlx-lm's, notably) accept only `json_schema` or `text`. Retry with
            // the field dropped: the prompt already asks for JSON and the caller's
            // extractor tolerates prose or fences around it.
            guard call.jsonMode, rejectsJSONObject(error) else { throw error }
            data = try await post(url, body: body(responseFormat: nil), apiKey: call.apiKey)
        }

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

    // MARK: - LM Studio native API (session polling + eject)

    /// Mirrors the server's `GET /api/v1/models` shape for the fields we read. Kept here — not in
    /// ``Models/OpenAIChat.swift`` — because it is wire-specific to this client, while ``LMSessionStatus``
    /// is what stores and views consume. Unknown keys (e.g. `size_bytes`, `capabilities`) are ignored by
    /// default decoding; the top-level array key is `models` per the live API. A model with several loaded
    /// instances reports them all in one entry's `loaded_instances`.
    private struct LMModelListResponse: Decodable {
        enum CodingKeys: String, Swift.CodingKey { case models }

        let models: [Entry]

        struct Entry: Decodable {
            enum CodingKeys: String, Swift.CodingKey {
                case key
                case displayName = "display_name"
                case loadedInstances = "loaded_instances"
            }

            let key: String
            let displayName: String?
            let loadedInstances: [Instance]
        }

        struct Instance: Decodable {
            let id: String
            let config: Config?

            struct Config: Decodable {
                enum CodingKeys: String, Swift.CodingKey { case contextLength = "context_length" }

                let contextLength: Int?
            }
        }
    }

    /// Polls the native session endpoint for currently-resident model instances. The base URL is stored as
    /// `…/v1` (the OpenAI path); LM Studio's native API lives at `/api/v1`, so we strip one trailing segment
    /// and re-add it — `http://host:1234/v1` becomes `http://host:1234/api/v1/models`. Servers without the
    /// native surface (non-LM-Studio OpenAI-compatible backends) fall back to the standard OpenAI
    /// `GET /v1/models` shape when it carries llama.cpp-style residency data (`status.value` per model);
    /// servers with neither surface throw, and callers treat that as "no info", not an error worth surfacing.
    static func fetchSessionStatus(baseURL: String, apiKey: String) async throws -> LMSessionStatus {
        do {
            return try await fetchNativeSessionStatus(baseURL: baseURL, apiKey: apiKey)
        } catch let error as OpenAIChatClientError where isNonNativeSurface(error) {
            // No LM Studio native surface (llama.cpp router, plain OpenAI proxy, …) — try the
            // standard OpenAI model list, which llama.cpp augments with residency status.
            return try await fetchOpenAISessionStatus(baseURL: baseURL, apiKey: apiKey, original: error)
        }
    }

    /// The LM Studio native call — `GET {base}/api/v1/models`. Unchanged wire behavior.
    private static func fetchNativeSessionStatus(baseURL: String, apiKey: String) async throws -> LMSessionStatus {
        let base = normalizedBase(baseURL).replacingOccurrences(of: "/v1", with: "/api/v1", options: [.anchored, .backwards])
        guard let url = URL(string: base + "/models") else {
            throw OpenAIChatClientError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        applyAuth(&request, apiKey: apiKey)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)

        do {
            let decoded = try JSONDecoder().decode(LMModelListResponse.self, from: data)
            var loaded: [LMSessionStatus.LoadedModel] = []
            for entry in decoded.models {
                guard !entry.loadedInstances.isEmpty else { continue } // only report *loaded* models
                let instances = entry.loadedInstances.map { LMSessionStatus.Instance(id: $0.id, contextLength: $0.config?.contextLength) }
                loaded.append(LMSessionStatus.LoadedModel(modelKey: entry.key, displayName: entry.displayName, instances: instances))
            }
            return LMSessionStatus(loaded: loaded)
        } catch {
            throw OpenAIChatClientError.decoding(error.localizedDescription)
        }
    }

    /// llama.cpp fallback for when the native surface 404/405s: `GET {base}/models` (the base as stored,
    /// i.e. `…/v1`) — the standard OpenAI model list. llama.cpp's router augments each entry with
    /// `status.value` and the spawn `args`; `sessionStatusFromOpenAIModelList` maps the loaded ones.
    /// If the standard list is also missing or unparseable, rethrows the original error so the store
    /// keeps its "no session info" behavior for servers with neither surface.
    private static func fetchOpenAISessionStatus(baseURL: String, apiKey: String, original: Error) async throws -> LMSessionStatus {
        let base = normalizedBase(baseURL)
        guard let url = URL(string: base + "/models") else {
            throw original
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        applyAuth(&request, apiKey: apiKey)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw original // no standard list either — the server really has no session surface
        }
        guard let status = sessionStatusFromOpenAIModelList(data) else {
            throw original
        }
        return status
    }

    /// True when the server answered but has no LM Studio native surface (404/405 on `/api/v1/models`).
    private static func isNonNativeSurface(_ error: Error) -> Bool {
        if case let OpenAIChatClientError.httpStatus(code, _) = error {
            return code == 404 || code == 405
        }
        return false
    }

    /// Residency fallback for OpenAI-compatible servers without the LM Studio native surface (404/405 on
    /// `/api/v1/models`): llama.cpp's router answers the standard `GET /v1/models` with a per-model
    /// `status.value` (`"loaded"` / `"unloaded"`) plus the spawn `args`, from which we recover the context
    /// length (`--ctx-size`). Plain OpenAI servers (no `status` field) decode to "nothing loaded".
    /// Exposed (non-private) for unit testing.
    static func sessionStatusFromOpenAIModelList(_ data: Data) -> LMSessionStatus? {
        guard let decoded = try? JSONDecoder().decode(OpenAIModelListResponse.self, from: data) else { return nil }
        var loaded: [LMSessionStatus.LoadedModel] = []
        for entry in decoded.data where entry.status?.value == "loaded" {
            let ctx = contextLength(fromArgs: entry.status?.args)
            loaded.append(LMSessionStatus.LoadedModel(
                modelKey: entry.id, displayName: nil,
                instances: [LMSessionStatus.Instance(id: entry.id, contextLength: ctx)]
            ))
        }
        return LMSessionStatus(loaded: loaded)
    }

    /// Pulls `--ctx-size N` out of a llama.cpp spawn-args array (`["--ctx-size", "125000", …]`).
    /// `nil` when the flag or its value is absent or unparsable — the pill simply omits the ctx readout.
    static func contextLength(fromArgs args: [String]?) -> Int? {
        guard let args, let i = args.firstIndex(of: "--ctx-size"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    /// Unloads one resident model instance (`POST /api/v1/models/unload`). Best-effort from the pill's
    /// eject button: a transient failure just means the next poll still shows it loaded and the user
    /// retries; the store surfaces nothing.
    static func unloadModel(instanceID: String, baseURL: String, apiKey: String) async throws {
        do {
            try await unloadNativeModel(instanceID: instanceID, baseURL: baseURL, apiKey: apiKey)
        } catch let error as OpenAIChatClientError where isNonNativeSurface(error) {
            // No LM Studio native surface — llama.cpp's router unloads via `POST /models/unload`
            // (no /v1 prefix) with a model id, not an instance id.
            try await unloadLlamaCPPModel(instanceID: instanceID, baseURL: baseURL, apiKey: apiKey)
        }
    }

    /// The LM Studio native unload — `POST {base}/api/v1/models/unload` with an instance id. Unchanged wire behavior.
    private static func unloadNativeModel(instanceID: String, baseURL: String, apiKey: String) async throws {
        let base = normalizedBase(baseURL).replacingOccurrences(of: "/v1", with: "/api/v1", options: [.anchored, .backwards])
        guard let url = URL(string: base + "/models/unload") else {
            throw OpenAIChatClientError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 // unload can take a moment to vacate weights
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, apiKey: apiKey)
        if let body = try? JSONSerialization.data(withJSONObject: ["instance_id": instanceID]) {
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)
    }

    /// llama.cpp fallback: `POST {base}/models/unload` with `{"model": <id>}`; the base is the OpenAI
    /// base with `/v1` stripped (the router serves the management path at the root).
    private static func unloadLlamaCPPModel(instanceID: String, baseURL: String, apiKey: String) async throws {
        let base = normalizedBase(baseURL).replacingOccurrences(of: "/v1", with: "", options: [.anchored, .backwards])
        guard let url = URL(string: base + "/models/unload") else {
            throw OpenAIChatClientError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 // unload can take a moment to vacate weights
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": instanceID])

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)
    }

    // MARK: - Helpers

    /// POSTs one chat-completions request and returns the raw response body.
    private static func post(_ url: URL, body: OpenAIChatRequest, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, apiKey: apiKey)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    /// True when a failure looks like the server rejecting the `response_format`
    /// field itself rather than the prompt — the signal to retry without it.
    /// Exposed (non-private) for unit testing.
    static func rejectsJSONObject(_ error: Error) -> Bool {
        guard case let OpenAIChatClientError.httpStatus(status, body) = error else { return false }
        return (status == 400 || status == 422) && body.contains("response_format")
    }

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

/// Wire shape of the standard OpenAI `GET /v1/models` list as served by llama.cpp's router, which
/// augments each entry with residency (`status.value`) and the spawn `args`. File-scoped (rather than
/// nested in ``OpenAIChatClient``) so the decoders stay within the lint nesting budget.
private struct OpenAIModelListResponse: Decodable {
    struct Status: Decodable {
        let value: String
        let args: [String]?
    }

    struct Entry: Decodable {
        let id: String
        let status: Status?
    }

    let data: [Entry]
}
