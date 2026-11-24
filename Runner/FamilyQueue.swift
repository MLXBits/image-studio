import Foundation

/// One family's queue as ``FamilyQueues`` sees it: whatever the family's job
/// type, the hand-off, Stop, retry and the landing handler loop over these.
@MainActor
protocol AnyFamilyQueue {
    var family: ModelFamily { get }
    var isRunning: Bool { get }
    var hasWaitingJobs: Bool { get }
    var activeJobID: UUID? { get }
    /// The preview of the running job, or nil when none runs.
    var activePreview: PreviewState? { get }
    var history: JobHistoryFile { get }
    var landing: Landing? { get }

    func runNext(settings: AppSettings, coordinator: GenerationCoordinator, timing: TimingStore)
    func cancel()
    /// Puts `job` back at the front of this queue. False, and nothing changes,
    /// when `job` belongs to another family.
    func restart(_ job: any GeneratedJob) -> Bool
}

/// A family's job store and runner, typed by the family's runner spec.
/// A value: ``FamilyQueues`` is rebuilt on every body evaluation, and this
/// holds references only.
struct FamilyQueue<Spec: JobRunnerSpec>: AnyFamilyQueue
    where Spec.Job: QueueListedJob, Spec.Store: ProfileScopedJobStore, Spec.Store.PersistedJob == Spec.Job {
    let store: Spec.Store
    let runner: JobRunner<Spec>

    var family: ModelFamily {
        Spec.family
    }

    var isRunning: Bool {
        store.isRunning
    }

    var hasWaitingJobs: Bool {
        !store.pendingJobs.isEmpty
    }

    var activeJobID: UUID? {
        runner.activeJob?.id
    }

    var activePreview: PreviewState? {
        runner.activeJob.map { Spec.preview($0) }
    }

    var history: JobHistoryFile {
        store.history
    }

    var landing: Landing? {
        runner.landing
    }

    func add(_ jobs: [Spec.Job]) {
        for job in jobs {
            store.add(job)
        }
    }

    func runNext(settings: AppSettings, coordinator: GenerationCoordinator, timing: TimingStore) {
        runner.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
    }

    func cancel() {
        runner.cancel()
    }

    func restart(_ job: any GeneratedJob) -> Bool {
        guard let job = job as? Spec.Job else { return false }
        store.restart(job)
        return true
    }
}
