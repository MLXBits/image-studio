import Foundation
import SwiftUI

/// Live residency status of the two *external* inference hosts this app can reach: a remote
/// ComfyUI server (the alternate image backend) and an LM Studio instance (the prompt-LLM
/// backend). Both sit on the same machine as local mflux runs, so their memory footprint is
/// exactly what the header needs to see — mirror of ``MfluxDriverController.loadedModelLabel``'s
/// pill, but for models this app never loads itself.
///
/// The two signals are asymmetric by design:
/// - **LM Studio** reports residency *directly* (`loaded_instances` per model). One instance per
///   model is the common case; the store aggregates across all of them and shows each loaded key.
/// - **ComfyUI** has no "what's resident" endpoint — only driver-level VRAM, whose *free* figure drops by the
///   size of whatever moved to the device. Note this must be *driver*-level `vram_free`, not torch's figure:
///   ComfyUI loads safetensors through the CUDA driver, so `torch_vram_free` barely moves even with a 30 GB
///   model resident (observed live: ~13 MB tracked while 29.5 GB was in use). Residency is simply GPU
///   occupancy (`vram_total − vram_free`) above an idle-overhead floor of ~1 GB — no baseline capture needed, so it
///   works even when the model was already loaded before this app (re)started.
@Observable
final class BackendModelStore {
    /// Poll cadence while at least one backend is configured and reachable. Generous — these are
    /// housekeeping reads, not run progress; a 5 s cycle keeps the pill responsive without churning
    /// the LAN or hammering a box already mid-render (each poll is a single small JSON GET).
    static let pollInterval: TimeInterval = 5

    /// GPU occupancy (bytes) that counts as *something resident*. An idle ComfyUI holds ~0–1 GB of driver and OS
    /// overhead on its card; above this floor, the delta is a loaded model. Kept at 1 GB so it tolerates normal
    /// idle variance while always surfacing a real diffusion model (~10 GB class or larger).
    static let residencyFloorBytes: Int64 = 1_073_741_824

    // MARK: - ComfyUI residency

    struct ComfyStatus: Equatable {
        var reachable = false
        /// Driver-level total VRAM (bytes) — `vram_total`. Constant for a given device. Paired with ``freeBytes`` to
        /// derive occupancy, which is the residency signal for the header pill.
        var totalBytes: Int64?
        /// Driver-level free VRAM (bytes) at the latest poll — `vram_free` from `/system_stats`. This is what
        /// actually tracks GPU occupancy, since ComfyUI loads safetensors through the CUDA driver rather than torch's
        /// allocator (the torch figure stays near-zero even with a large model resident). Occupancy =
        /// `totalBytes − freeBytes`; no baseline capture is needed because an *idle* ComfyUI holds ~0–1 GB of driver
        /// overhead regardless, so occupancy above that floor IS the residency — this works even when the model was
        /// already loaded before this app (re)started.
        var freeBytes: Int64?

        /// Current GPU occupancy in bytes (`total − free`), or `nil` until both figures are known.
        var occupiedBytes: Int64? {
            guard let t = totalBytes, let f = freeBytes else { return nil }
            return max(0, t - f)
        }
    }

    private(set) var comfy = ComfyStatus()
    /// Set between an eject click and the next poll that confirms the VRAM recovered — drives a brief
    /// "Freeing…" label instead of leaving the pill frozen on its old reading.
    private(set) var isComfyEjecting = false

    // MARK: - LM Studio residency

    struct LMServerStatus: Equatable {
        var reachable = false
        /// `true` when the server answered but speaks no native `/api/v1/models` — e.g. a plain
        /// OpenAI-compatible endpoint that happens to be configured as the prompt backend. The pill
        /// then shows "no session info" rather than pretending nothing is loaded.
        var lacksNativeAPI = false
        var models: [LMSessionStatus.Entry] = []
    }

    private(set) var lm = LMServerStatus()
    private(set) var isEjecting = Set<String>() // model keys with an in-flight unload
    /// `true` when the user clicked eject and the server hasn't yet confirmed the models gone — drives
    /// a brief "Freeing…" state on the LM pill.
    private(set) var isEjectingAll = false

    // MARK: - Wiring

    private weak var settings: AppSettings?
    /// `true` while any local mflux run is in flight — set by ``ContentView`` so a ComfyUI VRAM delta
    /// can't be misread as *Comfy* residency when it's actually our own process holding the GPU.
    var localRunInFlight = false

    private var pollTask: Task<Void, Never>?

    init(settings: AppSettings? = nil) {
        self.settings = settings
    }

