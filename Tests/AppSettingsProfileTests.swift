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

        let aside = fileA.deletingLastPathComponent().appendingPathComponent("profile.corrupt.json")
        #expect(settings.notepadText == "")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
    }
}
