import Foundation

/// Global, cross-family run gate.
///
/// The three model families (Flux, Ideogram 4, Krea 2) each own a separate store and
/// runner, but they all draw on the same GPU / unified memory — so only one `mflux`
/// process may run at a time. Two concurrent runs (e.g. generating in Ideogram while a
/// Flux job is still going) risk an out-of-memory crash.
///
/// Every runner consults this gate in `runNext` before starting a job: whichever family
/// is mid-run holds the gate until its own queue drains, then releases it. ``ContentView``
/// watches each store's `isRunning` flag and pumps the next family's pending jobs once the
/// gate is free, so queued work across families still drains — just strictly serially.
@Observable
@MainActor
final class GenerationCoordinator {
    /// The family currently executing, or `nil` when idle.
    private(set) var activeFamily: ModelFamily?

    /// Grants the gate to `family` when idle or already held by it. Returns `false` when a
    /// *different* family is mid-run, in which case the caller must leave its job pending.
    func tryAcquire(_ family: ModelFamily) -> Bool {
        if let activeFamily, activeFamily != family { return false }
        activeFamily = family
        return true
    }

    /// Releases the gate held by `family`. No-op if `family` isn't the current holder.
    func release(_ family: ModelFamily) {
        guard activeFamily == family else { return }
        activeFamily = nil
    }
}
