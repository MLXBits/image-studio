import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The two FileAccess implementations (spec §4, §7). The DMG passes every path
/// through. The App Store one keeps security-scoped bookmarks and starts them
/// while a lease holds them. Bookmarks resolve outside the sandbox too, so the
/// sandbox implementation runs here as it does in the app.
final class FileAccessTests {
    private let root: URL
    private let folder: URL
    private let lora: URL

    init() throws {
        root = FakeRuntime.tempDirectory("FileAccessTests")
        folder = root.appendingPathComponent("Chosen", isDirectory: true)
        lora = folder.appendingPathComponent("style.safetensors")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: lora)
    }

    /// `isReadable` stands in for the sandbox: pass `{ _ in false }` to deny
    /// every read that no grant covers, as the App Store build does.
    private func sandbox(
        codec: BookmarkCodec = .securityScoped, isReadable: @escaping (String) -> Bool = FileAccessPath.isReadable
    ) -> SandboxFileAccess {
        SandboxFileAccess(storeURL: root.appendingPathComponent("grants.json"), codec: codec, isReadable: isReadable)
    }

    @Test func theDMGPassesEverythingThrough() throws {
        let access = PassthroughFileAccess()
        #expect(access.canReach("/no/such/file"))
        try access.beginAccess(to: ["/no/such/file"]).end()
        #expect(access.adoptSourceImage("/elsewhere/a.png", library: "/lib", inputs: root) == "/elsewhere/a.png")
    }

    @Test func aRememberedFolderCoversTheFilesInIt() throws {
        let access = sandbox()
        access.remember(folder)
        let lease = try access.beginAccess(to: [lora.path])
        #expect(access.startedGrantPaths == [FileAccessPath.normalized(folder.path)])
        lease.end()
        #expect(access.startedGrantPaths.isEmpty)
    }

    @Test func overlappingLeasesShareOneStartedGrant() throws {
        let access = sandbox()
        access.remember(folder)
        let first = try access.beginAccess(to: [lora.path])
        let second = try access.beginAccess(to: [folder.path])
        first.end()
        first.end() // ending twice is harmless
        #expect(access.startedGrantPaths.count == 1)
        second.end()
        #expect(access.startedGrantPaths.isEmpty)
    }

    @Test func aDeletedFileIsReportedAsLost() throws {
        let access = sandbox()
        access.remember(lora)
        try FileManager.default.removeItem(at: lora)
        #expect(!access.canReach(lora.path))
        #expect(throws: FileAccessError.accessLost(lora.path)) {
            try access.beginAccess(to: [lora.path])
        }
        #expect(FileAccessError.accessLost(lora.path).localizedDescription
            == "Access to style.safetensors was lost — locate the file again.")
    }

    @Test func repoIDsAndEmptyPathsAreNotFiles() throws {
        let access = sandbox()
        let lease = try access.beginAccess(to: ["org/some-lora", "", "server-lora.safetensors"])
        #expect(access.startedGrantPaths.isEmpty)
        lease.end()
    }

    @Test func sessionAccessSkipsWhatItCantReach() {
        let access = sandbox()
        access.remember(folder)
        let lease = access.beginAccess(toAvailable: [folder.path, root.appendingPathComponent("gone").path])
        #expect(access.startedGrantPaths.count == 1)
        lease.end()
    }

    /// A moved folder isn't followed: the grant resolves somewhere else now, so
    /// the old path counts as gone — what the DMG would see too.
    @Test func aMovedFolderIsNotFollowed() throws {
        let access = sandbox()
        access.remember(folder)
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Moved", isDirectory: true))
        #expect(!access.canReach(lora.path))
        #expect(throws: FileAccessError.self) {
            try access.beginAccess(to: [lora.path])
        }
    }

    @Test func aStaleBookmarkIsRecreated() throws {
        var made = 0
        let real = BookmarkCodec.securityScoped
        let codec = BookmarkCodec(
            make: { url in
                made += 1
                return try real.make(url)
            },
            resolve: { data in try (real.resolve(data).url, true) }
        )
        let access = sandbox(codec: codec)
        access.remember(folder)
        try access.beginAccess(to: [lora.path]).end()
        #expect(made == 2)
    }

    @Test func aForgottenGrantIsNotUsed() throws {
        let access = sandbox()
        access.remember(folder)
        access.forget(folder.path)
        let lease = try access.beginAccess(to: [lora.path])
        #expect(access.startedGrantPaths.isEmpty)
        lease.end()
    }

    /// A grant whose bookmark no longer resolves (spec §4: "An unresolvable
    /// bookmark shows the existing missing-library banner") stops counting as
    /// access once it has failed to start, so the banner and Locate… appear.
    @Test func aGrantThatFailsToStartIsNoLongerTrusted() {
        let real = BookmarkCodec.securityScoped
        let unresolvable = BookmarkCodec(make: real.make) { _ in throw CocoaError(.fileReadCorruptFile) }
        let access = sandbox(codec: unresolvable) { _ in false }
        access.remember(folder)
        #expect(access.canReach(lora.path))

        access.beginAccess(toAvailable: [folder.path]).end()

        #expect(!access.canReach(lora.path))
        access.remember(folder) // choosing it again gives it another chance
        #expect(access.canReach(lora.path))
    }

    /// A path that isn't there is never resolved: resolving a bookmark to an
    /// offline network share can try to mount it on the main thread.
    @Test func aMissingPathIsNotResolved() throws {
        var resolved = 0
        let real = BookmarkCodec.securityScoped
        let codec = BookmarkCodec(make: real.make) { data in
            resolved += 1
            return try real.resolve(data)
        }
        let access = sandbox(codec: codec)
        access.remember(lora)
        try FileManager.default.removeItem(at: lora)
        #expect(throws: FileAccessError.self) {
            try access.beginAccess(to: [lora.path])
        }
        #expect(resolved == 0)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
