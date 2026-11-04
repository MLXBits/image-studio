import Foundation

// MARK: - ComfyUI client
//
// Talks to a running ComfyUI server (e.g. on the RTX 5090 box) so Image Studio can use it as
// an inference backend in place of local mflux. Mirrors ``OpenAIChatClient``'s URLSession +
// status-guard idiom; the app already carries `com.apple.security.network.client` and
// `NSAllowsLocalNetworking`, so a LAN endpoint needs no entitlement change.
//
// Endpoint contract (verified against server.py / main.py in a ComfyUI checkout):
//   POST /prompt        {"prompt": <graph>, "client_id"} → 200 {"prompt_id","number","node_errors"}
//                       invalid graph → 400 {"error":{type,message,...},"node_errors":{...}}
//   GET  /history/{id}  {} while pending; once done the record has outputs: {nodeID:{images:[
//                         {"filename","subfolder","type":"output"}]}}. `status` carries completion.
//   GET  /view          ?filename=&type=output[&subfolder=] → image bytes.
//   GET  /system_stats  liveness + GPU/VRAM (the Settings "Test Connection" proof).
//   POST /interrupt     cooperative cancel of the currently-executing prompt.

/// Network client for a running ComfyUI server. Main-actor-isolated by the project default
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`): its URLSession calls suspend rather than block, so awaiting them
/// leaves the main thread free.
final class ComfyUIClient {
    struct Config {
        static func normalize(_ raw: String) -> String {
            var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") {
                base.removeLast()
            }
            return base
        }

        /// Base URL, normalized to have no trailing slash (e.g. http://192.168.1.50:8188), so the
        /// endpoint paths appended to it never produce `//prompt` or `//ws`.
        let baseURL: String
        /// Optional bearer token for servers with auth enabled; nil/empty = none.
        var apiKey: String?

        /// Normalizes `baseURL` (trims whitespace and trailing slashes) for every caller, so a
        /// settings value like `http://host:8188/` works the same as one without the slash.
        init(baseURL: String, apiKey: String? = nil) {
            self.baseURL = Self.normalize(baseURL)
            self.apiKey = apiKey
        }
    }

    struct HistoryRecord {
        var statusMessage: String? // raw `status_str` label — reads "success" on completion, so not an error indicator by itself.
        /// Best available diagnostic from `status.messages` (the entry whose kind contains "error"/"exception"), else nil.
        var errorMessage: String?
        var completed: Bool? // from record["status"]["completed"]; nil = still running / not present yet
        var outputs: [ComfyOutputFile] = []
    }

    /// Consecutive `/history` transport failures tolerated before giving up — about a minute of blip tolerance at the default 1 Hz poll,
    /// long enough to ride out a router hiccup while permanent loss still fails within roughly that same window.
    static let maxConsecutiveHistoryFailures = 60

    private let config: Config
    /// Unique id for this client; sent as `client_id` so the server can attribute runs.
    let clientID = UUID().uuidString
    private var session: URLSession
    private var base: String {
        config.baseURL
    }

    init(config: Config) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        // First model load into VRAM can be slow; allow generous timeouts.
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 1800
        session = URLSession(configuration: cfg)
    }

    private func headers() -> [String: String] {
        if let key = config.apiKey, !key.isEmpty {
            return ["Authorization": "Bearer \(key)", "Content-Type": "application/json"]
        }
        return ["Content-Type": "application/json"]
    }

    // MARK: - Submit + track + fetch

    /// Submits a workflow and returns its server-side output files once `/history/{id}` reports them.
    /// Live progress is driven by the websocket `ProgressTracker` (real KSampler step counts), while
    /// the `/history` poll remains the *sole* completion/failure authority — so if the socket drops,
    /// the run still completes and the UI simply degrades to a coarse "Generating…" label.
    ///
    /// `workflow` is a prebuilt `/prompt` graph (the SeedVR2 builder, or the bundled-template render for Krea 2); `totalSteps` is only used
    /// to report
    /// a full progress bar on completion.
    func generate(
        workflow: Any,
        totalNodes: Int,
        totalSteps: Int,
        // SwiftLint misses that progressTask/tickerTask capture onProgress, which does make it escape.
        // swiftlint:disable:next unneeded_escaping
        onProgress: @escaping (ComfyUIProgress) -> Void,
        pollInterval: TimeInterval = 1.0,
        maxWaitSeconds: Int = 3600
    ) async throws -> [ComfyOutputFile] {
        let bodyObj: [String: Any] = ["prompt": workflow, "client_id": clientID]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyObj) else {
            throw ComfyUIError.decodeFailed("could not encode workflow")
        }

        // Open the live-progress socket *before* submitting so no early `executing`/`progress` frame is
        // missed. Binds to our clientID (the same one in the submit body) or the server drops our frames.
        let tracker = ProgressTracker(baseURL: base)
        _ = tracker.start(clientId: clientID)

        onProgress(ComfyUIProgress(isDenoising: false, phaseLabel: "Submitting…", totalNodes: totalNodes))
        do {
            let promptID = try await submit(data: data)
            onProgress(ComfyUIProgress(isDenoising: true, phaseLabel: "Queued…", totalNodes: totalNodes))

            // Concurrent consumer: translate each live snapshot into a ComfyUIProgress for the UI. The node
            // position is derived from the ordered executedNodes list (1-based index of current + 1), so even
            // without per-step frames the user sees "Node X / N" advance as nodes complete.
            // Both progressTask (real websocket frames) and tickerTask (1s elapsed-clock heartbeat) feed the same onProgress. Without
            // shared state the status line flip-flops between a real "Node X/N" frame and the ticker's bare "Generating".
            // lastPhase/lastNode carry whatever the latest real frame reported so the ticker never regresses the readout — it only keeps
            // the elapsed clock ticking when frames are sparse. No lock: both tasks inherit this method's main-actor isolation, so they
            // never run at the same time and each read-modify-write below completes without an intervening `await`.
            var lastPhase: String?
            var lastNode = 0
            func publish(phase: String?, node: Int) {
                onProgress(ComfyUIProgress(isDenoising: true, phaseLabel: phase, currentNode: node, totalNodes: totalNodes))
            }
            let progressTask = Task {
                for await snap in tracker.progressStream where !Task.isCancelled {
                    let nodePos = snap.nodeID
                        .flatMap { snap.executedNodes.firstIndex(of: $0) }
                        .map { $0 + 1 } ?? snap.executedNodes.count
                    lastPhase = snap.phaseLabel
                    if nodePos > lastNode {
                        lastNode = nodePos
                    }
                    publish(phase: snap.phaseLabel, node: lastNode)
                }
            }

            // Heartbeat ticker: fire a coarse denoising frame every second so the caller's elapsed clock keeps
            // updating even on builds that send no websocket `executing`/`progress` frames through the handler. It carries forward the last
            // real node/phase, never regressing them.
            let tickerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled {
                        break
                    }
                    publish(phase: lastPhase ?? "Generating", node: lastNode)
                }
            }

            defer {
                progressTask.cancel()
                tickerTask.cancel()
                tracker.stop()
            }

            let deadline = Date().addingTimeInterval(TimeInterval(maxWaitSeconds))
            // A transient LAN blip drops a /history fetch without failing the server-side run, so one bad poll must not kill an hour-long
            // job. Tolerate up to `maxConsecutiveHistoryFailures` consecutive transport failures (reset by any successful fetch) before
            // rethrowing; permanent loss still surfaces within about a minute at the default 1 Hz rate.
            var consecutiveFetchFailures = 0
            while Date() < deadline {
                if Task.isCancelled {
                    throw CancellationError()
                }
                do {
                    let record = try await fetchHistory(promptID: promptID)
                    consecutiveFetchFailures = 0

                    switch record.completed {
                    case true?:
                        guard !record.outputs.isEmpty else { throw ComfyUIError.noImageOutput }
                        onProgress(ComfyUIProgress(currentStep: totalSteps, totalSteps: totalSteps, isDenoising: true))
                        return record.outputs
                    // A failed prompt surfaces here two ways, both of which must fail the job — polling that only looks for a
                    // success never returns and Image Studio sits at "Generating…" until 1h or manual cancel:
                    //   1. `completed == false` with an execution_error entry in status.messages (e.g. CUDA OOM) — this build's shape;
                    //   2. no `completed` key but a terminal error message present — older ComfyUI writes only {"status": "error"}.
                    case false?:
                        let detail = (record.errorMessage ?? record.statusMessage).flatMap { $0.isEmpty ? nil : $0 }
                        throw ComfyUIError.executionFailed(detail ?? "the server reported an execution failure with no details")
                    case nil:
                        if let message = record.errorMessage {
                            throw ComfyUIError.executionFailed(message)
                        }
                        // still running → poll again
                    }

                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                } catch let e as ComfyUIError {
                    throw e // genuine terminal failure — surface immediately, no blip tolerance
                } catch {
                    consecutiveFetchFailures += 1
                    guard consecutiveFetchFailures < Self.maxConsecutiveHistoryFailures else { throw error }
                    // Keep the poll rhythm instead of hot-looping a dead endpoint.
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }
            }
        } catch {
            tracker.stop()
            throw error
        }
        throw ComfyUIError.unreachable("timed out waiting for prompt")
    }

    /// Submits an already-encoded workflow body; returns the server-minted `prompt_id`.
    private func submit(data: Data) async throws -> String {
        guard let url = URL(string: base + "/prompt") else { throw ComfyUIError.invalidURL(base) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.allHTTPHeaderFields = headers()
        req.httpBody = data

        let (respData, response): (Data, URLResponse)
        do { (respData, response) = try await session.data(for: req) } catch {
            throw ComfyUIError.unreachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw ComfyUIError.unreachable("no HTTP status") }
        if !(200 ..< 300).contains(http.statusCode) {
            throw ComfyUIError.httpStatus(http.statusCode, extractErrorMessage(String(data: respData, encoding: .utf8) ?? ""))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
              let pid = json["prompt_id"] as? String else {
            throw ComfyUIError.decodeFailed("no prompt_id in /prompt response")
        }
        return pid
    }

    /// Uploads a local image to the server's input dir via multipart `POST /upload/image` and returns
    /// the server-side filename (for a `LoadImage` node's `image` input). Mirrors `scripts/comfy_dry_run.py`'s
    /// `upload_image`. Called once per i2i job (before the per-seed render) so every seed references the
    /// same uploaded file.
    func uploadKreaImage(localPath: String) async throws -> String {
        guard let url = URL(string: base + "/upload/image") else { throw ComfyUIError.invalidURL(base) }
        let fileURL = URL(fileURLWithPath: localPath)
        guard let fileData = try? Data(contentsOf: fileURL) else {
            throw ComfyUIError.decodeFailed("could not read image file: \(localPath)")
        }
        let boundary = "----mlxbits" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"image\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        var h = headers()
        h["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        req.allHTTPHeaderFields = h
        req.httpBody = body

        let (respData, response): (Data, URLResponse)
        do { (respData, response) = try await session.data(for: req) } catch {
            throw ComfyUIError.unreachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ComfyUIError.unreachable("no HTTP status") }
        if !(200 ..< 300).contains(http.statusCode) {
            throw ComfyUIError.httpStatus(http.statusCode, extractErrorMessage(String(data: respData, encoding: .utf8) ?? ""))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
              let name = json["name"] as? String else {
            throw ComfyUIError.decodeFailed("no name in /upload/image response")
        }
        return name
    }

    /// Fetches and decodes `/history/{id}`. A 404 / empty object means "still pending" → all-empty record.
    private func fetchHistory(promptID: String) async throws -> HistoryRecord {
        guard let url = URL(string: base + "/history/\(promptID)") else { throw ComfyUIError.invalidURL(base) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.allHTTPHeaderFields = headers()

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) } catch {
            throw ComfyUIError.unreachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw ComfyUIError.unreachable("no HTTP status") }
        if !(200 ..< 300).contains(http.statusCode) {
            return HistoryRecord()
        } // pending → not found yet

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let record = json[promptID] as? [String: Any] else {
            return HistoryRecord() // still pending → empty object
        }

        var out = HistoryRecord()
        if let statusObj = record["status"] as? [String: Any] {
            out.completed = statusObj["completed"] as? Bool
            out.statusMessage = statusObj["status_str"] as? String

            // Real failure diagnostics live in `messages`: entries `[kind, payload]` where kind mentions error. The OOM shape is an
            // "execution_error" whose payload is a dict (exception_type / node_id / exception_message / traceback). Do NOT JSON-serialize
            // the whole payload: it embeds every live input tensor of the failing node (~5 MB for one 1920×1088 latent) and would bloat
            // job.log. Keep only selected fields; unrecognized payloads fall back to a bounded raw slice.
            if let messages = statusObj["messages"] as? [[Any]] {
                for entry in messages {
                    guard entry.count >= 2,
                          let kind = entry[0] as? String,
                          kind.lowercased().contains("error") || kind.lowercased().contains("exception") else { continue }
                    out.errorMessage = Self.formatErrorMessage(kind: kind, payload: entry[1])
                    break
                }
            }
        }
        if let nodes = record["outputs"] as? [String: Any] {
            for (_, nodeOut) in nodes {
                guard let outDict = nodeOut as? [String: Any],
                      let images = outDict["images"] as? [[String: Any]] else { continue }
                for img in images {
                    if let fn = img["filename"] as? String, !fn.isEmpty {
                        out.outputs.append(ComfyOutputFile(
                            filename: fn,
                            subfolder: (img["subfolder"] as? String) ?? "",
                            type: (img["type"] as? String) ?? "output"
                        ))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Image fetch
    /// Downloads one server-side output image to a local path. Returns true on success. Tries the `filename` as reported
    /// (a slash in it is passed through and resolves against the server's output dir); if that misses, retries with the last
    /// path component as `filename` and the remainder as `subfolder` — so both flat (`mlxbits/krea2_…png`) and genuinely nested
    /// outputs are served by the same call.
    func downloadOutput(filename: String, subfolder: String? = nil, type: String = "output", to localPath: String) async -> Bool {
        var candidates: [(String, String)] = [(filename, subfolder ?? "")]
        if let slash = filename.lastIndex(of: "/"), (subfolder ?? "").isEmpty {
            let head = String(filename[..<slash])
            let tail = String(filename[filename.index(after: slash)...])
            candidates.append((tail, head))
        }
        for (fn, sub) in candidates where await fetchView(filename: fn, subfolder: sub.isEmpty ? nil : sub, type: type, to: localPath) {
            return true
        }
        return false
    }

    /// One `/view` round-trip for a single (filename, subfolder) pair.
    private func fetchView(filename: String, subfolder: String?, type: String, to localPath: String) async -> Bool {
        var query = "?filename=\(filename.urlQueryEscaped)&type=\(type)"
        if let subfolder, !subfolder.isEmpty {
            query += "&subfolder=\(subfolder.urlQueryEscaped)"
        }
        guard let url = URL(string: base + "/view" + query) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.allHTTPHeaderFields = headers()
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode), !data.isEmpty else { return false }
            let dir = (localPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: localPath))
            return true
        } catch { return false }
    }

    // MARK: - Interrupt (cooperative cancel)

    func interrupt() async {
        guard let url = URL(string: base + "/interrupt") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.allHTTPHeaderFields = headers()
        _ = try? await session.data(for: req)
    }

    /// Frees VRAM and (optionally) unloads every resident model — ComfyUI's global `POST /free`. There is no
    /// per-model eject, so this is the whole-pill "eject" action. Best-effort like ``interrupt()``: a dead server
    /// shouldn't surface as an error from a housekeeping click; the next poll simply still shows residency and
    /// the user retries. `unloadModels` alone (no GC) is enough to vacate weights while keeping ComfyUI's own
    /// allocator warm for the next run.
    func freeModels(unload: Bool = true, clearMemory: Bool = false) async {
        guard let url = URL(string: base + "/free") else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.allHTTPHeaderFields = headers()
        if let body = try? JSONSerialization.data(withJSONObject: ["unload_models": unload, "free_memory": clearMemory]) {
            req.httpBody = body
        }
        _ = try? await session.data(for: req)
    }

    // MARK: - Raw helpers

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: base + path) else { throw ComfyUIError.invalidURL(base) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.allHTTPHeaderFields = headers()
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw ComfyUIError.unreachable("no HTTP status") }
            if !(200 ..< 300).contains(http.statusCode) {
                throw ComfyUIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        } catch let e as URLError where e.code == .timedOut || e.code == .cannotConnectToHost {
            throw ComfyUIError.unreachable(e.localizedDescription)
        } catch let e as ComfyUIError { throw e }
    }

    /// /prompt 400 body is `{"error":{type,message,...},"node_errors":{...}}`. The generic `message`
    /// ("Prompt outputs failed validation") hides the cause — the real diagnosis lives in `node_errors`,
    /// so surface it here (e.g. which node and field like a missing `weight_dtype`).
    private func extractErrorMessage(_ jsonBody: String) -> String {
        guard let data = jsonBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return jsonBody }

        var message: String
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            message = msg
        } else if let err = json["error"] as? String {
            message = err
        } else {
            return jsonBody
        }

        // Append per-node validation details so the user sees exactly what to fix.
        guard let nodeErrors = json["node_errors"] as? [String: Any] else { return message }
        var lines: [String] = []
        for (nodeID, entry) in nodeErrors.sorted(by: { $0.key < $1.key }) {
            guard let obj = entry as? [String: Any], let errors = obj["errors"] as? [[String: Any]] else { continue }
            let classType = obj["class_type"] as? String ?? "node"
            for e in errors {
                var part = "[\(nodeID) \(classType)] \(e["message"] as? String ?? "")"
                if let detail = e["details"] as? String, !detail.isEmpty {
                    part += ": \(detail)"
                }
                lines.append(part)
            }
        }
        return lines.isEmpty ? message : message + "\n\n" + lines.joined(separator: "\n")
    }
}

// MARK: - Transport for sibling-file extensions

/// `private` members aren't visible from `ComfyUIClient+*.swift`; these are the requests those extensions make.
extension ComfyUIClient {
    /// Test seam: inject a session whose protocol classes stub the transport (tests are `@testable`).
    convenience init(config: Config, session: URLSession) {
        self.init(config: config)
        self.session = session
    }

    /// GET `path` with this client's auth headers; returns the 2xx response body.
    func getData(_ path: String) async throws -> Data {
        try await get(path)
    }

    /// POST `body` to `path` with this client's auth headers and `contentType`; returns the 2xx response body.
    func post(_ path: String, body: Data, contentType: String, timeout: TimeInterval = 120) async throws -> Data {
        guard let url = URL(string: base + path) else { throw ComfyUIError.invalidURL(base) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        var hdrs = headers()
        hdrs["Content-Type"] = contentType
        req.allHTTPHeaderFields = hdrs
        req.httpBody = body
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) } catch {
            throw ComfyUIError.unreachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ComfyUIError.unreachable("no HTTP status") }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ComfyUIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

// MARK: - Small helpers

private extension String {
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
