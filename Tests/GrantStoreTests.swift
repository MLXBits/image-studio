import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The remembered folder and file grants (spec §4), kept in `grants.json` and
/// looked up by path: a grant covers its own path and everything inside it.
struct GrantStoreTests {
    private let root = FakeRuntime.tempDirectory("GrantStoreTests")

    private var storeURL: URL {
        root.appendingPathComponent("grants.json")
    }

    @Test func grantsSurviveARelaunch() {
        GrantStore(url: storeURL).set(Data([1, 2, 3]), for: "/Volumes/Models/hf")
        #expect(GrantStore(url: storeURL).bookmarks["/Volumes/Models/hf"] == Data([1, 2, 3]))
    }

    @Test func theDeepestGrantCoversAPath() {
        let store = GrantStore(url: storeURL)
        store.set(Data([1]), for: "/Users/me/models")
        store.set(Data([2]), for: "/Users/me/models/loras")
        #expect(store.grant(covering: "/Users/me/models/loras/style.safetensors")?.path == "/Users/me/models/loras")
        #expect(store.grant(covering: "/Users/me/models/hub/x")?.path == "/Users/me/models")
        #expect(store.grant(covering: "/Users/me/models")?.bookmark == Data([1]))
    }

    @Test func aSiblingWithTheSamePrefixIsNotCovered() {
        let store = GrantStore(url: storeURL)
        store.set(Data([1]), for: "/a/lib")
        #expect(store.grant(covering: "/a/library/x.png") == nil)
    }

    @Test func forgettingRemovesTheGrant() {
        let store = GrantStore(url: storeURL)
        store.set(Data([1]), for: "/a/lib")
        store.remove("/a/lib")
        #expect(GrantStore(url: storeURL).grant(covering: "/a/lib/x") == nil)
    }

    @Test func pathsHaveOneNormalForm() {
        #expect(FileAccessPath.normalized("/a/b/../lib/") == "/a/lib")
        #expect(FileAccessPath.isLocal("/x") && FileAccessPath.isLocal("~/x"))
        #expect(!FileAccessPath.isLocal("org/repo") && !FileAccessPath.isLocal(""))
    }

    @Test func readabilityIsAnOpenNotAStat() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FileAccessPath.isReadable(root.path))
        #expect(!FileAccessPath.isReadable(root.appendingPathComponent("missing").path))
    }
}
