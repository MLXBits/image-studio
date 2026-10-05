import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Model downloads the app owns (#18). A panel waits on one, but closing it or
/// cancelling its generation stops the wait, not the download.
struct ModelDownloadStoreTests {
    private func settings(offline: Bool = false) -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.hfOffline = offline
        return settings
    }

    @Test func localPathsAndOfflineModeNeedNoFetch() async throws {
        var fetched: [String] = []
        let store = ModelDownloadStore { repo, _ in fetched.append(repo) }
        try await store.ensureAvailable("/Volumes/Models/gemma", settings: settings())
        try await store.ensureAvailable("mlx-community/gemma", settings: settings(offline: true))
        #expect(fetched.isEmpty)
    }

    @Test func aRepoIsFetchedOncePerLaunch() async throws {
        var fetched = 0
        let store = ModelDownloadStore { _, _ in fetched += 1 }
        let s = settings()
        try await store.ensureAvailable("mlx-community/gemma", settings: s)
        try await store.ensureAvailable("mlx-community/gemma", settings: s)
        #expect(fetched == 1)
    }

    @Test func cancellingTheCallerLeavesTheDownloadRunning() async throws {
        let gate = AsyncGate()
        var fetched = 0
        let store = ModelDownloadStore { _, _ in
            fetched += 1
            await gate.wait()
        }
        let s = settings()
        let caller = Task { try await store.ensureAvailable("mlx-community/gemma", settings: s) }
        while store.active["mlx-community/gemma"] == nil {
            await Task.yield()
        }

        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(store.active["mlx-community/gemma"] != nil)

        gate.open()
        try await store.ensureAvailable("mlx-community/gemma", settings: s)
        #expect(fetched == 1)
        #expect(store.active.isEmpty)
    }

    @Test func aFailedDownloadIsReportedAndRetriedNextTime() async throws {
        var attempts = 0
        let store = ModelDownloadStore { repo, _ in
            attempts += 1
            throw ModelDownloadError.failed(repo: repo, detail: "boom")
        }
        let s = settings()
        await #expect(throws: ModelDownloadError.self) { try await store.ensureAvailable("org/model", settings: s) }
        await #expect(throws: ModelDownloadError.self) { try await store.ensureAvailable("org/model", settings: s) }
        #expect(attempts == 2)
    }

    /// A cached snapshot with `files` in it, under a new HF home.
    private func cachedSnapshot(_ files: [String: String]) throws -> AppSettings {
        let home = FakeRuntime.tempDirectory("ModelDownloadStoreTests")
        let snapshot = home.appendingPathComponent("hub/models--org--model/snapshots/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: snapshot.appendingPathComponent(name))
        }
        let s = settings()
        s.hfHome = home.path
        return s
    }

    @Test func aFailedFetchWithACachedCopyStillRuns() async throws {
        let s = try cachedSnapshot([
            "config.json": "{}",
            "model.safetensors.index.json": #"{"weight_map": {"a": "model-1.safetensors", "b": "model-2.safetensors"}}"#,
            "model-1.safetensors": "", "model-2.safetensors": "",
        ])
        let store = ModelDownloadStore { _, _ in throw URLError(.notConnectedToInternet) }
        try await store.ensureAvailable("org/model", settings: s)
    }

    /// An interrupted download leaves a snapshot without all its weights:
    /// the fetch's error is reported, and the next run tries again.
    @Test func aFailedFetchWithAPartialCopyIsReported() async throws {
        let s = try cachedSnapshot([
            "config.json": "{}",
            "model.safetensors.index.json": #"{"weight_map": {"a": "model-1.safetensors", "b": "model-2.safetensors"}}"#,
            "model-1.safetensors": "",
        ])
        let store = ModelDownloadStore { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) { try await store.ensureAvailable("org/model", settings: s) }
    }

    /// After the models folder changes, a repo fetched into the old folder is
    /// fetched again into the new one.
    @Test func aNewModelsFolderFetchesTheRepoAgain() async throws {
        var fetchedInto: [URL] = []
        let store = ModelDownloadStore { _, settings in fetchedInto.append(settings.hfHubDir) }
        let s = settings()
        s.hfHome = "/tmp/hf-a"
        try await store.ensureAvailable("org/model", settings: s)
        s.hfHome = "/tmp/hf-b"
        try await store.ensureAvailable("org/model", settings: s)
        #expect(fetchedInto.map(\.path) == ["/tmp/hf-a/hub", "/tmp/hf-b/hub"])
    }

    @Test func progressReadsAsSizeAndTime() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ModelDownloadStatusRow.describe(bytes: 2_254_857_830, since: start, now: start.addingTimeInterval(65))
            == "2.1 GB · 1m 05s")
        #expect(ModelDownloadStatusRow.describe(bytes: 0, since: start, now: start.addingTimeInterval(7)) == "07s")
    }
}
