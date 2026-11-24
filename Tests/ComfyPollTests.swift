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
        /// The connection drops after `seconds`, as a request to a vanished host times out.
        case droppedAfter(seconds: TimeInterval)
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
        case let .droppedAfter(seconds):
            // Blocks only the loading thread, which belongs to this request.
            Thread.sleep(forTimeInterval: seconds)
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
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
    nonisolated private static let running = Reply.status(200, #"{"queue_running":[[0,"p1",{},{},["9"]]],"queue_pending":[]}"#)
    nonisolated private static let pending = Reply.status(200, "{}")
    nonisolated private static let finished = Reply.status(200, """
    {"p1":{"status":{"completed":true,"status_str":"success","messages":[]},
    "outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}}
    """)

    private func generate(blipWindow: TimeInterval = ComfyPollTiming.standard.blipWindow) async throws -> [String] {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubComfyServer.self]
        let client = ComfyUIClient(config: .init(baseURL: "http://127.0.0.1:1"), session: URLSession(configuration: cfg))
        let outputs = try await client.generate(
            workflow: [String: Any](), totalNodes: 1, totalSteps: 1, onProgress: { _ in },
            timing: ComfyPollTiming(interval: 0.01, maxWait: 8, blipWindow: blipWindow)
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

    /// Pending or running, the prompt is still the server's: the poll waits for its output.
    @Test func aPromptStillQueuedOrRunningIsPolledUntilItFinishes() async throws {
        for queue in [Self.queued, Self.running] {
            StubComfyServer.serve { path, hits in
                switch path {
                case "/prompt": Self.submitted
                case "/queue": queue
                default: hits < 40 ? Self.pending : Self.finished
                }
            }
            #expect(try await generate() == ["out.png"])
            #expect(StubComfyServer.hits("/queue") > 0)
        }
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

    /// The prompt ends between a poll and the `/queue` read, and the history check that
    /// follows drops. That's a blip, not a lost prompt: the next poll finds the output.
    @Test func aDroppedRecheckAfterAnEmptyQueueIsNotALostPrompt() async throws {
        let checkPoll = ComfyUIClient.pollsPerQueueCheck
        StubComfyServer.serve { path, hits in
            switch path {
            case "/prompt": Self.submitted
            case "/queue": Self.notQueued
            default: hits < checkPoll ? Self.pending : hits == checkPoll ? .dropped : Self.finished
            }
        }
        #expect(try await generate() == ["out.png"])
    }

    /// A host that vanishes without refusing connections makes each poll wait out its
    /// timeout, so 60 failed polls could take half an hour. Failures stop at the window.
    @Test func failedPollsStopAtTheBlipWindowBeforeTheCountLimit() async {
        StubComfyServer.serve { path, _ in
            path == "/prompt" ? Self.submitted : .dropped
        }
        let error = await #expect(throws: ComfyUIError.self) { try await generate(blipWindow: 0.2) }
        guard case .unreachable? = error else {
            Issue.record("expected unreachable, got \(String(describing: error))")
            return
        }
        #expect(StubComfyServer.hits("/history/p1") < ComfyUIClient.maxConsecutiveHistoryFailures)
    }

    /// The window opens when the first failed poll was sent, not when its timeout came back:
    /// with 0.3 s timeouts and a 0.5 s window, the second failure ends the run.
    @Test func theBlipWindowCountsFromWhenTheFirstFailedPollWasSent() async {
        StubComfyServer.serve { path, _ in
            path == "/prompt" ? Self.submitted : .droppedAfter(seconds: 0.3)
        }
        _ = await #expect(throws: ComfyUIError.self) { try await generate(blipWindow: 0.5) }
        #expect(StubComfyServer.hits("/history/p1") == 2)
    }

    /// A recheck that comes back as something other than JSON (a proxy's error page) decides
    /// nothing: the next poll finds the output.
    @Test func anUnreadableRecheckAfterAnEmptyQueueIsNotALostPrompt() async throws {
        let checkPoll = ComfyUIClient.pollsPerQueueCheck
        StubComfyServer.serve { path, hits in
            switch path {
            case "/prompt": Self.submitted
            case "/queue": Self.notQueued
            default: hits < checkPoll ? Self.pending : hits == checkPoll ? .status(200, "<html>Bad Gateway</html>") : Self.finished
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
