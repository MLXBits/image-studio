import Foundation
import SwiftUI // MutableCollection.move(fromOffsets:toOffset:), for drag reorder

/// Run order and the queue drawer's row actions, shared by every family's store.
///
/// The list runs newest at the top. The runner takes the lowest pending row
/// next, so new jobs queue behind the waiting ones, and moving a row is what
/// changes when it runs.
extension ProfileScopedJobStore {
    /// The job the runner takes next: the lowest pending row.
    var nextPendingJob: PersistedJob? {
        jobs.last { $0.status == .pending }
    }

    /// Moves a waiting job to the front of the queue, so it runs next.
    func moveToFront(_ job: PersistedJob) {
        guard job.status == .pending else { return }
        placeNext(job)
        save()
    }

    /// Drag reorder in the drawer. Only waiting jobs move; a move that includes
    /// any other row is refused.
    func movePending(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard offsets.allSatisfy({ jobs.indices.contains($0) && jobs[$0].status == .pending }) else { return }
        jobs.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Retries every failed job, oldest first. Cancelled jobs stay cancelled.
    func retryAllFailed() {
        // Top to bottom is newest to oldest; each retry lands below the last,
        // so the oldest ends lowest and runs first.
        for job in jobs {
            if case .failed = job.status {
                restart(job)
            }
        }
    }

    /// Puts `job` just below the other waiting jobs: next in line.
    func placeNext(_ job: PersistedJob) {
        jobs.removeAll { $0.id == job.id }
        let index = jobs.lastIndex { $0.status == .pending }.map { $0 + 1 } ?? 0
        jobs.insert(job, at: index)
    }
}

extension ProfileScopedJobStore where PersistedJob: SeedSplittableJob {
    /// Queues a fresh copy of `job` behind the waiting jobs. A random-seed batch
    /// rolls new seeds; typed seeds are kept, as is a single job's seed.
    func duplicate(_ job: PersistedJob) {
        let copy = job.copy(seed: job.seed)
        if job.seeds.count > 1 {
            copy.seeds = job.seed == -1 ? RunnerSupport.randomSeeds(count: job.seeds.count) : job.seeds
        }
        jobs.insert(copy, at: 0)
        pruneIfNeeded()
        save()
    }
}
