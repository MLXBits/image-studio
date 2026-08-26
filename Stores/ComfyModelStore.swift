import Foundation

/// Observable holder for model lists discovered from a running ComfyUI server via `/object_info`.
/// The Krea 2 settings form binds its UNet / CLIP / VAE pickers to these; they refresh when the user
/// points the form at a (new) server URL, flips the backend segment to ComfyUI, or taps Refresh. A
/// failed/empty discovery leaves the lists empty, in which case the form falls back to manual text entry.
@Observable
final class ComfyModelStore {
    var unets: [String] = []
    var clips: [String] = []
    var vaes: [String] = []
    var samplers: [String] = []
    /// Server LoRA relative-path names from `/models/loras` (e.g. `krea2/foo.safetensors`). Populated by the same discovery pass as the
    /// model lists; fed to ``onLorasDiscovered`` so the owner can auto-catalog them into the library.
    var loras: [String] = []
    var schedulers: [String] = []

    /// Last fetch result so the UI can surface "Found N models" or a failure message.
    enum Status: Equatable {
        case idle, loading, loaded(count: Int), failed(String)
    }

    private(set) var status: Status = .idle
    private var inFlight: Task<Void, Never>?
    /// The normalized base URL we last fetched successfully for; `nil` until the first success. Used so
    /// re-appearing on the form doesn't re-hit `/object_info`; only a genuine refresh or URL change refetches.
    private(set) var fetchedForURL: String?
    /// Set by the owning view (e.g. ``ModelDefaultsView``) to receive the LoRA name list once a discovery pass succeeds — race-free, called
    /// in the same task that stored it. `nil` when no cataloging is wanted (e.g. preview contexts). The store deliberately does NOT hold a
    /// reference to any other store; this callback keeps it dependency-free.
    var onLorasDiscovered: (([String]) -> Void)?

    /// True when lists are already loaded for this exact (normalized) base URL. Lets the form trigger an
    /// initial discovery on first appear without hammering the server on every navigation.
    func hasLoaded(for raw: String) -> Bool {
        let url = ComfyUIClient.Config.normalize(raw)
        return !url.isEmpty && fetchedForURL == url
    }

    /// Kick off (or restart) discovery for `raw`. No-op when a fetch for this exact URL is already in flight.
    func refresh(baseURL raw: String) {
        let url = ComfyUIClient.Config.normalize(raw)
        guard !url.isEmpty else { return }
        if fetchIsInFlight() {
            return // already fetching for this URL
        }
        inFlight?.cancel()
        status = .loading
        fetchedForURL = nil
        let client = ComfyUIClient(config: .init(baseURL: url, apiKey: nil))
        inFlight = Task { [weak self] in
            do {
                let info = try await client.discoverModels()
                guard !Task.isCancelled else { return }
                self?.unets = info.unets
                self?.clips = info.clips
                self?.vaes = info.vaes
                self?.loras = info.loras
                self?.samplers = info.samplers
                let count = info.unets.count + info.clips.count + info.vaes.count
                self?.status = .loaded(count: count)
                self?.fetchedForURL = url
                // Hand the freshly-discovered LoRA names to the owner for auto-cataloging. Guarded so a missing
                // callback (preview / non-cataloging contexts) is harmless; the closure runs on this task, after
                // state is stored, so there's no ordering race with the UI observing `status`.
                if !info.loras.isEmpty {
                    self?.onLorasDiscovered?(info.loras)
                }
            } catch is CancellationError {
                // Superseded by a newer fetch; leave state for the new task.
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Reset all lists and pending work (e.g. when switching back to mflux or clearing the URL).
    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        status = .idle
        unets.removeAll()
        clips.removeAll()
        vaes.removeAll()
        samplers.removeAll()
        schedulers.removeAll()
        loras.removeAll()
        fetchedForURL = nil
    }

    // MARK: - Status discriminators (plain logic; avoids `if case` patterns that trip SwiftFormat)

    private func fetchIsInFlight() -> Bool {
        guard inFlight != nil, !inFlight!.isCancelled else { return false }
        switch status {
        case .loading:
            return true
        default:
            return false
        }
    }
}
