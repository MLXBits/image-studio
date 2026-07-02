import Foundation

// MARK: - Warm-driver protocol types
//
// NDJSON messages exchanged with Resources/mflux_driver.py over stdio.
// Requests encode to snake_case; events decode from snake_case. The driver
// ignores keys it doesn't know, so requests may carry app-only fields
// (modelVariantRaw, modelLabel) used to render the header chip.

/// Text-encoder residency policy sent with each generate request. `auto`
/// resolves to keep/evict app-side from measured peak memory vs physical RAM.
enum WarmTextEncoderPolicy: String, Codable, CaseIterable {
    case auto, keep, evict

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .keep: "Always keep"
        case .evict: "Always evict"
        }
    }
}

struct DriverOutput: Codable {
    let seed: Int
    let path: String
}

struct DriverGenerateRequest: Codable {
    var cmd: String = "generate"
    var id: String
    /// Warm-instance identity: resolved model + quantize + LoRA stack. A
    /// mismatch makes the driver unload before loading (never two resident).
    var fingerprint: String
    /// Resolved model argument (repo ID or local path), mirroring the CLI
    /// resolution in `FluxRunnerSpec.buildArgs`.
    var model: String
    /// Present only when falling back to in-memory quantization (BF16 base).
    var quantize: Int?
    var loraPaths: [String]
    var loraScales: [Double]
    var prompt: String
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Double
    var imagePath: String?
    var imageStrength: Double?
    /// Explicit per-seed output paths — the driver saves exactly here and
    /// emits an `image` event per path, so no filesystem reconciliation.
    var outputs: [DriverOutput]
    var stepwiseDir: String
    var tePolicy: String
    var cacheLimitGb: Double
    /// App-only: `FluxModelVariant.rawValue`, compared on model-picker
    /// switches to trigger proactive eviction.
    var modelVariantRaw: String
    /// App-only: human-readable name for the header warm-model chip.
    var modelLabel: String
}

/// One decoded driver event. `event` discriminates; the optional fields are
/// populated per event type (see mflux_driver.py's emit calls).
struct DriverEvent: Codable {
    let event: String
    var component: String?
    var seed: Int?
    var path: String?
    var step: Int?
    var total: Int?
    var seconds: Double?
    var memoryGb: Double?
    var peakGb: Double?
    var reason: String?
    var message: String?
    var cancelled: Bool?
    var fingerprint: String?
    var mfluxVersion: String?
    var loaded: Bool?
    var id: String?

    init(event: String, message: String? = nil) {
        self.event = event
        self.message = message
    }
}

enum DriverRunResult {
    case completed
    case cancelled
    case failed(String)
}
