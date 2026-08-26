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
//
// Output routing: ComfyUI's SaveImage node takes `filename_prefix` as a *single-level* path component (verified on the
// live 0.33 server: prefix "a/b" → file lands in subfolder "a", named "b_…"). So we set it to "mlxbits/" and remote results
// land in output/mlxbits/; /history reports that as `subfolder`, and downloadOutput resolves it (see the slash fallback).

enum ComfyUIError: LocalizedError {
    case invalidURL(String)
    case unreachable(String)
    case httpStatus(Int, String)
    case graphRejected(String)
    case noImageOutput
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(base):
            return "Invalid ComfyUI endpoint URL: \(base). Expected something like http://192.168.x.x:8188"
        case let .unreachable(detail):
            return "Could not reach the ComfyUI server (\(detail)). Is it running?"
        case let .httpStatus(code, body):
            var msg = "ComfyUI returned status \(code):\n…\(body.suffix(600))"
            if code >= 500 && !body.contains("\"error\"") && !body.hasPrefix("{") {
                msg += "\n\nThis is a generic server-internal error — the real traceback printed to your "
                    + "ComfyUI server's console. Check the terminal where `main.py` is running for the failing node/field."
            }
            return msg
        case let .graphRejected(msg):
            return "The workflow was rejected by the server:\n…\(msg.suffix(500))"
        case .noImageOutput:
            return "The prompt finished but produced no output image."
        case let .decodeFailed(detail):
            return "Could not parse the ComfyUI response: \(detail)"
        }
    }
}

/// A LoRA attachment for a remote workflow, keyed by the *server-side* filename in `models/loras`
/// (not a local macOS path) plus its strength. Decoupled from ``LoraEntry`` so it works without any
/// file on this machine.
struct ComfyLora: Equatable {
    var name: String
    var strength: Double
}

/// Resolves a LoRA's `path` to the exact value a ComfyUI `LoraLoader.lora_name` node accepts. Server-cataloged entries carry a
/// `/models/loras`-relative name (possibly with a subfolder prefix, e.g. `krea2/foo.safetensors`) that is submitted verbatim; only an
/// absolute local file path needs basename reduction (a fallback for any hand-entered entry that still resolves to a top-level server
/// file).
func resolverServerLoraName(_ path: String) -> String {
    path.hasPrefix("/") ? URL(fileURLWithPath: path).lastPathComponent : path
}

/// Available models/samplers reported by `/object_info`, used to populate the pickers.
struct ComfyModelInfo: Equatable {
    var unets: [String] = []
    var clips: [String] = []
    var vaes: [String] = []
    var loras: [String] = []
    var samplers: [String] = []
    var schedulers: [String] = []

    static let empty = Self()
}

/// One server-side output file, as recorded under a node's `outputs` in the history record.
struct ComfyOutputFile: Equatable {
    var filename: String
    var subfolder: String
    var type: String // "output" | "temp" | "input"
}

/// Progress reported while a prompt runs, mapped onto the step/total shape the runner uses. The
/// PoC polls `/history` (no live step counts from that endpoint), so `isDenoising` flips on submit
/// and completes when outputs appear; `phaseLabel` carries coarse stage text for the status line.
struct ComfyUIProgress: Equatable {
    var currentStep: Int = 0
    var totalSteps: Int = 0
    var isDenoising: Bool = false
    var phaseLabel: String?
    /// Which node of the workflow is executing now (1-based), when known.
    var currentNode: Int = 0
    /// Total nodes in the submitted workflow, so "node X of N" can be shown.
    var totalNodes: Int = 0

    static let empty = Self()
}

/// Network client for a running ComfyUI server. Deliberately NOT main-actor-isolated: its methods do
/// URLSession I/O and are called from background tasks by ``JobRunner``/the store, so keep them off-main.
final class ComfyUIClient {
    struct Config {
        /// Base URL, normalized to have no trailing slash (e.g. http://192.168.1.50:8188).
        var baseURL: String
        /// Optional bearer token for servers with auth enabled; nil/empty = none.
        var apiKey: String?

