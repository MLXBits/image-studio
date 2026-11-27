import Foundation

/// Every family's queue, and the gate between them. Holds references only:
/// ``ContentView`` builds one from ``FamilyRegistry/all`` as needed.
struct FamilyQueues {
    /// One queue per family, in ``GenerationCoordinator/runOrder``.
    let all: [any AnyFamilyQueue]
    let settings: AppSettings
    let coordinator: GenerationCoordinator
    let timing: TimingStore
    let driverController: MfluxDriverController

    /// The running job's ID, whichever family it belongs to.
    var activeJobID: UUID? {
        all.lazy.compactMap(\.activeJobID).first
    }

    /// The running job's preview, or idle when nothing runs.
    var activePreview: PreviewState {
        all.lazy.compactMap(\.activePreview).first ?? .idle
    }

    var isAnyRunning: Bool {
        all.contains { $0.isRunning }
    }

    /// The queue that runs now, or nil when none does. The gate lets only one run.
    var runningQueue: (any AnyFamilyQueue)? {
        all.first { $0.isRunning }
    }

    /// Every family's queue history file, in run order.
    var histories: [JobHistoryFile] {
        all.map(\.history)
    }

    /// Every family's latest landing, in run order.
    var landings: [Landing?] {
        all.map(\.landing)
    }

    /// Adds `jobs` to a family's queue and starts it if the gate is free.
    /// Returns whether every queue was idle before, so the preview can follow
    /// the first new job.
    @discardableResult
    func enqueue<Spec>(_ jobs: [Spec.Job], on queue: FamilyQueue<Spec>) -> Bool {
        let wasIdle = !isAnyRunning
        queue.add(jobs)
        queue.runNext(settings: settings, coordinator: coordinator, timing: timing)
        return wasIdle
    }

    /// Puts a failed job back at the front of its family's queue, then starts it
    /// once the gate is free.
    func restart(_ job: any GeneratedJob) {
        for queue in all {
            guard queue.restart(job) else { continue }
            pump()
            return
        }
    }

    /// Starts the next pending job across all families, but only when the gate is free.
    /// Each runner drains its own queue internally; this hands off to the next family once
    /// the current one is fully idle (called when the union of `isRunning` turns false).
    func pump() {
        guard !isAnyRunning,
              let family = GenerationCoordinator.nextFamily(hasWaitingJobs: { queue(for: $0)?.hasWaitingJobs == true }),
              let next = queue(for: family) else { return }
        // A hand-off to any family but Flux first asks the warm driver to unload its model,
        // since holding two models risks OOM. The request is not awaited: the next run
        // starts without waiting for the driver's `unloaded` reply.
        if family != .flux {
            driverController.eject(reason: "model_switch")
        }
        next.runNext(settings: settings, coordinator: coordinator, timing: timing)
    }

    func stopAll() {
        for queue in all {
            queue.cancel()
        }
    }

    private func queue(for family: ModelFamily) -> (any AnyFamilyQueue)? {
        all.first { $0.family == family }
    }
}
