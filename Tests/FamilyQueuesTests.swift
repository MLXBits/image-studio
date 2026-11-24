import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// A queue that records what ``FamilyQueues`` asks of it, without a runner.
@MainActor
private final class FakeQueue: AnyFamilyQueue {
    let family: ModelFamily
    var isRunning = false
    var hasWaitingJobs = false
    var activeJobID: UUID?
    var activePreview: PreviewState?
    var landing: Landing?
    let history = JobHistoryFile(fileName: "fake-jobs.json", directory: nil)
    /// The jobs ``restart(_:)`` claims as this queue's own.
    var ownJobs: Set<UUID> = []
    private(set) var runNextCalls = 0
    private(set) var cancelCalls = 0
    private(set) var restarted: [UUID] = []

    init(_ family: ModelFamily) {
        self.family = family
    }

    func runNext(settings _: AppSettings, coordinator _: GenerationCoordinator, timing _: TimingStore) {
        runNextCalls += 1
    }

    func cancel() {
        cancelCalls += 1
    }

    func restart(_ job: any GeneratedJob) -> Bool {
        guard ownJobs.contains(job.id) else { return false }
        restarted.append(job.id)
        return true
    }
}

/// ``FamilyQueues`` runs every family's queue through one list: the hand-off
/// follows run order, and nothing starts while any queue runs.
@Suite("Family queues")
@MainActor
struct FamilyQueuesTests {
    private let settings = AppSettings()

    private func queues(_ all: [FakeQueue]) -> FamilyQueues {
        FamilyQueues(
            all: all, settings: settings, coordinator: GenerationCoordinator(), timing: TimingStore(),
            driverController: MfluxDriverController(settings: settings)
        )
    }

    // MARK: - Hand-off

    @Test func pumpStartsTheFirstQueueInRunOrderWithWaitingJobs() {
        let flux = FakeQueue(.flux)
        let krea2 = FakeQueue(.krea2)
        let seedVR2 = FakeQueue(.seedvr2)
        krea2.hasWaitingJobs = true
        seedVR2.hasWaitingJobs = true

        // Listed out of run order: the hand-off follows run order, not the list.
        queues([seedVR2, flux, krea2]).pump()

        #expect(flux.runNextCalls == 0)
        #expect(krea2.runNextCalls == 1)
        #expect(seedVR2.runNextCalls == 0)
    }

    @Test func pumpStartsNothingWhileAnyQueueRuns() {
        let flux = FakeQueue(.flux)
        let krea2 = FakeQueue(.krea2)
        flux.hasWaitingJobs = true
        krea2.isRunning = true

        queues([flux, krea2]).pump()

        #expect(flux.runNextCalls == 0)
        #expect(krea2.runNextCalls == 0)
    }

    @Test func pumpStartsNothingWhenNoQueueWaits() {
        let flux = FakeQueue(.flux)
        queues([flux]).pump()
        #expect(flux.runNextCalls == 0)
    }

    // MARK: - Restart

    @Test func restartPutsAJobBackOnItsOwnQueueOnly() {
        let flux = FakeQueue(.flux)
        let seedVR2 = FakeQueue(.seedvr2)
        let job = SeedVR2Job(sourcePath: "/a.png")
        seedVR2.ownJobs = [job.id]

        queues([flux, seedVR2]).restart(job)

        #expect(flux.restarted.isEmpty)
        #expect(seedVR2.restarted == [job.id])
    }

    @Test func restartStartsTheRestartedJobWhenIdle() {
        let seedVR2 = FakeQueue(.seedvr2)
        let job = SeedVR2Job(sourcePath: "/a.png")
        seedVR2.ownJobs = [job.id]
        seedVR2.hasWaitingJobs = true

        queues([seedVR2]).restart(job)

        #expect(seedVR2.runNextCalls == 1)
    }

    /// A real queue only takes back a job of its own family.
    @Test func aFamilyQueueRestartsOnlyItsOwnFamilysJobs() {
        let store = SeedVR2JobStore()
        let queue = FamilyQueue(store: store, runner: SeedVR2JobRunner())
        let job = SeedVR2Job(sourcePath: "/a.png")
        job.status = .failed("boom")
        store.jobs = [job]

        #expect(!queue.restart(Krea2Job(prompt: "a heron")))
        #expect(queue.restart(job))
        #expect(job.status == .pending)
    }

    // MARK: - Stop and aggregates

    @Test func stopAllCancelsEveryQueue() {
        let all = [FakeQueue(.flux), FakeQueue(.zimage), FakeQueue(.seedvr2)]
        queues(all).stopAll()
        #expect(all.map(\.cancelCalls) == [1, 1, 1])
    }

    @Test func anyRunningQueueMakesTheWholeSetRunning() {
        let flux = FakeQueue(.flux)
        let qwen21 = FakeQueue(.qwen21)
        let set = queues([flux, qwen21])
        #expect(!set.isAnyRunning)

        qwen21.isRunning = true

        #expect(set.isAnyRunning)
    }

    @Test func theActiveJobIsWhicheverQueueHasOne() {
        let flux = FakeQueue(.flux)
        let ideogram4 = FakeQueue(.ideogram4)
        let id = UUID()
        ideogram4.activeJobID = id

        #expect(queues([flux, ideogram4]).activeJobID == id)
    }

    @Test func landingsFollowQueueOrder() {
        let flux = FakeQueue(.flux)
        let krea2 = FakeQueue(.krea2)
        let landing = Landing(seq: 1, run: 1, firstPath: "/a.png")
        krea2.landing = landing

        #expect(queues([flux, krea2]).landings == [nil, landing])
    }
}
