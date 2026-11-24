import Foundation

/// Every family's job store and runner, and the gate between them. Holds
/// references only: ``ContentView`` builds one from its environment as needed.
struct FamilyQueues {
    let settings: AppSettings
    let coordinator: GenerationCoordinator
    let timing: TimingStore
    let driverController: MfluxDriverController
    let flux: JobStore
    let fluxRunner: FluxJobRunner
    let ideogram4: Ideogram4JobStore
    let ideogram4Runner: Ideogram4JobRunner
    let krea2: Krea2JobStore
    let krea2Runner: Krea2JobRunner
    let zimage: ZImageJobStore
    let zimageRunner: ZImageJobRunner
    let qwen21: Qwen21JobStore
    let qwen21Runner: Qwen21JobRunner
    let seedVR2: SeedVR2JobStore
    let seedVR2Runner: SeedVR2JobRunner

    /// The running job's ID, whichever family it belongs to.
    var activeJobID: UUID? {
        let ids: [UUID?] = [
            fluxRunner.activeJob?.id, ideogram4Runner.activeJob?.id, krea2Runner.activeJob?.id,
            zimageRunner.activeJob?.id, qwen21Runner.activeJob?.id, seedVR2Runner.activeJob?.id,
        ]
        return ids.lazy.compactMap(\.self).first
    }

    var isAnyRunning: Bool {
        flux.isRunning || ideogram4.isRunning || krea2.isRunning
            || zimage.isRunning || qwen21.isRunning || seedVR2.isRunning
    }

    /// Every family's queue history file, in run order.
    var histories: [JobHistoryFile] {
        [flux.history, ideogram4.history, krea2.history, zimage.history, qwen21.history, seedVR2.history]
    }

    /// Adds `jobs` to a family's queue and starts it if the gate is free.
    /// Returns whether every queue was idle before, so the preview can follow
    /// the first new job.
    @discardableResult
    func enqueue<Spec: JobRunnerSpec>(_ jobs: [Spec.Job], in store: Spec.Store, on runner: JobRunner<Spec>) -> Bool
        where Spec.Job: QueueListedJob, Spec.Store: ProfileScopedJobStore, Spec.Store.PersistedJob == Spec.Job {
        let wasIdle = !isAnyRunning
        for job in jobs {
            store.add(job)
        }
        runner.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
        return wasIdle
    }

    /// Puts the failed job a preview shows back at the front of its family's
    /// queue, then starts it once the gate is free.
    func restart(_ preview: PreviewState) {
        switch preview {
        case let .activeJob(job): flux.restart(job)
        case let .activeIdeogram4Job(job): ideogram4.restart(job)
        case let .activeKrea2Job(job): krea2.restart(job)
        case let .activeZImageJob(job): zimage.restart(job)
        case let .activeQwen21Job(job): qwen21.restart(job)
        case let .activeSeedVR2Job(job): seedVR2.restart(job)
        case .idle, .galleryItem: return
        }
        pump()
    }

    /// Starts the next pending job across all families, but only when the gate is free.
    /// Each runner drains its own queue internally; this hands off to the next family once
    /// the current one is fully idle (called when the union of `isRunning` turns false).
    func pump() {
        guard !isAnyRunning,
              let family = GenerationCoordinator.nextFamily(hasWaitingJobs: { hasWaitingJobs($0) }) else { return }
        // A hand-off to any family but Flux first asks the warm driver to unload its model,
        // since holding two models risks OOM. The request is not awaited: the next run
        // starts without waiting for the driver's `unloaded` reply.
        if family != .flux {
            driverController.eject(reason: "model_switch")
        }
        switch family {
        case .flux: fluxRunner.runNext(in: flux, settings: settings, coordinator: coordinator, timing: timing)
        case .ideogram4: ideogram4Runner.runNext(in: ideogram4, settings: settings, coordinator: coordinator, timing: timing)
        case .krea2: krea2Runner.runNext(in: krea2, settings: settings, coordinator: coordinator, timing: timing)
        case .zimage: zimageRunner.runNext(in: zimage, settings: settings, coordinator: coordinator, timing: timing)
        case .qwen21: qwen21Runner.runNext(in: qwen21, settings: settings, coordinator: coordinator, timing: timing)
        case .seedvr2: seedVR2Runner.runNext(in: seedVR2, settings: settings, coordinator: coordinator, timing: timing)
        }
    }

    func stopAll() {
        fluxRunner.cancel(); ideogram4Runner.cancel(); krea2Runner.cancel()
        zimageRunner.cancel(); qwen21Runner.cancel(); seedVR2Runner.cancel()
    }

    private func hasWaitingJobs(_ family: ModelFamily) -> Bool {
        switch family {
        case .flux: !flux.pendingJobs.isEmpty
        case .ideogram4: !ideogram4.pendingJobs.isEmpty
        case .krea2: !krea2.pendingJobs.isEmpty
        case .zimage: !zimage.pendingJobs.isEmpty
        case .qwen21: !qwen21.pendingJobs.isEmpty
        case .seedvr2: !seedVR2.pendingJobs.isEmpty
        }
    }
}
