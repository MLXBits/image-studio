import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// First run in the App Store build (spec §4). Skip for Now makes the library
/// in Pictures, which the sandbox may write to. An existing Hugging Face cache
/// is offered as the models folder.
struct FirstRunPathsTests {
    @Test func skipForNowUsesPicturesInTheAppStoreBuild() {
        #expect(FileAccessPath.defaultLibrary(isAppStore: true, home: "/Users/me")
            == "/Users/me/Pictures/MLXBits Image Studio")
        #expect(FileAccessPath.defaultLibrary(isAppStore: false, home: "/Users/me") == "/Users/me/MLXBits Image Studio")
    }

    @Test func anExistingHuggingFaceCacheIsOffered() throws {
        let home = FakeRuntime.tempDirectory("FirstRunPathsTests")
        #expect(FileAccessPath.existingHuggingFaceCache(home: home.path) == nil)
        let cache = home.appendingPathComponent(".cache/huggingface", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #expect(FileAccessPath.existingHuggingFaceCache(home: home.path)?.path == cache.path)
    }
}
