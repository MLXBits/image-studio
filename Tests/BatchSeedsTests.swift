@testable import MLXBits_Image_Studio
import Testing

/// The seeds a Generate press gives a job: a batch count rolls that many random
/// seeds; otherwise typed-in seeds are used, and one seed is a plain single run.
@MainActor
struct BatchSeedsTests {
    private func job(seed: Int = -1) -> Krea2Job {
        Krea2Job(seed: seed)
    }

    @Test func aBatchCountRollsThatManyDistinctSeeds() {
        let job = job(seed: 7)
        job.applyBatchSeeds(count: 5, typed: [1, 2])
        #expect(job.seeds.count == 5)
        #expect(Set(job.seeds).count == 5)
        #expect(job.seed == 7)
    }

    /// mflux adds `_seed_N` only for two or more seeds.
    @Test func oneTypedSeedIsASingleSeedRun() {
        let job = job()
        job.applyBatchSeeds(count: 1, typed: [42])
        #expect(job.seed == 42)
        #expect(job.seeds.isEmpty)
    }

    @Test func aRepeatedTypedSeedCountsOnce() {
        let job = job()
        job.applyBatchSeeds(count: 1, typed: [42, 42])
        #expect(job.seed == 42)
        #expect(job.seeds.isEmpty)
    }

    @Test func typedSeedsBatchWithoutRepeatsInOrder() {
        let job = job()
        job.applyBatchSeeds(count: 1, typed: [3, 1, 3, 2])
        #expect(job.seeds == [3, 1, 2])
    }

    @Test func noCountAndNoTypedSeedsLeavesTheJobsSeed() {
        let job = job(seed: 9)
        job.applyBatchSeeds(count: 1, typed: [])
        #expect(job.seed == 9)
        #expect(job.seeds.isEmpty)
    }
}
