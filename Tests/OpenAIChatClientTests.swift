import Foundation
@testable import MLXBits_Image_Studio
import Testing

@Suite("OpenAIChatClient")
struct OpenAIChatClientTests {
    private func makeCall(
        system: String, examples: [(input: String, output: String)], finalUser: String
    ) -> OpenAIChatCall {
        OpenAIChatCall(
            system: system, examples: examples, finalUser: finalUser,
            model: "m", maxTokens: 128, temp: 0.3, topP: 0.95, topK: 64, jsonMode: false,
            baseURL: "http://localhost:1234/v1", apiKey: ""
        )
    }

    // MARK: - Message assembly

    @Test func messagesOrderSystemExamplesThenFinalUser() {
        let messages = makeCall(
            system: "You are a writer.",
            examples: [(input: "in-a", output: "out-a"), (input: "in-b", output: "out-b")],
            finalUser: "the request"
        ).messages
        #expect(messages.map(\.role) == ["system", "user", "assistant", "user", "assistant", "user"])
        #expect(messages[0].content == "You are a writer.")
        #expect(messages[1].content == "in-a")
        #expect(messages[2].content == "out-a")
        #expect(messages.last?.content == "the request")
    }

    @Test func messagesOmitEmptySystem() {
        let messages = makeCall(system: "", examples: [], finalUser: "hi").messages
        #expect(messages.map(\.role) == ["user"])
        #expect(messages[0].content == "hi")
    }

    // MARK: - Base URL normalization

    @Test func normalizedBaseAppendsV1WhenAbsent() {
        #expect(OpenAIChatClient.normalizedBase("http://localhost:1234") == "http://localhost:1234/v1")
    }

    @Test func normalizedBaseTrimsTrailingSlashAndKeepsV1() {
        #expect(OpenAIChatClient.normalizedBase("http://localhost:1234/v1/") == "http://localhost:1234/v1")
        #expect(OpenAIChatClient.normalizedBase("  http://localhost:1234/v1  ") == "http://localhost:1234/v1")
    }

    // MARK: - Response decoding

    @Test func decodesFirstChoiceContent() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"hello there"}}]}
        """
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(json.utf8))
        #expect(decoded.firstContent == "hello there")
    }

    @Test func firstContentNilWhenNoChoices() throws {
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(#"{"choices":[]}"#.utf8))
        #expect(decoded.firstContent == nil)
    }

    @Test func decodesModelIds() throws {
        let json = """
        {"data":[{"id":"gemma-3-12b"},{"id":"qwen2.5-7b"}]}
        """
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: Data(json.utf8))
        #expect(decoded.ids == ["gemma-3-12b", "qwen2.5-7b"])
    }

    // MARK: - Request encoding

    @Test func requestEncodesSnakeCaseKeysAndOmitsNilFields() throws {
        let request = OpenAIChatRequest(
            model: "m", messages: [OpenAIChatMessage(role: "user", content: "hi")],
            maxTokens: 128, temperature: 0.3, topP: 0.95, topK: nil,
            stream: false, responseFormat: nil
        )
        let text = try String(bytes: JSONEncoder().encode(request), encoding: .utf8) ?? ""
        #expect(text.contains("\"max_tokens\":128"))
        #expect(text.contains("\"top_p\":0.95"))
        #expect(!text.contains("top_k"))
        #expect(!text.contains("response_format"))
    }

    @Test func requestEncodesTopKAndJSONResponseFormat() throws {
        let request = OpenAIChatRequest(
            model: "m", messages: [], maxTokens: 8, temperature: 1, topP: 0.95, topK: 64,
            stream: false, responseFormat: .jsonObject
        )
        let text = try String(bytes: JSONEncoder().encode(request), encoding: .utf8) ?? ""
        #expect(text.contains("\"top_k\":64"))
        #expect(text.contains("\"response_format\""))
        #expect(text.contains("\"json_object\""))
    }
}