    func attach(_ settings: AppSettings) {
        self.settings = settings
        restart()
    }

    // MARK: - Poll lifecycle

    /// (Re)starts the poll loop. Idempotent — safe to call from `onChange` of any setting that affects
    /// *whether* we should be polling at all. Cancels and replaces the previous task so a settings edit
    /// mid-flight doesn't leave two loops racing each other into the same state variables.
    func restart() {
        pollTask?.cancel()
        let comfyConfigured = !(settings?.comfyURL.trimmed().isEmpty ?? true)
        let lmConfigured = settings?.llmBackend == .remote && !(settings?.openAIBaseURL.trimmed().isEmpty ?? true)
        guard comfyConfigured || lmConfigured else { return }
        // Settings changed → the previous reading no longer describes this server; clear it so we don't show a
        // stale size until the next successful poll overwrites it with fresh occupancy figures.
        comfy = ComfyStatus()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling internals

    private func pollOnce() async {
        let comfyURL = settings?.comfyURL.trimmed() ?? ""
        if !comfyURL.isEmpty {
            await pollComfy(url: comfyURL)
        } else {
            // No backend configured — drop the reading so a stale pill from a previous URL doesn't linger.
            comfy = ComfyStatus()
        }

        let lmBase = settings?.openAIBaseURL.trimmed() ?? ""
        let lmKey = settings?.openAIAPIKey ?? ""
        if settings?.llmBackend == .remote && !lmBase.isEmpty {
            do {
                let status = try await OpenAIChatClient.fetchSessionStatus(baseURL: lmBase, apiKey: lmKey)
                lm.reachable = true
                lm.lacksNativeAPI = false
                // Collapse `LMSessionStatus.loaded` (wire models + instances) into the display-oriented entry list.
                var entries: [LMSessionStatus.Entry] = []
                for m in status.loaded {
                    let name = LMSessionStatus.ModelName(key: m.modelKey, displayName: m.displayName)
                    entries.append(LMSessionStatus.Entry(model: name, instances: m.instances))
                }
                lm.models = entries
            } catch where isNotNativeAPI(error) {
                // Server reached but has no native session endpoint — plain OpenAI-compatible box. The pill
                // degrades to "reachable, no info" instead of erroring every cycle.
                lm.reachable = true
                lm.lacksNativeAPI = true
                lm.models = []
            } catch {
                lm.reachable = false
                lm.lacksNativeAPI = false
            }
        } else if settings?.llmBackend != .remote || lmBase.isEmpty {
            // Backend switched to local Gemma, or URL cleared — clear the reading rather than showing a
            // stale "loaded" pill for a server we no longer talk to.
            lm = LMServerStatus()
        }
    }

    private func pollComfy(url: String) async {
        let client = ComfyUIClient(config: .init(baseURL: url))
        do {
            let stats = try await client.systemStats()
            comfy.reachable = true
            // Store both figures; occupancy is derived as `total − free` in the status type. Driver-level numbers,
            // because ComfyUI loads weights through the CUDA driver (the torch figure stays near-zero even with a
            // large model resident). If the server only exposes one of them we still show reachability but no size.
            comfy.totalBytes = stats.vramTotalBytes
            comfy.freeBytes = stats.vramFreeBytes
        } catch {
            // Unreachable (server down / wrong URL) — flip to offline and drop the reading so a later reconnection
            // starts fresh instead of comparing against a dead box's last figures.
            comfy.reachable = false
            comfy.totalBytes = nil
            comfy.freeBytes = nil
        }
    }

    /// `true` when the server answered but the path 404s / 405s — i.e. it isn't LM Studio at all, just some
    /// other OpenAI-compatible endpoint the user pointed us at. Distinguished from a plain connection failure
    /// (which means "unreachable", not "no info").
    private func isNotNativeAPI(_ error: Error) -> Bool {
        guard case let OpenAIChatClientError.httpStatus(status, _) = error else { return false }
        return status == 404 || status == 405
    }

    // MARK: - Derived UI state (read by the pills in ``ContentView``)

    /// Human size of what's currently resident on ComfyUI's GPU above the idle floor. `nil` when nothing is
    /// resident, we haven't yet read both VRAM figures, or we're mid-eject (the number will be wrong anyway for one poll).
    var comfyResidentGB: Double? {
        guard let occupied = comfy.occupiedBytes else { return nil }
        guard !isComfyEjecting else { return nil }
        return Self.residentGB(occupiedBytes: occupied)
    }

    var lmLoadedEntries: [LMSessionStatus.Entry] {
        // Ejecting keys are hidden from the count while their unload is in flight — the pill shows "Freeing…"
        // instead of a stale model list that's about to be empty.
        let ejecting = Set(isEjecting)
        return lm.models.filter { !ejecting.contains($0.model.key) }
    }

    var lmHasResidency: Bool {
        !lmLoadedEntries.isEmpty
    }

    /// Ejectable on the Comfy pill: only when we *know* something is resident (occupancy read, not offline).
    var canEjectComfy: Bool {
        comfy.reachable && comfy.occupiedBytes != nil && comfyResidentGB != nil && !isComfyEjecting
    }

    // MARK: - Eject actions

    /// Asks ComfyUI to unload every resident model (`POST /free`, `unload_models: true`). The next poll's
    /// VRAM recovery is what actually clears the pill; this just fires the request and marks the brief
    /// "Freeing…" window so a fast user can't double-click into two in-flight frees.
    func ejectComfy() {
        guard let url = settings?.comfyURL.trimmed(), !url.isEmpty else { return }
        guard !isComfyEjecting else { return }
        isComfyEjecting = true
        Task { [weak self] in
            let client = ComfyUIClient(config: .init(baseURL: url))
            await client.freeModels(unload: true, clearMemory: false)
            // Give the server one poll cycle to actually vacate before clearing the "Freeing…" state — if VRAM hasn't
            // recovered by then, occupancy stays high and the pill keeps showing its (now-correct) reading; we drop the
            // flag so the eject button re-arms for a retry.
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            self?.isComfyEjecting = false
        }
    }

    /// Unloads every loaded LM instance. Best-effort per key (one flaky unload doesn't abort the others).
    func ejectAllLM() {
        guard let base = settings?.openAIBaseURL.trimmed(), !base.isEmpty else { return }
        let keys = Set(lmLoadedEntries.map(\.model.key))
        guard !keys.isEmpty else { return }
        isEjecting.formUnion(keys)
        isEjectingAll = true
        Task { [weak self] in
            let key = self?.settings?.openAIAPIKey ?? ""
            for modelKey in keys {
                try? await OpenAIChatClient.unloadModel(instanceID: modelKey, baseURL: base, apiKey: key)
            }
            // Same one-cycle grace as the Comfy path — clear the "Freeing…" state after the next poll would have
            // observed the unload, so a still-loaded model (server ignored us) re-arms the button.
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            self?.isEjecting.subtract(keys)
            self?.isEjectingAll = false
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Residency decision from raw GPU occupancy, pulled out of ``comfyResidentGB`` so the floor is testable without a
    /// live server. `occupiedBytes` is the ComfyUI card's current `total − free`; an idle server holds only ~0–1 GB of
    /// driver/OS overhead, so anything at or below the floor reports nothing resident (`nil`), and above it we surface
    /// the full occupancy in GB (we don't subtract the floor from the display value — showing "29.5 GB" is what a user
    /// wants to see, not "28.5 GB above noise"). This needs no baseline capture: an already-loaded model at app start
    /// simply reads as high occupancy immediately.
    static func residentGB(occupiedBytes: Int64) -> Double? {
        guard occupiedBytes >= residencyFloorBytes else { return nil } // below idle-overhead floor → nothing to show
        return Double(occupiedBytes) / 1_073_741_824
    }
}

// MARK: - Display-facing value types for the pills

extension LMSessionStatus {
    /// Display-facing model name — falls back to the raw key when the server doesn't report a friendlier label.
    struct ModelName: Equatable, CustomStringConvertible {
        let key: String
        let displayName: String?

        var description: String {
            displayName ?? key
        }

        /// Short form for tight pill widths — last path component of the key (`org/model-quant` → `model-quant`).
        var shortKey: String {
            key.components(separatedBy: "/").last(where: { !$0.isEmpty }) ?? key
        }
    }

    /// One *displayed* loaded model (a server entry that has at least one resident instance), in the shape
    /// the pill renders. Kept separate from ``LMSessionStatus/loaded``'s tuple form so views don't have to
    /// destructure a labeled tuple across the view boundary.
    struct Entry: Equatable {
        let model: ModelName
        let instances: [Instance]

        /// Context length of the *first* instance — enough for the pill's "~4 k ctx" readout; multiple
        /// instances of one model are an edge case we don't render per-instance detail for.
        var firstContextLength: Int? {
            instances.first?.contextLength
        }
    }
}

extension String {
    /// Whitespace-trimmed copy — used by the store and the header pills to test "is this URL configured?".
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
