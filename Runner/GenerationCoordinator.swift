import Foundation

/// Global, cross-family run gate.
///
/// Each model family owns a separate store and runner, but they all draw on the same
/// GPU / unified memory — so only one `mflux` process may run at a time. Two concurrent runs (e.g. generating in Ideogram while a
/// Flux job is still going) risk an out-of-memory crash.
///
/// Every runner consults this gate in `runNext` before starting a job: whichever family
/// is mid-run holds the gate until its own queue drains, then releases it. ``ContentView``
/// watches each store's `isRunning` flag and, once all are idle, starts the family
/// ``nextFamily(hasWaitingJobs:)`` picks, so queued work across families still drains,
/// strictly serially.
@Observable
@MainActor
final class GenerationCoordinator {
    /// The order the queues run in when jobs wait in more than one: generative
    /// families first, SeedVR2 upscales last. Each family drains its queue before
    /// the next starts, so a mixed queue loads each model once. Not FIFO across
    /// families: a job waits behind any earlier family's, however late those came.
    static let runOrder: [ModelFamily] = ModelFamily.generative + [.seedvr2]

    /// The family whose queue to start once every queue is idle: the first, in
    /// ``runOrder``, with a waiting job. Nil when nothing waits.
    static func nextFamily(hasWaitingJobs: (ModelFamily) -> Bool) -> ModelFamily? {
        runOrder.first { hasWaitingJobs($0) }
    }

    /// The family currently executing, or `nil` when idle.
    private(set) var activeFamily: ModelFamily?

    /// Grants the gate to `family` when idle or already held by it. Returns `false` when a
    /// *different* family is mid-run, in which case the caller must leave its job pending.
    func tryAcquire(_ family: ModelFamily) -> Bool {
        if let activeFamily, activeFamily != family {
            return false
        }
        activeFamily = family
        return true
    }

    /// Releases the gate held by `family`. No-op if `family` isn't the current holder.
    func release(_ family: ModelFamily) {
        guard activeFamily == family else { return }
        activeFamily = nil
    }
}
