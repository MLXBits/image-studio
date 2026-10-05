import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Source images from outside the library are copied into the profile's
/// `Inputs/` folder in the App Store build (spec §4), so re-runs and templates
/// keep working after a relaunch. Images already in the library stay in place.
struct SourceImageImportTests {
    private let root = FakeRuntime.tempDirectory("SourceImageImportTests")

    private var library: URL {
        root.appendingPathComponent("Library", isDirectory: true)
    }

    private var inputs: URL {
        root.appendingPathComponent("Profiles/P/Inputs", isDirectory: true)
    }

    private func image(_ name: String, in dir: URL, bytes: String = "png-bytes") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func anImageInTheLibraryIsUsedInPlace() throws {
        let inLibrary = try image("a.png", in: library.appendingPathComponent("Board", isDirectory: true))
        #expect(try SourceImageImport.adopt(inLibrary.path, library: library.path, inputs: inputs) == inLibrary.path)
        #expect(!FileManager.default.fileExists(atPath: inputs.path))
    }

    @Test func anImageFromElsewhereIsCopiedIntoInputs() throws {
        let outside = try image("Photo.PNG", in: root.appendingPathComponent("Downloads", isDirectory: true))
        let adopted = try SourceImageImport.adopt(outside.path, library: library.path, inputs: inputs)
        #expect(URL(fileURLWithPath: adopted).deletingLastPathComponent().path == inputs.path)
        #expect(adopted.hasSuffix(".png"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: adopted)) == Data("png-bytes".utf8))
    }

    @Test func theSameImageIsStoredOnce() throws {
        let one = try image("a.png", in: root.appendingPathComponent("X", isDirectory: true))
        let two = try image("b.png", in: root.appendingPathComponent("Y", isDirectory: true))
        let first = try SourceImageImport.adopt(one.path, library: library.path, inputs: inputs)
        let second = try SourceImageImport.adopt(two.path, library: library.path, inputs: inputs)
        #expect(first == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inputs.path).count == 1)
    }

    @Test func anImageAlreadyInInputsIsUsedInPlace() throws {
        let outside = try image("a.png", in: root.appendingPathComponent("X", isDirectory: true))
        let adopted = try SourceImageImport.adopt(outside.path, library: library.path, inputs: inputs)
        #expect(try SourceImageImport.adopt(adopted, library: library.path, inputs: inputs) == adopted)
    }

    @Test func theSandboxAdoptsAndTheDMGDoesNot() throws {
        let outside = try image("a.png", in: root.appendingPathComponent("X", isDirectory: true))
        let sandbox = SandboxFileAccess(storeURL: root.appendingPathComponent("grants.json"))
        #expect(sandbox.adoptSourceImage(outside.path, library: library.path, inputs: inputs) != outside.path)
        #expect(PassthroughFileAccess().adoptSourceImage(outside.path, library: library.path, inputs: inputs)
            == outside.path)
    }
}
