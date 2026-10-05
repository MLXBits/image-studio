import Foundation

/// AppSettings' part in sandbox file access (spec §4).
extension AppSettings {
    /// The folders read all session long: the models folder, the mflux cache,
    /// and any local model or Gemma folder. Repo IDs and empty settings drop out
    /// in ``FileAccess``.
    var sessionAccessPaths: [String] {
        [hfHome, mfluxCacheDir, gemmaModelPath, ideogram4ModelRepoOverride ?? ""]
            + modelDefaults.values.compactMap(\.modelRepoOverride)
    }

    /// The active profile's `Inputs/` folder, where source images from outside
    /// the library are copied.
    var inputsDirectory: URL? {
        profileFileURL?.deletingLastPathComponent().appendingPathComponent("Inputs", isDirectory: true)
    }

    /// Whether the active library can take new images.
    var libraryStatus: LibraryStatus {
        LibraryStatus(path: outputDir, exists: libraryRootExists(), reachable: fileAccess.canReach(outputDir))
    }

    /// Re-holds ``sessionAccessPaths`` after one changes. The new lease starts
    /// before the old one ends, so a folder in both is never dropped in between.
    func refreshSessionAccess() {
        let next = fileAccess.beginAccess(toAvailable: sessionAccessPaths)
        sessionLease?.end()
        sessionLease = next
    }

    /// The path a source image should be used from: in place when it's in the
    /// library; otherwise, in the App Store build, a copy in ``inputsDirectory``.
    func adoptSourceImage(_ path: String) -> String {
        fileAccess.adoptSourceImage(path, library: outputDir, inputs: inputsDirectory)
    }
}
