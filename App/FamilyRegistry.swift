import Foundation

/// Every family's queue (its job store and runner), built once at launch and
/// shared by every window. The typed fields serve code that needs one family's
/// job type, such as Generate and the queue drawer. Everything that loops over
/// families goes through ``all`` (``FamilyQueues``, the hand-off) or the lists
/// below, so a new family is one field, one line in ``init(driver:)`` and one
/// entry in ``members``.
///
/// Nothing here changes after init, so nothing is tracked: `@Observable` is only
/// what `.environment(_:)` requires. Views observe the stores and runners.
@Observable
final class FamilyRegistry {
    let flux: FamilyQueue<FluxRunnerSpec>
    let ideogram4: FamilyQueue<Ideogram4RunnerSpec>
    let krea2: FamilyQueue<Krea2RunnerSpec>
    let zimage: FamilyQueue<ZImageRunnerSpec>
    let qwen21: FamilyQueue<Qwen21RunnerSpec>
    let seedVR2: FamilyQueue<SeedVR2RunnerSpec>

    /// One queue per family, in ``GenerationCoordinator/runOrder``.
    var all: [any AnyFamilyQueue] {
        members
    }

    /// Every queue's job store, which a profile switch reloads.
    var jobStores: [any ProfileScopedJobStore] {
        members.map(\.jobStore)
    }

    /// Every runner, for the support nudge's image count and the finish notifications.
    var reporters: [any JobOutcomeReporting] {
        members.map(\.reporter)
    }

    /// The images every queue has still to make, for the dock badge.
    var imagesLeft: Int {
        members.reduce(0) { $0 + $1.imagesLeft }
    }

    private var members: [any RegisteredFamilyQueue] {
        [flux, ideogram4, krea2, zimage, qwen21, seedVR2]
    }

    /// Every generative runner gets `driver`: one warm process that keeps a
    /// single model, so a cross-family switch evicts before it loads (see the
    /// gate). SeedVR2 runs as a CLI and never uses it.
    init(driver: MfluxDriverController) {
        flux = FamilyQueue(store: JobStore(), runner: FluxJobRunner())
        ideogram4 = FamilyQueue(store: Ideogram4JobStore(), runner: Ideogram4JobRunner())
        krea2 = FamilyQueue(store: Krea2JobStore(), runner: Krea2JobRunner())
        zimage = FamilyQueue(store: ZImageJobStore(), runner: ZImageJobRunner())
        qwen21 = FamilyQueue(store: Qwen21JobStore(), runner: Qwen21JobRunner())
        seedVR2 = FamilyQueue(store: SeedVR2JobStore(), runner: SeedVR2JobRunner())
        for member in members where ModelFamily.generative.contains(member.family) {
            member.useDriver(driver)
        }
    }
}

/// What ``FamilyRegistry`` needs from a queue beyond what ``FamilyQueues`` uses.
private protocol RegisteredFamilyQueue: AnyFamilyQueue {
    var jobStore: any ProfileScopedJobStore { get }
    var reporter: any JobOutcomeReporting { get }
    /// Each pending job's batch, plus what the running job has yet to land.
    var imagesLeft: Int { get }
    func useDriver(_ driver: MfluxDriverController)
}

extension FamilyQueue: RegisteredFamilyQueue {
    var jobStore: any ProfileScopedJobStore {
        store
    }

    var reporter: any JobOutcomeReporting {
        runner
    }

    var imagesLeft: Int {
        BackgroundSignals.imagesLeft(pending: store.pendingJobs, running: runner.activeJob)
    }

    func useDriver(_ driver: MfluxDriverController) {
        runner.driver = driver
    }
}