        static func normalize(_ raw: String) -> String {
            var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") {
                base.removeLast()
            }
            return base
        }
    }

    private let config: Config
    /// Unique id for this client; sent as `client_id` so the server can attribute runs.
    let clientID = UUID().uuidString
    private let session: URLSession

    init(config: Config) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        // First model load into VRAM can be slow; allow generous timeouts.
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 1800
        session = URLSession(configuration: cfg)
    }

    private var base: String {
        config.baseURL
    }

    private func headers() -> [String: String] {
        if let key = config.apiKey, !key.isEmpty {
            return ["Authorization": "Bearer \(key)", "Content-Type": "application/json"]
        }
        return ["Content-Type": "application/json"]
    }

    // MARK: - Connection test / system stats

    struct SystemStats {
        var serverVersion: String?
        var os: String?
        var gpuNames: [String] = []
        var vramTotalGb: Double?

        /// One-line summary for the Settings "Test Connection" button.
        var summary: String {
            let gpu = gpuNames.isEmpty ? "no GPU reported" : gpuNames.joined(separator: ", ")
            let vram = vramTotalGb.map { String(format: " · %.1f GB VRAM", $0) } ?? ""
            return "ComfyUI \(serverVersion ?? "unknown") on \(os ?? "?") — \(gpu)\(vram)"
        }
    }

    /// Hits `/system_stats` — the cheap liveness + "did we reach the right box" check.
    func systemStats() async throws -> SystemStats {
        let data = try await get("/system_stats")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ComfyUIError.decodeFailed("unexpected /system_stats shape")
        }
        var stats = SystemStats()
        if let comfy = json["comfyui"] as? [String: Any], let info = comfy["info"] as? [String: Any] {
            stats.serverVersion = info["version"] as? String
            stats.os = info["os"] as? String
        }
        if let devices = json["devices"] as? [[String: Any]] {
            for d in devices {
                if let name = d["name"] as? String, !name.isEmpty {
                    stats.gpuNames.append(name)
                }
                if let vram = d["vram_total"] as? Double {
                    stats.vramTotalGb = vram / 1_073_741_824
                }
            }
        }
        return stats
    }

    /// Pulls available UNet / CLIP / VAE / sampler lists from `/object_info`. Each loader list is read from the
    /// node that actually enumerates it on this server (verified live), not `CheckpointLoaderSimple`, which only
    /// holds monolithic checkpoints and had none of Krea 2's separate model files. LoRAs are fetched separately via
    /// ``fetchLoras()`` from `/models/loras` — the dedicated endpoint that returns *full relative* filenames
    /// (e.g. `krea2/foo.safetensors`), including any subfolder prefix, exactly as the server's node dropdown shows them.
    func discoverModels() async throws -> ComfyModelInfo {
        let data = try await get("/object_info")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ComfyUIError.decodeFailed("unexpected /object_info shape")
        }
        var info = ComfyModelInfo()

        func optionsFor(_ cls: String, _ key: String) -> [String]? {
            guard let node = json[cls] as? [String: Any],
                  let input = node["input"] as? [String: Any],
                  let required = input["required"] as? [String: Any],
                  let field = required[key] else { return nil }
            // ComfyUI encodes model lists as `[ ["file1", "file2", …], {optional metadata} ]` — a two-element
            // array whose first element is the string list. Handle both that and a bare `{"options": [...]}` shape.
            if let arr = field as? [Any], let opts = arr.first as? [String] {
                return opts
            }
            if let dict = field as? [String: Any], let opts = dict["options"] as? [String] {
                return opts
            }
            return nil
        }

        info.unets = optionsFor("UNETLoader", "unet_name") ?? []
        info.clips = optionsFor("CLIPLoader", "clip_name") ?? []
        info.vaes = optionsFor("VAELoader", "vae_name") ?? []
        info.loras = try await fetchLoras()
        info.samplers = optionsFor("KSampler", "sampler_name") ?? ["euler"]
        info.schedulers = optionsFor("KSampler", "scheduler") ?? ["normal"]
        return info
    }

    /// Fetches the full list of LoRA filenames from `/models/loras`. Returns the names verbatim, which are relative
    /// paths with a subfolder prefix when present (e.g. `krea2/Krea2-realism-V2.safetensors`) and bare basenames for
    /// top-level files. These strings are exactly what a `LoraLoader.lora_name` node accepts, so they double as both the
    /// cataloging identity key and the workflow submission value — no transformation needed either way. Verified live:
    /// this endpoint is path-preserving on ComfyUI 0.33 (unlike `/object_info`, which omits subfolder structure in some builds).
    func fetchLoras() async throws -> [String] {
        let data = try await get("/models/loras")
        guard let names = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            throw ComfyUIError.decodeFailed("unexpected /models/loras shape — expected a JSON array of filenames")
        }
        return names.filter { !$0.isEmpty }
    }

    // MARK: - Workflow building (PoC: Krea2 UNet text-to-image graph)
    //
    // Verified against the live ComfyUI server via /object_info + a real POST /prompt. Krea2's model is
    // a fp8 *diffusion UNet* living in `models/unet`, not a monolithic checkpoint — so it loads through
    // three separate loaders (UNETLoader → MODEL, CLIPLoader with type="krea2" → CLIP, VAELoader → VAE),
    // not CheckpointLoaderSimple (which only reads `models/checkpoints` and has no krea2 file there).
    // EmptyLatentImage requires batch_size on this server version. LoRAs chain LoraLoader nodes feeding
    // the next loader; KSampler consumes the final model/clip/vae — your saved stacks plug in here.

    struct WorkflowInput {
        var prompt: String
        var negativePrompt: String?
        var width: Int
        var height: Int
        var steps: Int
        var cfg: Double
        var seed: Int
        /// Server-side UNet filename (`models/unet`), e.g. `krea2_turbo_fp8_scaled.safetensors`.
        var unetName: String
        /// Server-side CLIP text-encoder filename (`models/clip`).
        var clipName: String
        /// CLIPLoader pipeline type; "krea2" is the server's first-class Krea 2 encoder.
        var clipType: String = "krea2"
        /// Server-side VAE filename (`models/vae`).
        var vaeName: String
        /// UNETLoader `weight_dtype`. Required (advanced) on current ComfyUI. `"default"` lets the server
        /// honor the dtype stored inside the weights file — correct for fp8 checkpoints like Krea 2's.
        var weightDtype: String = "default"
        var loras: [ComfyLora] = []
        var sampler: String = "euler"
        var scheduler: String = "normal"
        /// Server-side output subfolder for the SaveImage node, appended as a path component to the `mlxbits` filename prefix.
        /// ComfyUI treats it as a *single* level (a slash does not nest), so `"krea2"` → `output/mlxbits/…`. Empty uses just `mlxbits`.
        var saveSubfolder: String = ""
    }

    /// Builds the Krea2 graph as the `/prompt` wire form `{nodeID:{class_type, inputs}}`.
    func buildKrea2Workflow(_ input: WorkflowInput) -> Any {
        var raw: [String: Any] = [:]

        // Source of the latent to denoise (text-to-image → empty noise). KSampler + this server require batch_size.
        let emptyID = "EMPTY"
        raw[emptyID] = ["class_type": "EmptyLatentImage", "inputs": ["width": input.width, "height": input.height, "batch_size": 1]]

        // Model source: UNet (a diffusion model, not a checkpoint), with any LoRAs chained in front of KSampler.
        let unetID = "UNET"
        raw[unetID] = ["class_type": "UNETLoader", "inputs": ["unet_name": input.unetName, "weight_dtype": input.weightDtype]]

        // CLIP text encoder + VAE are separate loaders for this pipeline (Krea2 uses the server's krea2 clip type).
        let clipID = "CLIPL"
        raw[clipID] = ["class_type": "CLIPLoader", "inputs": ["clip_name": input.clipName, "type": input.clipType]]
        let vaeID = "VAEL"
        raw[vaeID] = ["class_type": "VAELoader", "inputs": ["vae_name": input.vaeName]]

        // LoRAs chain as a series. On this ComfyUI version the LoraLoader's output is `['MODEL', 'CLIP']` (index 0 = MODEL,
        // index 1 = CLIP) and it has NO vae input/output — verified against /object_info on the live server. So each lora consumes
        // the previous node's model (slot 0) and clip (slot 1 for a LoraLoader, slot 0 for a loader), re-emitting both; VAE never
        // passes through a LoRA, so VAEDecode always reads the base VAELoader. Reading a lora's CLIP from slot 0 (its MODEL) is what
        // produced "Return type mismatch ... received_type(MODEL)" for two-plus LoRAs.
        var upstreamModel = unetID
        var upstreamClip: [Any] = [clipID, 0] // first lora's clip comes from the base CLIPLoader (single CLIP output, slot 0)
        for (i, lora) in input.loras.enumerated() {
            let id = "LORA_\(i)"
            raw[id] = [
                "class_type": "LoraLoader",
                "inputs": [
                    "model": [upstreamModel, 0], // MODEL from previous unet/lora (slot 0 on both node kinds)
                    "clip": upstreamClip, // CLIP from base CLIPLoader, or the previous lora's slot-1 CLIP output
                    "lora_name": lora.name,
                    "strength_model": lora.strength,
                    "strength_clip": lora.strength,
                ],
            ]
            upstreamModel = id
            upstreamClip = [id, 1] // this lora re-emits CLIP at output slot 1 (MODEL is slot 0)
        }

        let clipPosID = "CLIP_POS"
        raw[clipPosID] = ["class_type": "CLIPTextEncode", "inputs": ["text": input.prompt, "clip": upstreamClip]]
        var hasNeg = false
        if let neg = input.negativePrompt, !neg.isEmpty {
            hasNeg = true
            raw["CLIP_NEG"] = ["class_type": "CLIPTextEncode", "inputs": ["text": neg, "clip": upstreamClip]]
        }

        var ks: [String: Any] = [
            "model": [upstreamModel, 0],
            "positive": [clipPosID, 0],
            "negative": hasNeg ? ["CLIP_NEG", 0] as [Any] : [clipPosID, 0] as [Any],
            "latent_image": [emptyID, 0],
            "seed": input.seed,
            "steps": input.steps,
            "cfg": input.cfg,
            "sampler_name": input.sampler,
            "scheduler": input.scheduler,
            "denoise": 1.0,
        ]
        raw["KSAMPLER"] = ["class_type": "KSampler", "inputs": ks]

        let decodeID = "DECODE"
        raw[decodeID] = ["class_type": "VAEDecode", "inputs": ["samples": ["KSAMPLER", 0], "vae": [vaeID, 0]]]
        // SaveImage writes to the server's output dir; we fetch it back via /view by filename. The `mlxbits/<family>` prefix
        // lands remote results in a per-family subfolder on the *server* (e.g. output/mlxbits/krea2/) without touching its config.
        let prefix = input.saveSubfolder.isEmpty ? "mlxbits" : "mlxbits/\(input.saveSubfolder)"
        raw["SAVE"] = ["class_type": "SaveImage", "inputs": ["images": [decodeID, 0], "filename_prefix": prefix]]

        var payload: [String: Any] = [:]
        for (id, def) in raw {
            payload[id] = def
        }
        return payload
    }

    // MARK: - Submit + track + fetch

    /// Submits a workflow and returns its server-side output files once `/history/{id}` reports them.
    /// Live progress is driven by the websocket `ProgressTracker` (real KSampler step counts), while
    /// the `/history` poll remains the *sole* completion/failure authority — so if the socket drops,
    /// the run still completes and the UI simply degrades to a coarse "Generating…" label.
    func generate(
        _ input: WorkflowInput,
        totalNodes: Int,
        onProgress: @escaping (ComfyUIProgress) -> Void,
        pollInterval: TimeInterval = 1.0,
        maxWaitSeconds: Int = 3600
    ) async throws -> [ComfyOutputFile] {
        let payload = buildKrea2Workflow(input)
        let bodyObj: [String: Any] = ["prompt": payload, "client_id": clientID]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyObj) else {
            throw ComfyUIError.decodeFailed("could not encode workflow")
        }

        // Open the live-progress socket *before* submitting so no early `executing`/`progress` frame is
        // missed. Binds to our clientID (the same one in the submit body) or the server drops our frames.
        let tracker = ProgressTracker(baseURL: base)
        _ = tracker.start(clientId: clientID)

        var firstDenoiseAt: Date?
        onProgress(ComfyUIProgress(isDenoising: false, phaseLabel: "Submitting…", totalNodes: totalNodes))
        do {
            let promptID = try await submit(data: data)
            onProgress(ComfyUIProgress(isDenoising: true, phaseLabel: "Queued…", totalNodes: totalNodes))

            // Concurrent consumer: translate each live snapshot into a ComfyUIProgress for the UI. The node
            // position is derived from the ordered executedNodes list (1-based index of current + 1), so even
            // without per-step frames the user sees "Node X / N" advance as nodes complete.
            let progressTask = Task { [weak self] in
                guard let self else { return }
                for await snap in tracker.progressStream where !Task.isCancelled {
                    if firstDenoiseAt == nil && (snap.phaseLabel == "Denoising" || snap.nodeID == "KSAMPLER") {
                        firstDenoiseAt = Date()
                    }
                    let nodePos = snap.executedNodes.contains(snap.nodeID ?? "")
                        ? (snap.executedNodes.firstIndex(of: snap.nodeID!)! + 1)
                        : snap.executedNodes.count
                    onProgress(ComfyUIProgress(
                        currentStep: snap.step,
                        totalSteps: max(snap.totalSteps, input.steps),
                        isDenoising: true,
                        phaseLabel: snap.phaseLabel,
                        currentNode: nodePos,
                        totalNodes: totalNodes
                    ))
                }
            }

            // Heartbeat ticker: fire a coarse denoising frame every second so the caller's elapsed clock keeps
            // updating even on builds that send no websocket `executing`/`progress` frames through the handler.
            let tickerTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled {
                        break
                    }
                    onProgress(ComfyUIProgress(isDenoising: true, phaseLabel: "Generating", totalNodes: totalNodes))
                }
            }

            defer {
                progressTask.cancel()
                tickerTask.cancel()
                tracker.stop()
            }

            let deadline = Date().addingTimeInterval(TimeInterval(maxWaitSeconds))
            while Date() < deadline {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let record = try await fetchHistory(promptID: promptID)

                switch record.completed {
                case true?:
                    guard !record.outputs.isEmpty else { throw ComfyUIError.noImageOutput }
                    onProgress(ComfyUIProgress(currentStep: input.steps, totalSteps: input.steps, isDenoising: true))
                    return record.outputs
                case false?:
                    // Genuine failure. Prefer the real diagnostic from `status.messages`; fall back to status_str.
                    let detail = record.errorMessage ?? record.statusMessage
                    throw ComfyUIError
                        .graphRejected(detail?.isEmpty == false ? detail! : "the server reported an execution failure with no details")
                case nil:
                    break // still running → poll again
                }

                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
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

    struct HistoryRecord {
        var statusMessage: String? // raw `status_str` label — reads "success" on completion, so not an error indicator by itself.
        /// Best available diagnostic from `status.messages` (the entry whose kind contains "error"/"exception"), else nil.
        var errorMessage: String?
        var completed: Bool? // from record["status"]["completed"]; nil = still running / not present yet
        var outputs: [ComfyOutputFile] = []
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

            // Real failure diagnostics live in `messages`: entries `[kind, payload]` where kind mentions error.
            if let messages = statusObj["messages"] as? [[Any]] {
                for entry in messages {
                    guard entry.count >= 2,
                          let kind = entry[0] as? String,
                          kind.lowercased().contains("error") || kind.lowercased().contains("exception") else { continue }
                    let payload = entry[1]
                    if let s = payload as? String, !s.isEmpty {
                        out.errorMessage = "\(kind): \(s)"
                    } else if let data = try? JSONSerialization.data(withJSONObject: [payload], options: [.sortedKeys]),
                              let text = String(data: data, encoding: .utf8) {
                        out.errorMessage = "\(kind): …\(text.suffix(1200))"
                    } else {
                        out.errorMessage = kind
                    }
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
        if filename.contains("/"), (subfolder ?? "").isEmpty {
            let slash = filename.lastIndex(of: "/")!
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
            if n == "DECODE" || n == "SAVE" {
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
    final class ProgressTracker: @unchecked Sendable {
        private let baseURL: String
        private var task: URLSessionWebSocketTask?
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
            comps.path = "/ws"
            comps.queryItems = [URLQueryItem(name: "clientId", value: clientId)]
            guard let connectURL = comps.url else {
                continuation.finish()
                return false
            }

            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 60 // handshake only; the stream itself is unbounded
            cfg.timeoutIntervalForResource = .infinity
            let task = URLSession(configuration: cfg).webSocketTask(with: connectURL)
            self.task = task
            task.resume()
            receiveLoop(task: task)
            return true
        }

        /// Last-running-node id, mutated by the websocket read loop (arrives on the URL session queue);
        /// only ever read to build the current snapshot, so a plain stored var suffices.
        private var lastNodeID: String?
        /// Distinct node ids in first-seen order; grown by the read loop as `executing` frames arrive.
        private var executedNodes: [String] = []

        /// Recursively drains the socket, yielding a snapshot for each progress-relevant frame.
        private func receiveLoop(task: URLSessionWebSocketTask) {
            task.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(message):
                    if let snap = Self.decode(message, lastNodeID: &self.lastNodeID, executedNodes: &self.executedNodes) {
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

        /// Maps one raw websocket text frame to a LiveProgress snapshot, or nil if the frame carries no
        /// progress-relevant data (status heartbeats, custom-node noise such as `crystools.monitor`, etc.).
        /// `executedNodes` accumulates distinct node ids in first-seen order so consumers can derive "node X of N".
        static func decode(
            _ message: URLSessionWebSocketTask.Message,
            lastNodeID: inout String?,
            executedNodes: inout [String]
        ) -> LiveProgress? {
            guard case let .data(data) = message else { return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

        func stop() {
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            continuation.finish()
        }
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

// MARK: - Small helpers

private extension String {
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
