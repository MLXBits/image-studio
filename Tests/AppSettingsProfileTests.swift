import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers how AppSettings swaps its per-profile fields. Saves are debounced, so
/// the order inside a switch (flush the old profile, then load the new one)
/// decides which profile an edit made just before the switch ends up in.
struct AppSettingsProfileTests {
    private func profileFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsProfileTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("profile.json")
    }

    private func notepad(in url: URL) throws -> String? {
        try JSONDecoder().decode(AppSettings.ProfileStored.self, from: Data(contentsOf: url)).notepadText
    }

    @Test func editsMadeBeforeASwitchStayInTheirProfile() throws {
        let fileA = profileFile()
        let fileB = profileFile()
        let settings = AppSettings()
        settings.activateProfile(contentURL: fileA, libraryPath: "/lib/A")
        settings.notepadText = "A's notes"

        settings.activateProfile(contentURL: fileB, libraryPath: "/lib/B")

        #expect(settings.notepadText == "")
        #expect(settings.outputDir == "/lib/B")
        #expect(try notepad(in: fileA) == "A's notes")

        settings.activateProfile(contentURL: fileA, libraryPath: "/lib/A")
        #expect(settings.notepadText == "A's notes")
    }

    /// Loading a profile assigns every field; those assignments must not be
    /// saved back (or, worse, flushed into the next profile's file).
    @Test func activatingWritesNothing() {
        let fileA = profileFile()
        let settings = AppSettings()
        settings.activateProfile(contentURL: fileA, libraryPath: "/lib/A")
        settings.activateProfile(contentURL: profileFile(), libraryPath: "/lib/B")

        #expect(!FileManager.default.fileExists(atPath: fileA.path))
    }

    @Test func unreadableProfileFileIsSetAside() throws {
        let fileA = profileFile()
        try FileManager.default.createDirectory(
            at: fileA.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileA)
        let settings = AppSettings()

        settings.activateProfile(contentURL: fileA, libraryPath: "/lib/A")

        #expect(settings.notepadText == "")
        #expect(try corruptBackups(beside: fileA) == ["not json"])
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
    }

    /// A second corruption must not delete the first backup — it may hold the
    /// only copy of the notes.
    @Test func earlierCorruptBackupIsKept() throws {
        let fileA = profileFile()
        let dir = fileA.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = AppSettings()

        try Data("first".utf8).write(to: fileA)
        settings.activateProfile(contentURL: fileA, libraryPath: "/lib/A")
        try Data("second".utf8).write(to: fileA)
        settings.activateProfile(contentURL: fileA, libraryPath: "/lib/A")

        #expect(try corruptBackups(beside: fileA).sorted() == ["first", "second"])
    }

    private func corruptBackups(beside file: URL) throws -> [String] {
        let dir = file.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("profile.corrupt") }
            .map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
    }
}
