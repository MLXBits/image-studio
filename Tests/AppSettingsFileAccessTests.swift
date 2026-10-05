import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// AppSettings holds its folder settings open for the session (the models
/// folder, the mflux cache, local model and Gemma folders), and copies outside
/// source images into the active profile's Inputs/ (spec §4).
struct AppSettingsFileAccessTests {
    private func settings(_ access: any FileAccess) -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.fileAccess = access
        return settings
    }

    @Test func choosingAModelsFolderHoldsItAndLetsTheOldOneGo() {
        let access = RecordingFileAccess()
        let s = settings(access)
        s.hfHome = "/Volumes/Models/hf"
        #expect(access.isHeld("/Volumes/Models/hf"))
        s.hfHome = "/Volumes/Other/hf"
        #expect(access.isHeld("/Volumes/Other/hf"))
        #expect(!access.isHeld("/Volumes/Models/hf"))
    }

    @Test func localModelFoldersAreHeldAndRepoIDsAreNot() {
        let access = RecordingFileAccess()
        let s = settings(access)
        var defaults = s.defaults(for: .flux2Klein9B)
        defaults.modelRepoOverride = "/Volumes/Models/klein"
        s.updateDefaults(defaults, for: .flux2Klein9B)
        s.mfluxCacheDir = "/Volumes/Models/mflux"
        s.gemmaModelPath = "mlx-community/gemma-3-12b-it-4bit"
        #expect(access.isHeld("/Volumes/Models/klein"))
        #expect(access.isHeld("/Volumes/Models/mflux"))
        #expect(!access.isHeld("mlx-community/gemma-3-12b-it-4bit"))
    }

    @Test func sourceImagesLandInTheActiveProfilesInputs() throws {
        let root = FakeRuntime.tempDirectory("AppSettingsFileAccessTests")
        let s = settings(SandboxFileAccess(storeURL: root.appendingPathComponent("grants.json")))
        s.activateProfile(
            contentURL: root.appendingPathComponent("Profiles/P/profile.json"),
            libraryPath: root.appendingPathComponent("Library").path
        )
        let outside = root.appendingPathComponent("Downloads/a.png")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: outside)

        #expect(s.inputsDirectory?.path == root.appendingPathComponent("Profiles/P/Inputs").path)
        #expect(s.adoptSourceImage(outside.path).hasPrefix(root.appendingPathComponent("Profiles/P/Inputs").path))
    }
}
