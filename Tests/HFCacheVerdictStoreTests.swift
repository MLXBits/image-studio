import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// "Downloaded" for a Hugging Face cache folder (#19): the quick check follows
/// huggingface_hub 2.x's links into its shared blob store, and mflux's own
/// answer, while current, overrides it.
struct HFCacheVerdictStoreTests {
    private let root = FakeRuntime.tempDirectory("HFCacheVerdictStoreTests")
    private let repo = "mlx-community/flux2-klein-9b-8bit"

    private var hub: URL {
        root.appendingPathComponent("hub", isDirectory: true)
    }

    private var folder: URL {
        ModelDownloadStore.cacheFolder(repo: repo, hubDir: hub)
    }

    private var blobs: URL {
        folder.appendingPathComponent("blobs", isDirectory: true)
    }

    /// A sparse file over 1 GB: the quick check's threshold for weights.
    private func writeWeights(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1_100_000_000)
        try handle.close()
    }

    /// The huggingface_hub 2.x layout: the content lives once in the hub's
    /// shared `blobs/<xx>/<sha>`, and the repo's blob is a relative link to it.
    private func cacheLinked() throws {
        try writeWeights(to: hub.appendingPathComponent("blobs/ab/abcdef"))
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: blobs.appendingPathComponent("abcdef").path, withDestinationPath: "../../blobs/ab/abcdef"
        )
    }

    /// An interpreter that ignores its arguments and prints `output`.
    private func interpreter(printing output: String) throws -> String {
        let url = root.appendingPathComponent("python-\(UUID().uuidString)")
        try FakeRuntime.writeExecutable("#!/bin/sh\nprintf '%s' '\(output)'\n", to: url)
        return url.path
    }

    private func refresh(_ store: HFCacheVerdictStore, printing output: String) async throws {
        let python = try interpreter(printing: output)
        await store.refresh(python: python, script: root.appendingPathComponent("probe.py"), hubDir: hub)
    }

    @Test func aLinkedBlobCountsAtItsTargetsSize() throws {
        try cacheLinked()
        #expect(ModelDownloadStore.bytesOnDisk(repo: repo, hubDir: hub) == 1_100_000_000)
        #expect(FluxModelVariant.isCompleteHFCache(at: folder, verdicts: HFCacheVerdictStore()))
    }

    @Test func mfluxCanSayACacheIsIncomplete() async throws {
        try writeWeights(to: blobs.appendingPathComponent("weights"))
        let store = HFCacheVerdictStore()
        #expect(FluxModelVariant.isCompleteHFCache(at: folder, verdicts: store))
        try await refresh(store, printing: #"{"\#(repo)": false}"#)
        #expect(store.isComplete(folder) == false)
        #expect(!FluxModelVariant.isCompleteHFCache(at: folder, verdicts: store))
    }

    /// A stale partial from an interrupted download fails the quick check, but
    /// not mflux's.
    @Test func mfluxCanSayACacheWithALeftoverPartialIsComplete() async throws {
        try writeWeights(to: blobs.appendingPathComponent("weights"))
        FileManager.default.createFile(atPath: blobs.appendingPathComponent("etag.abcd1234.incomplete").path, contents: nil)
        let store = HFCacheVerdictStore()
        #expect(!FluxModelVariant.isCompleteHFCache(at: folder, verdicts: store))
        try await refresh(store, printing: #"{"\#(repo)": true}"#)
        #expect(FluxModelVariant.isCompleteHFCache(at: folder, verdicts: store))
    }

    @Test func anAnswerLapsesWhenTheBlobsChange() async throws {
        try writeWeights(to: blobs.appendingPathComponent("weights"))
        let store = HFCacheVerdictStore()
        try await refresh(store, printing: #"{"\#(repo)": false}"#)
        #expect(store.isComplete(folder) == false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: blobs.path)
        #expect(store.isComplete(folder) == nil)
        #expect(FluxModelVariant.isCompleteHFCache(at: folder, verdicts: store))
    }

    /// hf links a file into the snapshot after its blob lands, and a new
    /// revision can link blobs already there: neither touches `blobs/`.
    @Test func anAnswerLapsesWhenASnapshotChanges() async throws {
        try writeWeights(to: blobs.appendingPathComponent("weights"))
        let vae = folder.appendingPathComponent("snapshots/rev1/vae", isDirectory: true)
        try FileManager.default.createDirectory(at: vae, withIntermediateDirectories: true)
        let store = HFCacheVerdictStore()
        try await refresh(store, printing: #"{"\#(repo)": false}"#)
        #expect(store.isComplete(folder) == false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: vae.path)
        #expect(store.isComplete(folder) == nil)
    }

    @Test func aFailedProbeLeavesTheQuickCheck() async throws {
        try writeWeights(to: blobs.appendingPathComponent("weights"))
        let store = HFCacheVerdictStore()
        try await refresh(store, printing: "Traceback (most recent call last)")
        #expect(store.isComplete(folder) == nil)
        #expect(FluxModelVariant.isCompleteHFCache(at: folder, verdicts: store))
    }

    @Test func eachModelFolderIsAskedAboutOnceWithItsFamily() throws {
        for name in ["models--mlx-community--flux2-klein-9b-8bit", "models--krea--Krea-2-Turbo", "models--org--unrelated"] {
            try FileManager.default.createDirectory(at: hub.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let asked = HFCacheVerdictStore.requests(hubDir: hub).map { "\($0.family)=\($0.repo)" }
        #expect(asked.sorted() == ["flux.2=mlx-community/flux2-klein-9b-8bit", "krea2=krea/Krea-2-Turbo"])
    }

    /// The probe looks families up by ``ModelFamily/id``; a family it doesn't
    /// list would silently keep the quick check.
    @Test func theProbeKnowsEveryGenerativeFamily() throws {
        let script = try #require(Bundle.main.url(forResource: "hf_cache_probe", withExtension: "py"))
        let source = try String(contentsOf: script, encoding: .utf8)
        for family in ModelFamily.generative {
            #expect(source.contains("\n    \"\(family.id)\": (\"mflux."), "no definition for \(family.id)")
        }
    }

    @Test func aCacheFolderNameSpellsItsRepo() {
        #expect(HFCacheVerdictStore.repoID(cacheFolder: "models--black-forest-labs--FLUX.2-klein-9B")
            == "black-forest-labs/FLUX.2-klein-9B")
        #expect(HFCacheVerdictStore.repoID(cacheFolder: "datasets--org--name") == nil)
        #expect(HFCacheVerdictStore.repoID(cacheFolder: "models--orphan") == nil)
    }
}
