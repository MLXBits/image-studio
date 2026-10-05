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
        try cache("mlx-community/flux2-klein-9b-8bit")
        let noSaves = root.appendingPathComponent("mflux", isDirectory: true)
        #expect(FluxModelVariant.flux2Klein9B.onDiskURL(quantize: 8, hubDir: hub) != nil)
        #expect(FluxModelVariant.flux2Klein9B.isOnDisk(quantize: 8, savedIn: noSaves, hubDir: hub))
    }

    @Test func aModelCachedSomewhereElseIsNotOnDisk() throws {
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        #expect(FluxModelVariant.flux2Klein9B.onDiskURL(quantize: 8, hubDir: hub) == nil)
    }
}
