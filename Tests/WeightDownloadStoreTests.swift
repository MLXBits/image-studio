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

        func make(_: WeightDownloadStore.Plan, _: AppSettings) -> Process {
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
        WeightDownloadStore { try tool.make($0, $1) }
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

    // MARK: - Plans

    @Test func aPublishedRepoIsDownloadedAsIs() {
        let cache = FakeRuntime.tempDirectory("WeightDownloadStoreTests")
        let hub = cache.appendingPathComponent("hub")
        #expect(WeightDownloadStore.plan(model: .flux2Klein9B, quantize: 8, cacheDir: cache, hubDir: hub)
            == .download(repo: "mlx-community/flux2-klein-9b-8bit"))
        #expect(WeightDownloadStore.plan(model: .ideogram4, quantize: 4, cacheDir: cache, hubDir: hub)
            == .download(repo: "mflux-community/ideogram-4-mflux-q4"))
        #expect(WeightDownloadStore.plan(model: .ideogram4, quantize: 0, cacheDir: cache, hubDir: hub)
            == .download(repo: "ideogram-ai/ideogram-4-fp8"))
    }

    @Test func aConversionWithoutLocalBaseWeightsFetchesThem() {
        let cache = FakeRuntime.tempDirectory("WeightDownloadStoreTests")
        let savePath = FluxModelVariant.flux2Klein9B.savedModelPath(quantize: 4, in: cache)
        let plan = WeightDownloadStore.plan(
            model: .flux2Klein9B, quantize: 4, cacheDir: cache, hubDir: cache.appendingPathComponent("hub")
        )
        #expect(plan == .save(
            args: ["--model", "flux2-klein-9b", "--quantize", "4", "--path", savePath.path],
            savePath: savePath, fetchesBase: true
        ))
    }

    @Test func aConversionFromSavedBaseWeightsFetchesNothing() throws {
        let cache = FakeRuntime.tempDirectory("WeightDownloadStoreTests")
        let base = FluxModelVariant.flux2Klein9B.savedModelPath(quantize: 0, in: cache)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent("model.safetensors"))
        let savePath = FluxModelVariant.flux2Klein9B.savedModelPath(quantize: 4, in: cache)
        let plan = WeightDownloadStore.plan(
            model: .flux2Klein9B, quantize: 4, cacheDir: cache, hubDir: cache.appendingPathComponent("hub")
        )
        #expect(plan == .save(
            args: ["--model", base.path, "--quantize", "4", "--path", savePath.path],
            savePath: savePath, fetchesBase: false
        ))
    }

    // MARK: - Progress (#26)

    /// The case from #26: Q8 is downloaded and the Quantization setting, and Q4
    /// is being converted. Progress measures the base repo mflux is fetching,
    /// against the base size, not the finished Q8 repo.
    @Test func aConversionMeasuresTheBaseRepoBeingFetched() throws {
        let hub = FakeRuntime.tempDirectory("WeightDownloadStoreTests").appendingPathComponent("hub")
        for folder in ["models--mlx-community--flux2-klein-9b-8bit", "models--black-forest-labs--FLUX.2-klein-9B"] {
            try FileManager.default.createDirectory(
                at: hub.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        let run = WeightDownloadStore.Run(
            model: .flux2Klein9B, quantize: 4, plan: .save(args: [], savePath: hub, fetchesBase: true)
        )
        let target = try #require(WeightDownloadStore.progressTarget(of: run, hubDir: hub))
        #expect(target.folder.lastPathComponent == "models--black-forest-labs--FLUX.2-klein-9B")
        #expect(target.totalGB == FluxModelVariant.flux2Klein9B.approximateSizeGB(quantize: 0))
    }

    @Test func aDownloadMeasuresItsOwnRepo() throws {
        let hub = FakeRuntime.tempDirectory("WeightDownloadStoreTests").appendingPathComponent("hub")
        let run = WeightDownloadStore.Run(
            model: .ideogram4, quantize: 4, plan: .download(repo: "mflux-community/ideogram-4-mflux-q4")
        )
        let target = try #require(WeightDownloadStore.progressTarget(of: run, hubDir: hub))
        #expect(target.folder.lastPathComponent == "models--mflux-community--ideogram-4-mflux-q4")
        #expect(target.totalGB == 14)
    }

    @Test func aConversionFromLocalWeightsHasNoDownloadProgress() {
        let run = WeightDownloadStore.Run(
            model: .flux2Klein9B, quantize: 4, plan: .save(args: [], savePath: URL(fileURLWithPath: "/"), fetchesBase: false)
        )
        #expect(WeightDownloadStore.progressTarget(of: run, hubDir: URL(fileURLWithPath: "/")) == nil)
    }

    // MARK: - Runs

    @Test func aFailedRunKeepsTheLevelItWasStartedFor() async throws {
        let tool = FakeTool("exit 3")
        let store = store(tool)
        store.start(model: .flux2Klein9B, quantize: 4, settings: settings())
        try await waitUntil { store.runs[.flux2Klein9B]?.phase != .running }
        let run = try #require(store.runs[.flux2Klein9B])
        #expect(run.quantize == 4)
        #expect(run.phase == .failed("mflux-save exited with status 3. Check the log below."))
    }

    @Test func aFinishedDownloadReportsAndBumpsTheRevision() async throws {
        let store = store(FakeTool("exit 0"))
        let revision = store.revision
        store.start(model: .ideogram4, quantize: 4, settings: settings())
        try await waitUntil { store.runs[.ideogram4]?.phase == .done }
        #expect(store.runs[.ideogram4]?.log.hasSuffix("✓ Cached mflux-community/ideogram-4-mflux-q4.") == true)
        #expect(store.revision != revision)
    }

    /// #27: leaving the page dismisses only a finished run.
    @Test func leavingAPageKeepsItsDownloadRunning() async throws {
        let store = store(FakeTool(Self.longRunning))
        store.start(model: .ideogram4, quantize: 4, settings: settings())
        try await waitUntil { store.runs[.ideogram4]?.log.contains("started") == true }

        store.dismiss(.ideogram4)
        #expect(store.runs[.ideogram4]?.phase == .running)

        store.cancel(.ideogram4)
        try await waitUntil { store.runs[.ideogram4] == nil }
    }

    /// #27, #43: cancelling one model's download leaves another's alone.
    @Test func downloadsOfTwoModelsAreIndependent() async throws {
        let store = store(FakeTool(Self.longRunning))
        let s = settings()
        store.start(model: .ideogram4, quantize: 4, settings: s)
        store.start(model: .flux2Klein9B, quantize: 8, settings: s)
        try await waitUntil {
            store.runs[.ideogram4]?.log.contains("started") == true
                && store.runs[.flux2Klein9B]?.log.contains("started") == true
        }

        store.cancel(.ideogram4)
        try await waitUntil { store.runs[.ideogram4] == nil }
        #expect(store.runs[.flux2Klein9B]?.phase == .running)
        #expect(store.runs[.flux2Klein9B]?.quantize == 8)

        store.cancel(.flux2Klein9B)
        try await waitUntil { store.runs[.flux2Klein9B] == nil }
    }

    /// #43: a run cancelled before its process exists never launches one.
    @Test func cancellingBeforeLaunchLaunchesNothing() async throws {
        let tool = FakeTool(Self.longRunning)
        let store = store(tool)
        store.start(model: .ideogram4, quantize: 4, settings: settings())
        store.cancel(.ideogram4)
        try await waitUntil { store.runs[.ideogram4] == nil }
        #expect(tool.launches == 0)
    }

    @Test func aModelThatIsDownloadingIsntStartedTwice() async throws {
        let tool = FakeTool(Self.longRunning)
        let store = store(tool)
        let s = settings()
        store.start(model: .ideogram4, quantize: 4, settings: s)
        try await waitUntil { store.runs[.ideogram4]?.log.contains("started") == true }
        store.start(model: .ideogram4, quantize: 8, settings: s)
        #expect(store.runs[.ideogram4]?.quantize == 4)
        #expect(tool.launches == 1)

        store.cancel(.ideogram4)
        try await waitUntil { store.runs[.ideogram4] == nil }
    }
}
