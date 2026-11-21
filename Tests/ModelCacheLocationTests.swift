import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// "Downloaded" checks look in the models folder the person chose (HF_HOME),
/// not under the home folder, which in the App Store build is the app's
/// container (spec §4: the models folder covers HF_HOME).
struct ModelCacheLocationTests {
    private let root = FakeRuntime.tempDirectory("ModelCacheLocationTests")

    private var hub: URL {
        root.appendingPathComponent("hub", isDirectory: true)
    }

    /// A complete-looking hub cache entry: one sparse blob over 1 GB.
    private func cache(_ repo: String) throws {
        let blobs = hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("weights")
        FileManager.default.createFile(atPath: blob.path, contents: nil)
        let handle = try FileHandle(forWritingTo: blob)
        try handle.truncate(atOffset: 1_100_000_000)
        try handle.close()
    }

    @Test func aModelInTheChosenModelsFolderIsOnDisk() throws {
        try cache("mflux-community/flux2-klein-9b-mflux-q8")
        let noSaves = root.appendingPathComponent("mflux", isDirectory: true)
        #expect(FluxModelVariant.flux2Klein9B.onDiskURL(quantize: 8, hubDir: hub) != nil)
        #expect(FluxModelVariant.flux2Klein9B.isOnDisk(quantize: 8, savedIn: noSaves, hubDir: hub))
    }

    @Test func aModelCachedSomewhereElseIsNotOnDisk() throws {
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        #expect(FluxModelVariant.flux2Klein9B.onDiskURL(quantize: 8, hubDir: hub) == nil)
    }

    /// Ideogram Q8/Q4 come from the mflux-community mflux-save checkpoints. The
    /// older MLXBits repos use a layout mflux rejects, so a leftover copy of one
    /// must not count as downloaded.
    @Test func ideogramQ8IsOnDiskOnlyFromTheMfluxCommunityRepo() throws {
        let noSaves = root.appendingPathComponent("mflux", isDirectory: true)
        try cache("MLXBits/ideogram-4-mlx-q8")
        #expect(!FluxModelVariant.ideogram4.isOnDisk(quantize: 8, savedIn: noSaves, hubDir: hub))
        try cache("mflux-community/ideogram-4-mflux-q8")
        #expect(FluxModelVariant.ideogram4.isOnDisk(quantize: 8, savedIn: noSaves, hubDir: hub))
    }

    /// A level counts only from the exact repo it loads. The upstream repos, the old
    /// third-party quantized ones, and a sibling variant's repo don't — Z-Image's
    /// name is a prefix of Z-Image-Turbo's, and Klein's of Klein Base's.
    @Test func onlyTheLevelsOwnRepoCounts() throws {
        for repo in [
            "Tongyi-MAI/Z-Image", "filipstrand/Z-Image-Turbo-mflux-4bit", "mflux-community/z-image-turbo-mflux-q4",
            "mlx-community/flux2-klein-9b-8bit", "mflux-community/flux-2-klein-base-9b-mflux-q8", "krea/Krea-2-Turbo",
        ] {
            try cache(repo)
        }
        #expect(FluxModelVariant.zimage.hubCacheFolder(quantize: 0, hubDir: hub) == nil)
        #expect(FluxModelVariant.zimage.hubCacheFolder(quantize: 4, hubDir: hub) == nil)
        #expect(FluxModelVariant.flux2Klein9B.hubCacheFolder(quantize: 8, hubDir: hub) == nil)
        #expect(FluxModelVariant.krea2.hubCacheFolder(quantize: 0, hubDir: hub) == nil)
        #expect(FluxModelVariant.zimageTurbo.hubCacheFolder(quantize: 4, hubDir: hub)?
            .lastPathComponent == "models--mflux-community--z-image-turbo-mflux-q4")
        #expect(FluxModelVariant.flux2KleinBase9B.hubCacheFolder(quantize: 8, hubDir: hub)?
            .lastPathComponent == "models--mflux-community--flux-2-klein-base-9b-mflux-q8")
    }

    /// A copy the app's old mflux-save pass wrote is still loaded, so it counts as
    /// downloaded — except for Ideogram, whose old copies are stale.
    @Test func aLegacySavedCopyCountsExceptForIdeogram() throws {
        let saves = root.appendingPathComponent("mflux", isDirectory: true)
        for model in [FluxModelVariant.krea2, .ideogram4] {
            let saved = model.savedModelPath(quantize: 4, in: saves).appendingPathComponent("transformer")
            try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: saved.appendingPathComponent("0.safetensors").path, contents: nil)
        }
        #expect(FluxModelVariant.krea2.isOnDisk(quantize: 4, savedIn: saves, hubDir: hub))
        #expect(FluxModelVariant.krea2.legacySavedWeights(quantize: 4, in: saves) != nil)
        #expect(!FluxModelVariant.ideogram4.isOnDisk(quantize: 4, savedIn: saves, hubDir: hub))
        #expect(FluxModelVariant.ideogram4.legacySavedWeights(quantize: 4, in: saves) == nil)
    }

    @Test func ideogramTermsLinkFollowsThePrecision() {
        let link = { FluxModelVariant.ideogram4.hfRepoURL(quantize: $0)?.absoluteString }
        #expect(link(0) == "https://huggingface.co/mflux-community/ideogram-4-mflux-bf16")
        #expect(link(8) == "https://huggingface.co/mflux-community/ideogram-4-mflux-q8")
        #expect(link(4) == "https://huggingface.co/mflux-community/ideogram-4-mflux-q4")
    }
}
