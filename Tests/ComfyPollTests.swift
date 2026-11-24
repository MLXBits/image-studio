import Foundation
@testable import MLXBits_Image_Studio
import os
import Testing

/// A scripted ComfyUI server for ``ComfyUIClient/generate``'s poll loop. Each request is
/// answered by the script from its path and how many times that path was asked before.
nonisolated final class StubComfyServer: URLProtocol {
    typealias Script = @Sendable (_ path: String, _ earlierHits: Int) -> Reply

    enum Reply {
        case status(Int, String)
        /// The connection drops before any answer, as a LAN blip does.
        case dropped
    }

    private struct State {
        var script: Script = { _, _ in .status(404, "") }
        var hits: [String: Int] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func serve(_ script: @escaping Script) {
        state.withLock { $0 = State(script: script) }
    }

    static func hits(_ path: String) -> Int {
        state.withLock { $0.hits[path, default: 0] }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let (script, earlierHits) = Self.state.withLock { state in
            let hits = state.hits[url.path, default: 0]
            state.hits[url.path] = hits + 1
            return (state.script, hits)
        }
        switch script(url.path, earlierHits) {
        case .dropped:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case let .status(code, body):
            guard let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// How a remote run ends when the server forgets the prompt, stays busy, or blips.
/// `/history/{id}` answers `{}` for a prompt still queued or running, and for one the
/// server never saw (checked against a live server), so only `/queue` tells them apart.
@MainActor
@Suite(.serialized)
struct ComfyPollTests {
    private typealias Reply = StubComfyServer.Reply

    nonisolated private static let submitted = Reply.status(200, #"{"prompt_id":"p1","number":0,"node_errors":{}}"#)
    nonisolated private static let notQueued = Reply.status(200, #"{"queue_running":[],"queue_pending":[]}"#)
    nonisolated private static let queued = Reply.status(200, #"{"queue_running":[],"queue_pending":[[0,"p1",{},{},["9"]]]}"#)
    nonisolated private static let pending = Reply.status(200, "{}")
    nonisolated private static let finished = Reply.status(200, """
    {"p1":{"status":{"completed":true,"status_str":"success","messages":[]},
    "outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}}
    """)

    private func generate() async throws -> [String] {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubComfyServer.self]
        let client = ComfyUIClient(config: .init(baseURL: "http://127.0.0.1:1"), session: URLSession(configuration: cfg))
        let outputs = try await client.generate(
            workflow: [String: Any](), totalNodes: 1, totalSteps: 1, onProgress: { _ in },
            pollInterval: 0.01, maxWaitSeconds: 8
        )
        return outputs.map(\.filename)
    }

    /// The server restarted mid-run: history answers `{}` forever and the queue no longer holds it.
    @Test func aPromptTheServerForgotFailsWithinSeconds() async {
        StubComfyServer.serve { path, _ in
            switch path {
            case "/prompt": Self.submitted
            case "/queue": Self.notQueued
            default: Self.pending
            }
        }
        let start = Date()
        let error = await #expect(throws: ComfyUIError.self) { try await generate() }
        guard case .promptLost? = error else {
            Issue.record("expected promptLost, got \(String(describing: error))")
            return
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func aPromptStillQueuedIsPolledUntilItFinishes() async throws {
        StubComfyServer.serve { path, hits in
            switch path {
            case "/prompt": Self.submitted
            case "/queue": Self.queued
            default: hits < 40 ? Self.pending : Self.finished
            }
        }
        #expect(try await generate() == ["out.png"])
        #expect(StubComfyServer.hits("/queue") > 0)
    }

    @Test func dropsAndServerErrorsBelowTheLimitRideThrough() async throws {
        StubComfyServer.serve { path, hits in
            switch path {
            case "/prompt": Self.submitted
            case "/queue": Self.queued
            default:
                switch hits {
                case 0, 1: .dropped
                case 2, 3: .status(503, "busy")
                default: Self.finished
                }
            }
        }
        #expect(try await generate() == ["out.png"])
    }

    @Test func aServerThatKeepsFailingFailsTheJobAtTheLimit() async {
        StubComfyServer.serve { path, _ in
            path == "/prompt" ? Self.submitted : .status(503, "busy")
        }
        let error = await #expect(throws: ComfyUIError.self) { try await generate() }
        guard case .httpStatus(503, _)? = error else {
            Issue.record("expected the 503, got \(String(describing: error))")
            return
        }
        #expect(StubComfyServer.hits("/history/p1") == ComfyUIClient.maxConsecutiveHistoryFailures)
    }
}
