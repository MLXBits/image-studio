import Foundation

// MARK: - ComfyUI value types

enum ComfyUIError: LocalizedError {
    case invalidURL(String)
    case unreachable(String)
    case httpStatus(Int, String)
    case graphRejected(String)
    case noImageOutput
    /// Execution finished with an error (node exception, CUDA OOM, …) — the failure diagnostic from status.messages.
    case executionFailed(String)
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
        case let .executionFailed(detail):
            return "ComfyUI execution failed:\n\(detail)"
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
    static let empty = Self()

    var unets: [String] = []
    var clips: [String] = []
    var vaes: [String] = []
    var loras: [String] = []
    var samplers: [String] = []
    var schedulers: [String] = []
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
    static let empty = Self()

    var currentStep: Int = 0
    var totalSteps: Int = 0
    var isDenoising: Bool = false
    var phaseLabel: String?
    /// Which node of the workflow is executing now (1-based), when known.
    var currentNode: Int = 0
    /// Total nodes in the submitted workflow, so "node X of N" can be shown.
    var totalNodes: Int = 0
}

// MARK: - History failure diagnostics

extension ComfyUIClient {
    /// Turns one `status.messages` `[kind, payload]` failure entry into the job-facing diagnostic. The OOM shape is an "execution_error"
    /// whose payload is a dict carrying exception_type / node_id / node_type / exception_message (plus traceback and — the trap — full
    /// input
    /// tensors). Keep exactly what lets the user fix it; cap at 1600 chars so a pathological message can't bloat job.log.
    static func formatErrorMessage(kind: String, payload: Any) -> String {
        if let s = payload as? String, !s.isEmpty {
            return String("\(kind): \(s)".prefix(1600))
        }
        guard let obj = payload as? [String: Any] else {
            if let data = try? JSONSerialization.data(withJSONObject: [payload], options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return "\(kind): …\(text.suffix(1200))"
            }
            return kind
        }
        var parts: [String] = []
        if let t = obj["exception_type"] as? String, !t.isEmpty {
            parts.append(t)
        } else {
            parts.append(kind)
        }
        if let n = obj["node_id"] as? String, !n.isEmpty {
            let nodeType = obj["node_type"] as? String ?? ""
            let type = nodeType.isEmpty ? "" : " \(nodeType)"
            parts.append("[node \(n)\(type)]")
        }
        if let msg = obj["exception_message"] as? String, !msg.isEmpty {
            parts.append(msg)
        } else if let data = try? JSONSerialization.data(withJSONObject: [obj], options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) {
            // Unrecognized payload shape: show a bounded slice rather than the whole thing.
            parts.append("…\(text.suffix(1200))")
        }
        return String(parts.joined(separator: " ").prefix(1600))
    }
}
