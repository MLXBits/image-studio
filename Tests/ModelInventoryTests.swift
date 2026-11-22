import Foundation
@testable import MLXBits_Image_Studio
import Testing

struct ModelInventoryTests {
    @Test func sectionsListEveryModelOnceInOrder() {
        let sections = ModelInventory.sections
        #expect(sections.map(\.title) == ["FLUX.3", "FLUX.2", "Ideogram", "Krea", "Qwen", "Z-Image"])
        let flat = sections.flatMap(\.models)
        #expect(flat == [
            .flux3Klein, .flux3KleinBase, .flux2Klein9B, .flux2Klein4B, .flux2KleinBase9B, .flux2KleinBase4B,
            .ideogram4, .krea2, .qwen21Turbo, .zimageTurbo, .zimage,
        ])
        #expect(Set(flat) == Set(FluxModelVariant.allModels))
    }

    @Test func headerLineNamesTheSectionFamilyAndType() {
        #expect(ModelInventory.headerLine(for: .flux3Klein) == "FLUX.3 · Distilled · 16 steps")
        #expect(ModelInventory.headerLine(for: .flux3KleinBase) == "FLUX.3 · Base · 50 steps")
        #expect(ModelInventory.headerLine(for: .krea2) == "Krea · Distilled · 8 steps")
        #expect(ModelInventory.headerLine(for: .ideogram4) == "Ideogram · Preset-based")
        #expect(ModelInventory.headerLine(for: .flux2Klein4B) == "FLUX.2 · Distilled · 4 steps")
        #expect(ModelInventory.headerLine(for: .zimage) == "Z-Image · Base · 50 steps")
    }

    @Test func aRowCarriesEachQuantInOrder() {
        let row = ModelInventory.row(
            for: .krea2, isCached: { $0 == 4 }, ramGB: { _ in 10 }, physicalGB: 32, toolMissing: false
        )
        #expect(row.quants.map(\.quantize) == [0, 8, 4])
        #expect(row.quants.map(\.label) == ["BF16", "Q8", "Q4"])
        #expect(row.quants.map(\.cached) == [false, false, true])
        #expect(row.quants[2].sizeGB == 15.8)
        #expect(row.quants[0].fit == .comfortable)
    }

    @Test func aBlobLinkedFromTwoReposCountsOnce() throws {
        let root = FakeRuntime.tempDirectory("ModelInventoryTests")
        let fm = FileManager.default
        let store = root.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let blob = store.appendingPathComponent("abc")
        try Data(count: 1_048_576).write(to: blob)
        var folders: [URL] = []
        for name in ["models--a--x", "models--b--y"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let blobs = folder.appendingPathComponent("blobs", isDirectory: true)
            try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: blobs.appendingPathComponent("abc"), withDestinationURL: blob)
            folders.append(folder)
        }
        #expect(ModelInventory.diskBytes(repoFolders: folders) == 1_048_576)
    }

    @Test func aMissingRepoFolderCountsZero() {
        let missing = FakeRuntime.tempDirectory("ModelInventoryTests").appendingPathComponent("nope")
        #expect(ModelInventory.diskBytes(repoFolders: [missing]) == 0)
    }

    @Test func aSpecIsCachedWhenEveryIncludeIsInItsRevision() throws {
        let hub = FakeRuntime.tempDirectory("ModelInventoryTests")
        // A pinned spec names a real commit, as mflux's pins do.
        let commit = "09ced71023636e9bc8cdf9cdecfb2625d1e691e8"
        let spec = HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: commit, include: ["a.safetensors", "b.safetensors"])
        let folder = ModelDownloadStore.cacheFolder(repo: spec.repo, hubDir: hub)
        let fm = FileManager.default
        let revision = folder.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
        try fm.createDirectory(at: revision, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: revision.appendingPathComponent("a.safetensors"))
        #expect(!ModelInventory.isCached(spec, hubDir: hub))
        try Data("b".utf8).write(to: revision.appendingPathComponent("b.safetensors"))
        #expect(ModelInventory.isCached(spec, hubDir: hub))

        let other = FakeRuntime.tempDirectory("ModelInventoryTests")
        let elsewhere = ModelDownloadStore.cacheFolder(repo: spec.repo, hubDir: other)
            .appendingPathComponent("snapshots/1111111111111111111111111111111111111111", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for name in spec.include {
            try Data("x".utf8).write(to: elsewhere.appendingPathComponent(name))
        }
        #expect(!ModelInventory.isCached(spec, hubDir: other))
    }

    /// hf files a branch or unpinned download under the commit its `refs/<branch>` names, so an
    /// mflux that stops pinning SeedVR2 (or pins a branch) still finds a complete download.
    @Test func aBranchOrUnpinnedSpecResolvesThroughRefs() throws {
        let hub = FakeRuntime.tempDirectory("ModelInventoryTests")
        let fm = FileManager.default
        let folder = ModelDownloadStore.cacheFolder(repo: "numz/SeedVR2_comfyUI", hubDir: hub)
        let commit = String(repeating: "a", count: 40)
        let snapshot = folder.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: snapshot.appendingPathComponent("a.safetensors"))
        try fm.createDirectory(at: folder.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("\(commit)\n".utf8).write(to: folder.appendingPathComponent("refs/main"))

        let unpinned = HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: nil, include: ["a.safetensors"])
        let branch = HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: "main", include: ["a.safetensors"])
        let pinned = HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: commit, include: ["a.safetensors"])
        #expect(ModelInventory.isCached(unpinned, hubDir: hub))
        #expect(ModelInventory.isCached(branch, hubDir: hub))
        #expect(ModelInventory.isCached(pinned, hubDir: hub))
        let otherBranch = HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: "dev", include: ["a.safetensors"])
        #expect(!ModelInventory.isCached(otherBranch, hubDir: hub))
    }

    @Test func listedRepoFoldersSkipMissingOnes() throws {
        let hub = FakeRuntime.tempDirectory("ModelInventoryTests")
        let fm = FileManager.default
        let krea = try #require(FluxModelVariant.krea2.publishedRepoID(quantize: 4))
        let kreaFolder = ModelDownloadStore.cacheFolder(repo: krea, hubDir: hub)
        let gemmaFolder = ModelDownloadStore.cacheFolder(repo: "org/gemma", hubDir: hub)
        try fm.createDirectory(at: kreaFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: gemmaFolder, withIntermediateDirectories: true)
        let listed = ModelInventory.listedRepoFolders(hubDir: hub, seedVR2Repo: "numz/SeedVR2_comfyUI", gemmaRepo: "org/gemma")
        #expect(Set(listed) == [kreaFolder, gemmaFolder])
        #expect(listed.count == 2)
    }

    /// A model the runner loads from an old mflux-save copy shows as cached, so its
    /// folder counts toward the total too.
    @Test func legacySavedFoldersListOnlyCopiesWithWeights() throws {
        let cache = FakeRuntime.tempDirectory("ModelInventoryTests")
        let fm = FileManager.default
        let krea = FluxModelVariant.krea2.savedModelPath(quantize: 8, in: cache)
        try fm.createDirectory(at: krea.appendingPathComponent("transformer"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: krea.appendingPathComponent("transformer/0.safetensors"))
        // Configs only: not a copy the runner would load.
        let zimage = FluxModelVariant.zimage.savedModelPath(quantize: 8, in: cache)
        try fm.createDirectory(at: zimage, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: zimage.appendingPathComponent("config.json"))
        // Ideogram 4 ignores its old copies, so they are not listed.
        let ideogram = FluxModelVariant.ideogram4.savedModelPath(quantize: 8, in: cache)
        try fm.createDirectory(at: ideogram, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: ideogram.appendingPathComponent("0.safetensors"))
        #expect(ModelInventory.legacySavedFolders(cacheDir: cache) == [krea])
    }

    @Test func folderBytesSumsEveryNestedFile() throws {
        let root = FakeRuntime.tempDirectory("ModelInventoryTests")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: root.appendingPathComponent("a/one.safetensors"))
        try Data(count: 24).write(to: root.appendingPathComponent("a/b/two.safetensors"))
        #expect(ModelInventory.folderBytes([root.appendingPathComponent("a"), root.appendingPathComponent("missing")]) == 1024)
    }
}
