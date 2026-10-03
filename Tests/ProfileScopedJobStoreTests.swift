import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers how a job store moves between profiles: its queue history is a file
/// in the profile's data folder, and a switch must neither carry the old
/// queue into the new profile nor write pending edits into the wrong file.
struct ProfileScopedJobStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileScopedJobStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func decodeJobs(in dir: URL) throws -> [SeedVR2Job] {
        let data = try Data(contentsOf: dir.appendingPathComponent("seedvr2-jobs.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SeedVR2Job].self, from: data)
    }

    /// A profile with no history file yet starts with an empty queue — not the
    /// previous profile's jobs left in memory.
    @Test func activatingAProfileWithoutHistoryEmptiesTheQueue() {
        let store = SeedVR2JobStore()
        store.activate(profileDirectory: tempDir())
        store.add(SeedVR2Job(sourcePath: "/a.png"))

        store.activate(profileDirectory: tempDir())

        #expect(store.jobs.isEmpty)
    }

    /// Saves are debounced; a switch inside that window must flush the edit to
    /// the profile it was made in.
    @Test func pendingSaveLandsInThePreviousProfile() throws {
        let dirA = tempDir()
        let dirB = tempDir()
        let store = SeedVR2JobStore()
        store.activate(profileDirectory: dirA)
        let job = SeedVR2Job(sourcePath: "/a.png")
        store.add(job)

        store.activate(profileDirectory: dirB)

        #expect(try decodeJobs(in: dirA).map(\.id) == [job.id])
        #expect(!FileManager.default.fileExists(atPath: dirB.appendingPathComponent("seedvr2-jobs.json").path))
    }

    @Test func switchingBackRestoresTheQueue() {
        let dirA = tempDir()
        let store = SeedVR2JobStore()
        store.activate(profileDirectory: dirA)
        let job = SeedVR2Job(sourcePath: "/a.png")
        store.add(job)

        store.activate(profileDirectory: tempDir())
        store.activate(profileDirectory: dirA)

        #expect(store.jobs.map(\.id) == [job.id])
    }

    @Test func jobInterruptedMidRunLoadsAsFailed() throws {
        let dir = tempDir()
        let job = SeedVR2Job(sourcePath: "/a.png")
        job.status = .running
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([job]).write(to: dir.appendingPathComponent("seedvr2-jobs.json"))

        let store = SeedVR2JobStore()
        store.activate(profileDirectory: dir)

        let status = try #require(store.jobs.first?.status)
        guard case .failed = status else {
            Issue.record("expected .failed, got \(status)")
            return
        }
    }

    @Test func queuedOrRunningWorkBlocksASwitch() {
        let store = SeedVR2JobStore()
        store.activate(profileDirectory: tempDir())
        #expect(!store.blocksProfileSwitch)

        let job = SeedVR2Job(sourcePath: "/a.png")
        store.add(job)
        #expect(store.blocksProfileSwitch)
        #expect(store.queuedCount == 1)

        job.status = .completed
        #expect(!store.blocksProfileSwitch)

        store.isRunning = true
        #expect(store.blocksProfileSwitch)
    }
}
