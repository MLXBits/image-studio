import Foundation

/// A named library: one folder of generated images plus its own notepad, prompt
/// history, templates, drafts and job history. Models, LoRAs and backend
/// settings are shared across profiles.
struct Profile: Codable, Equatable, Identifiable {
    /// Stable key for the profile's data folder, so a rename moves nothing.
    let id: UUID
    var name: String
    /// Absolute path of the library folder. Empty only for a migrated profile
    /// whose folder has not been chosen yet (the first-run prompt fills it).
    var libraryPath: String
}

/// The on-disk profile list (`profiles.json`) and which profile is active.
struct ProfileRegistry: Codable, Equatable {
    var activeProfileID: UUID
    var profiles: [Profile]

    /// The active profile, falling back to the first one when the stored ID is
    /// stale. `nil` only when the list is empty.
    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }
}
