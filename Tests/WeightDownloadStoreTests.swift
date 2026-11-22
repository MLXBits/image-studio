import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Settings ▸ Models downloads. Each run keeps the level it was started for
/// (#26), outlives its page (#27), and writes only to itself (#43). The tools
/// are `/bin/sh` stand-ins, and both caches are fresh temp folders.
struct WeightDownloadStoreTests {
    /// Counts the processes a store builds, each running `script`.
    private final class FakeTool {
        var launches = 0
        let script: String

        init(_ script: String) {
            self.script = script
        }

        func make(_: HFDownloadSpec, _: AppSettings) -> Process {
            launches += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            return process
        }
    }

    /// `exec` so the stop signal reaches `sleep` itself, not a waiting shell.
    private static let longRunning = "echo started; exec sleep 30"

    private func settings() -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        let home = FakeRuntime.tempDirectory("WeightDownloadStoreTests")
        settings.hfHome = home.appendingPathComponent("hf").path
        settings.mfluxCacheDir = home.appendingPathComponent("mflux").path
        return settings
    }

    private func store(_ tool: FakeTool) -> WeightDownloadStore {
        WeightDownloadStore { tool.make($0, $1) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Starting

    /// Every level downloads the mflux-community repo the runner loads — never
    /// the upstream BF16 repo, and never an mflux-save pass (the Krea 2 Q4 that
    /// ran out of memory on a 24 GB Mac converting from BF16).
    @Test(arguments: [
        (FluxModelVariant.krea2, 4, "mflux-community/krea-2-turbo-mflux-q4"),
        (.krea2, 0, "mflux-community/krea-2-turbo-mflux-bf16"),
        (.flux2Klein9B, 8, "mflux-community/flux2-klein-9b-mflux-q8"),
        (.flux2KleinBase4B, 4, "mflux-community/flux-2-klein-base-4b-mflux-q4"),
        (.zimage, 8, "mflux-community/z-image-base-mflux-q8"),
        (.ideogram4, 0, "mflux-community/ideogram-4-mflux-bf16"),
    ])
    func aRunDownloadsThePublishedRepo(model: FluxModelVariant, quantize: Int, repo: String) async throws {
        let store = store(FakeTool("exit 0"))
        store.start(model: model, quantize: quantize, settings: settings())
        let run = try #require(store.runs[.weights(model, quantize: quantize)])
        #expect(run.repo == repo)
        try await waitUntil { run.phase == .done }
    }

    @Test func aCustomModelHasNothingToDownload() {
        let tool = FakeTool("exit 0")
        let store = store(tool)
        store.start(model: .custom, quantize: 4, settings: settings())
        #expect(store.runs[.weights(.custom, quantize: 4)] == nil)
        #expect(tool.launches == 0)
    }

    // MARK: - Progress (#26)

    @Test func aDownloadMeasuresItsOwnRepo() {
        let hub = FakeRuntime.tempDirectory("WeightDownloadStoreTests").appendingPathComponent("hub")
        let run = WeightDownloadStore.Run(
            target: .weights(.krea2, quantize: 4),
            spec: HFDownloadSpec(repo: "mflux-community/krea-2-turbo-mflux-q4", revision: nil, include: []),
            expectedGB: FluxModelVariant.krea2.approximateSizeGB(quantize: 4)
        )
        let target = WeightDownloadStore.progressTarget(of: run, hubDir: hub)
        #expect(target.folder.lastPathComponent == "models--mflux-community--krea-2-turbo-mflux-q4")
        #expect(target.totalGB == FluxModelVariant.krea2.approximateSizeGB(quantize: 4))
    }

    // MARK: - Deleting

    /// A repo's blobs link into hub/blobs/, the cache-wide shared store, so
    /// deleting the repo folder by hand left the weights behind for the next
    /// download to relink. `hf cache rm` sweeps them.
    @Test func deletingAPublishedRepoGoesThroughHFCacheRm() throws {
        let hub = FakeRuntime.tempDirectory("WeightDownloadStoreTests").appendingPathComponent("hub")
        let repo = "mflux-community/flux-3-image-klein-mflux-q4"
        try FileManager.default.createDirectory(
            at: ModelDownloadStore.cacheFolder(repo: repo, hubDir: hub), withIntermediateDirectories: true
        )
        #expect(WeightDownloadStore.removeArgs(model: .flux3Klein, quantize: 4, hubDir: hub)
            == ["cache", "rm", "model/\(repo)", "--yes", "--cache-dir", hub.path])
    }

    /// Only the repo the level loads is the model's: an old upstream or third-party
    /// folder that merely names it is left alone.
    @Test func deletingIgnoresFoldersThatOnlyNameTheModel() throws {
        let hub = FakeRuntime.tempDirectory("WeightDownloadStoreTests").appendingPathComponent("hub")
        try FileManager.default.createDirectory(
            at: hub.appendingPathComponent("models--mlx-community--flux2-klein-9b-4bit"), withIntermediateDirectories: true
        )
        #expect(WeightDownloadStore.removeArgs(model: .flux2Klein9B, quantize: 4, hubDir: hub) == nil)
    }

    @Test func deletingWithNothingInTheHubCacheRunsNoHF() {
        let hub = FakeRuntime.tempDirectory("WeightDownloadStoreTests").appendingPathComponent("hub")
        #expect(WeightDownloadStore.removeArgs(model: .flux3Klein, quantize: 4, hubDir: hub) == nil)
    }

    // MARK: - Runs

    @Test func aFailedRunKeepsTheLevelItWasStartedFor() async throws {
        let tool = FakeTool("exit 3")
        let store = store(tool)
        store.start(model: .flux2Klein9B, quantize: 4, settings: settings())
        try await waitUntil { store.runs[.weights(.flux2Klein9B, quantize: 4)]?.phase != .running }
        let run = try #require(store.runs[.weights(.flux2Klein9B, quantize: 4)])
        #expect(run.target == .weights(.flux2Klein9B, quantize: 4))
        #expect(run.phase == .failed("hf exited with status 3. Check the log below."))
    }

    @Test func aFinishedDownloadReportsAndBumpsTheRevision() async throws {
        let store = store(FakeTool("exit 0"))
        let revision = store.revision
        store.start(model: .ideogram4, quantize: 4, settings: settings())
        try await waitUntil { store.runs[.weights(.ideogram4, quantize: 4)]?.phase == .done }
        #expect(store.runs[.weights(.ideogram4, quantize: 4)]?.log.hasSuffix("✓ Cached mflux-community/ideogram-4-mflux-q4.") == true)
        #expect(store.revision != revision)
    }

    /// #27: leaving the page dismisses only a finished run.
    @Test func leavingAPageKeepsItsDownloadRunning() async throws {
        let store = store(FakeTool(Self.longRunning))
        store.start(model: .ideogram4, quantize: 4, settings: settings())
        try await waitUntil { store.runs[.weights(.ideogram4, quantize: 4)]?.log.contains("started") == true }

        store.dismiss(.weights(.ideogram4, quantize: 4))
        #expect(store.runs[.weights(.ideogram4, quantize: 4)]?.phase == .running)

        store.cancel(.weights(.ideogram4, quantize: 4))
        try await waitUntil { store.runs[.weights(.ideogram4, quantize: 4)] == nil }
    }

    /// #27, #43: cancelling one model's download leaves another's alone.
    @Test func downloadsOfTwoModelsAreIndependent() async throws {
        let store = store(FakeTool(Self.longRunning))
        let s = settings()
        store.start(model: .ideogram4, quantize: 4, settings: s)
        store.start(model: .flux2Klein9B, quantize: 8, settings: s)
        try await waitUntil {
            store.runs[.weights(.ideogram4, quantize: 4)]?.log.contains("started") == true
                && store.runs[.weights(.flux2Klein9B, quantize: 8)]?.log.contains("started") == true
        }

        store.cancel(.weights(.ideogram4, quantize: 4))
        try await waitUntil { store.runs[.weights(.ideogram4, quantize: 4)] == nil }
        #expect(store.runs[.weights(.flux2Klein9B, quantize: 8)]?.phase == .running)

        store.cancel(.weights(.flux2Klein9B, quantize: 8))
        try await waitUntil { store.runs[.weights(.flux2Klein9B, quantize: 8)] == nil }
    }

    /// #43: a run cancelled before its process exists never launches one.
    @Test func cancellingBeforeLaunchLaunchesNothing() async throws {
        let tool = FakeTool(Self.longRunning)
        let store = store(tool)
        store.start(model: .ideogram4, quantize: 4, settings: settings())
        store.cancel(.weights(.ideogram4, quantize: 4))
        try await waitUntil { store.runs[.weights(.ideogram4, quantize: 4)] == nil }
        #expect(tool.launches == 0)
    }

    @Test func aTargetThatIsDownloadingIsntStartedTwice() async throws {
        let tool = FakeTool(Self.longRunning)
        let store = store(tool)
        let s = settings()
        store.start(model: .ideogram4, quantize: 4, settings: s)
        try await waitUntil { store.runs[.weights(.ideogram4, quantize: 4)]?.log.contains("started") == true }
        store.start(model: .ideogram4, quantize: 4, settings: s)
        #expect(tool.launches == 1)

        store.cancel(.weights(.ideogram4, quantize: 4))
        try await waitUntil { store.runs[.weights(.ideogram4, quantize: 4)] == nil }
    }

    // MARK: - Per-target runs

    @Test func twoQuantsOfOneModelRunSideBySide() async throws {
        let tool = FakeTool(Self.longRunning)
        let store = store(tool)
        let s = settings()
        store.start(model: .krea2, quantize: 8, settings: s)
        store.start(model: .krea2, quantize: 4, settings: s)
        try await waitUntil {
            store.runs[.weights(.krea2, quantize: 8)]?.log.contains("started") == true
                && store.runs[.weights(.krea2, quantize: 4)]?.log.contains("started") == true
        }
        #expect(store.runs[.weights(.krea2, quantize: 8)]?.phase == .running)
        #expect(store.runs[.weights(.krea2, quantize: 4)]?.phase == .running)
        #expect(tool.launches == 2)

        store.cancel(.weights(.krea2, quantize: 8))
        store.cancel(.weights(.krea2, quantize: 4))
        try await waitUntil { store.runs.isEmpty }
    }

    @Test func dismissFinishedKeepsRunningRuns() async throws {
        let s = settings()
        let done = FakeTool("exit 0")
        let long = FakeTool(Self.longRunning)
        let store = WeightDownloadStore { spec, settings in
            spec.repo.hasSuffix("q8") ? done.make(spec, settings) : long.make(spec, settings)
        }
        store.start(model: .krea2, quantize: 8, settings: s)
        try await waitUntil { store.runs[.weights(.krea2, quantize: 8)]?.phase == .done }
        store.start(model: .krea2, quantize: 4, settings: s)
        try await waitUntil { store.runs[.weights(.krea2, quantize: 4)]?.log.contains("started") == true }

        store.dismissFinished()
        #expect(Set(store.runs.keys) == [.weights(.krea2, quantize: 4)])

        store.cancel(.weights(.krea2, quantize: 4))
        try await waitUntil { store.runs.isEmpty }
    }

    @Test func downloadArgsCarryRevisionAndIncludes() {
        let spec = HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: "abc", include: ["a.safetensors", "b.safetensors"])
        #expect(WeightDownloadStore.downloadArgs(spec)
            == ["download", "numz/SeedVR2_comfyUI", "--revision", "abc", "--include", "a.safetensors", "--include", "b.safetensors"])
        #expect(WeightDownloadStore.downloadArgs(HFDownloadSpec(repo: "r/x", revision: nil, include: [])) == ["download", "r/x"])
    }
}
