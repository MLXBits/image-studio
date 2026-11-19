@testable import MLXBits_Image_Studio
import Testing

/// Queue order: the runner takes the lowest pending row next, and the queue
/// drawer's Duplicate, Retry, Run Next, Retry All Failed and drag reorder move
/// rows within that order.
@Suite("Queue order and row actions")
struct JobQueueOrderTests {
    private func job(_ prompt: String, _ status: JobStatus = .pending, seed: Int = -1, seeds: [Int] = []) -> Krea2Job {
        let job = Krea2Job(prompt: prompt, seed: seed, seeds: seeds)
        job.status = status
        return job
    }

    /// A store listing `jobs` top to bottom, as the drawer shows them.
    private func store(_ jobs: [Krea2Job]) -> Krea2JobStore {
        let store = Krea2JobStore()
        store.jobs = jobs
        return store
    }

    private func prompts(_ store: Krea2JobStore) -> [String] {
        store.jobs.map(\.prompt)
    }

    @Test func theLowestPendingRowRunsNext() {
        let store = store([job("newest"), job("done", .completed), job("oldest"), job("older done", .completed)])
        #expect(store.nextPendingJob?.prompt == "oldest")
    }

    @Test func newJobsQueueBehindTheOnesWaiting() {
        let store = store([job("first")])
        store.add(job("second"))
        #expect(store.nextPendingJob?.prompt == "first")
    }

    @Test func aRetriedJobRunsNext() {
        let failed = job("failed", .failed("boom"))
        let store = store([job("waiting 2"), job("waiting 1"), failed, job("done", .completed)])

        store.restart(failed)

        #expect(prompts(store) == ["waiting 2", "waiting 1", "failed", "done"])
        #expect(store.nextPendingJob === failed)
    }

    @Test func aRetryWithNothingWaitingStillRuns() {
        let failed = job("failed", .failed("boom"))
        let store = store([job("done", .completed), failed])

        store.restart(failed)

        #expect(store.nextPendingJob === failed)
    }

    @Test func retryAllFailedRunsTheOldestFirst() {
        let store = store([
            job("new fail", .failed("a")), job("cancelled", .cancelled), job("old fail", .failed("b")),
        ])

        store.retryAllFailed()

        #expect(store.jobs.filter { $0.status == .pending }.map(\.prompt) == ["new fail", "old fail"])
        #expect(store.nextPendingJob?.prompt == "old fail")
        // Retry All Failed leaves cancelled jobs alone.
        #expect(store.jobs.first { $0.prompt == "cancelled" }?.status == .cancelled)
    }

    @Test func runNextMovesAWaitingJobToTheFront() {
        let last = job("last")
        let store = store([last, job("middle"), job("first"), job("done", .completed)])

        store.moveToFront(last)

        #expect(prompts(store) == ["middle", "first", "last", "done"])
        #expect(store.nextPendingJob === last)
    }

    @Test func runNextIgnoresAJobThatIsNotWaiting() {
        let done = job("done", .completed)
        let store = store([job("waiting"), done])

        store.moveToFront(done)

        #expect(prompts(store) == ["waiting", "done"])
    }

    @Test func dragReordersWaitingJobs() {
        let store = store([job("c"), job("b"), job("a")])

        store.movePending(fromOffsets: [2], toOffset: 0)

        #expect(prompts(store) == ["a", "c", "b"])
        #expect(store.nextPendingJob?.prompt == "b")
    }

    @Test func dragRefusesToMoveAFinishedJob() {
        let store = store([job("waiting"), job("done", .completed)])

        store.movePending(fromOffsets: [1], toOffset: 0)

        #expect(prompts(store) == ["waiting", "done"])
    }

    @Test func duplicateQueuesACopyBehindTheWaitingJobs() {
        let original = job("original", .completed, seed: 42)
        let store = store([job("waiting"), original])

        store.duplicate(original)

        #expect(store.jobs.count == 3)
        let copy = store.jobs[0]
        #expect(copy.id != original.id)
        #expect(copy.prompt == "original" && copy.seed == 42 && copy.status == .pending)
        #expect(store.nextPendingJob?.prompt == "waiting")
    }

    @Test func duplicatingARandomBatchRollsNewSeeds() {
        let batch = job("batch", .failed("x"), seed: -1, seeds: [1, 2, 3])
        let store = store([batch])

        store.duplicate(batch)

        let copy = store.jobs[0]
        #expect(copy.seeds.count == 3)
        #expect(Set(copy.seeds).isDisjoint(with: [1, 2, 3]))
    }

    @Test func duplicatingATypedSeedBatchKeepsItsSeeds() {
        let batch = job("batch", .cancelled, seed: 7, seeds: [7, 8, 9])
        let store = store([batch])

        store.duplicate(batch)

        #expect(store.jobs[0].seeds == [7, 8, 9])
    }
}
