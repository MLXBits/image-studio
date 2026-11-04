import Foundation
import os

// MARK: - Live step progress (WebSocket)
//
// ComfyUI only delivers per-prompt websocket events to a socket whose `clientId` query param
// matches the `client_id` sent in the /prompt body — messages addressed to any other id are
// dropped server-side (`send_json`/`send_bytes` filter on `sid`). So this tracker connects with
// *our* clientID (the same one used at submit) and reports:
//   - "progress"  { value, max, node }     -> real denoise step N/M from the KSampler
//   - "executing" { node }                 -> which node is running now (phase label)
// It never decides completion/failure — `generate()` keeps polling /history for that. The WS
// stream merely paints live progress between polls, so a dead socket degrades to the old
// coarse "Generating…" behavior instead of breaking the run.

/// Mutable state of a ``ComfyUIClient/ProgressTracker``, shared by its caller (`start`/`stop`) and
/// its websocket read loop, which runs on the URL session's queue. Lives behind the tracker's lock.
nonisolated private struct ProgressTrackerState {
    var task: URLSessionWebSocketTask?
    /// Last-running-node id; only ever read to build the current snapshot.
    var lastNodeID: String?
    /// Distinct node ids in first-seen order; grown as `executing` frames arrive.
    var executedNodes: [String] = []
}

extension ComfyUIClient {
    struct LiveProgress: Equatable {
        var step: Int = 0 // completed steps (from `progress.value`)
        var totalSteps: Int = 0 // denoise total (from `progress.max`)
        var nodeID: String? // currently-running node id (`executing.node` / `progress.node`)
        /// Ordered node ids seen via `executing` frames, so a consumer can derive "node X of N".
        var executedNodes: [String] = []

        /// Human phase label derived from the active node class, e.g. "Denoising".
        var phaseLabel: String? {
            guard let n = nodeID else { return nil }
            if n == "KSAMPLER" {
                return "Denoising"
            }
            if n.hasPrefix("CLIP") {
                return "Encoding prompt"
            } // CLIP_POS / CLIP_NEG
            if n == "ENCODE" {
                return "Encoding image"
            } // SeedVR2
            if n == "DECODE" || n == "POST" || n == "SAVE" {
                return "Decoding & saving"
            }
            if n == "EMPTY" {
                return "Preparing"
            }
            return nil
        }
    }

    /// Opens a websocket bound to one submitter identity and streams live progress snapshots as the
    /// server reports them. Start it *before* submitting, then use its returned `clientID` in the
    /// /prompt body so the socket is addressed correctly. Safe to discard — no global state; a dead
    /// connection only loses live progress, never the result (polling still decides completion).
    nonisolated final class ProgressTracker: Sendable {
        /// Extracts the JSON payload as `Data` from a websocket frame. ComfyUI sends its frames as text (`.string`) — not binary — so
        /// handling
        /// only `.data` silently drops every `executing`/`progress` message and live progress never reaches the UI. Accept both shapes;
        /// return
        /// nil for anything that is neither.
        static func payloadData(from message: URLSessionWebSocketTask.Message) -> Data? {
            switch message {
            case let .data(data):
                return data
            case let .string(text):
                return text.data(using: .utf8)
            @unknown default:
                return nil
            }
        }

        /// Maps one decoded JSON frame to a LiveProgress snapshot, or nil if the frame carries no progress-relevant data (status
        /// heartbeats,
        /// custom-node noise such as `crystools.monitor`, etc.). `executedNodes` accumulates distinct node ids in first-seen order so
        /// consumers
        /// can derive "node X of N".
        static func decode(
            _ data: Data?,
            lastNodeID: inout String?,
            executedNodes: inout [String]
        ) -> LiveProgress? {
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  let dataObj = obj["data"] as? [String: Any] else { return nil }

            switch type {
            case "executing":
                guard let n = dataObj["node"] as? String, !n.isEmpty && n.lowercased() != "null" else {
                    lastNodeID = nil // {"node":"null"} marks execution end -> stop labelling
                    return nil
                }
                if lastNodeID != n {
                    executedNodes.append(n)
                } // first-seen order; de-dupe repeats
                lastNodeID = n
                var snap = LiveProgress(nodeID: n)
                snap.executedNodes = executedNodes
                return snap

            case "progress":
                guard let node = dataObj["node"] as? String, !node.isEmpty else { return nil }
                if lastNodeID != node {
                    executedNodes.append(node)
                }
                lastNodeID = node
                var snap = LiveProgress(nodeID: node)
                snap.executedNodes = executedNodes
                snap.step = (dataObj["value"] as? Int) ?? 0
                snap.totalSteps = (dataObj["max"] as? Int) ?? 0
                return snap

            default:
                return nil // status, execution_*, assets.*, crystools.* — not step progress
            }
        }

        private let baseURL: String
        private let state = OSAllocatedUnfairLock(initialState: ProgressTrackerState())
        private let continuation: AsyncStream<LiveProgress>.Continuation

        /// Yields a snapshot each time the server reports one. Terminates when the socket closes;
        /// consumers stop reading on job completion regardless.
        let progressStream: AsyncStream<LiveProgress>

        init(baseURL: String) {
            self.baseURL = baseURL
            let (stream, continuation) = AsyncStream.makeStream(of: LiveProgress.self)
            self.progressStream = stream
            self.continuation = continuation
        }

        /// Opens the socket bound to `clientID` and begins reading. Returns nil if the base URL is not
        /// a parseable http(s) URL (the tracker then yields nothing and callers fall back to polling).
        @discardableResult
        func start(clientId: String) -> Bool {
            guard var comps = URLComponents(string: baseURL), comps.scheme?.hasPrefix("http") == true else {
                continuation.finish()
                return false
            }
            comps.scheme = (comps.scheme ?? "").lowercased() == "https" ? "wss" : "ws"
            // Append rather than replace, so a reverse-proxy prefix (`/comfy`) survives — the HTTP
            // calls append their endpoint paths to the same base.
            comps.path += "/ws"
            comps.queryItems = [URLQueryItem(name: "clientId", value: clientId)]
            guard let connectURL = comps.url else {
                continuation.finish()
                return false
            }

            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 60 // handshake only; the stream itself is unbounded
            cfg.timeoutIntervalForResource = .infinity
            let task = URLSession(configuration: cfg).webSocketTask(with: connectURL)
            state.withLock { $0.task = task }
            task.resume()
            receiveLoop(task: task)
            return true
        }

        /// Recursively drains the socket, yielding a snapshot for each progress-relevant frame.
        private func receiveLoop(task: URLSessionWebSocketTask) {
            task.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(message):
                    let snap = self.state.withLock { st in
                        Self.decode(
                            Self.payloadData(from: message),
                            lastNodeID: &st.lastNodeID,
                            executedNodes: &st.executedNodes
                        )
                    }
                    if let snap {
                        self.continuation.yield(snap)
                    }
                    self.receiveLoop(task: task) // keep reading either way
                case .failure:
                    self.continuation.finish()
                @unknown default:
                    break
                }
            }
        }

        func stop() {
            let task = state.withLock { st in
                defer { st.task = nil }
                return st.task
            }
            task?.cancel(with: .normalClosure, reason: nil)
            continuation.finish()
        }
    }
}
