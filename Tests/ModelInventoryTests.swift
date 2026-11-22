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

    private func preferred(cached: Set<Int>, ram: [Int: Double]) -> Int {
        let row = ModelInventory.row(
            for: .krea2, isCached: { cached.contains($0) }, ramGB: { ram[$0] ?? 1 }, physicalGB: 10, toolMissing: false
        )
        return ModelInventory.preferredQuantize(row)
    }

    @Test func preferredQuantizeIsTheLargestCachedQuantThatFits() {
        #expect(preferred(cached: [8, 4], ram: [8: 8.5, 4: 2]) == 4)
        #expect(preferred(cached: [0, 8], ram: [0: 2, 8: 2]) == 0)
        #expect(preferred(cached: [], ram: [:]) == 8)
        #expect(preferred(cached: [4], ram: [4: 20]) == 8)
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
        let spec = HFDownloadSpec(repo: "numz/SeedVR2_comfyUI", revision: "rev123", include: ["a.safetensors", "b.safetensors"])
        let folder = ModelDownloadStore.cacheFolder(repo: spec.repo, hubDir: hub)
        let fm = FileManager.default
        let revision = folder.appendingPathComponent("snapshots/rev123", isDirectory: true)
        try fm.createDirectory(at: revision, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: revision.appendingPathComponent("a.safetensors"))
        #expect(!ModelInventory.isCached(spec, hubDir: hub))
        try Data("b".utf8).write(to: revision.appendingPathComponent("b.safetensors"))
        #expect(ModelInventory.isCached(spec, hubDir: hub))

        let other = FakeRuntime.tempDirectory("ModelInventoryTests")
        let elsewhere = ModelDownloadStore.cacheFolder(repo: spec.repo, hubDir: other)
            .appendingPathComponent("snapshots/other", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for name in spec.include {
            try Data("x".utf8).write(to: elsewhere.appendingPathComponent(name))
        }
        #expect(!ModelInventory.isCached(spec, hubDir: other))
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
}
