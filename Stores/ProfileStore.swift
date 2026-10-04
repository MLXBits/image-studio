import AppKit
import Foundation

/// The profiles, and switching between them.
///
/// A profile is a library folder plus its own notepad, prompt history,
/// templates, drafts, job history and thumbnail cache. Activating one points
/// ``AppSettings``, the five job stores and the gallery at that profile's data.
///
/// A switch runs in two steps so nothing from the outgoing profile lands in the
/// incoming one. ``requestSwitch(to:)`` puts the window into
/// ``Phase/switching(_:)``, which tears the old view tree down while the old
/// profile is still active — views that save drafts in `onDisappear` save them
/// to the old profile. The placeholder shown meanwhile then calls
/// ``completePendingSwitch()``.
@Observable
@MainActor
final class ProfileStore {
    enum Phase: Equatable {
        case ready
        case switching(UUID)
        /// The registry can't be read. Nothing is written until it's fixed.
        case failed(String)
    }

    /// Posted before a switch tears the window down, so windows that outlive it
    /// (the Scenario Generator panel) can stop work for the outgoing profile.
    static let willDeactivateNotification = Notification.Name("MLXBitsImageStudio.profileWillDeactivate")

    /// Absolute, standardized, symlink-resolved. Relative paths are returned
    /// as typed so validation can reject them.
    static func resolvedPath(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private(set) var registry = ProfileRegistry(activeProfileID: UUID(), profiles: [])
    private(set) var phase: Phase = .ready
    /// The active profile has a folder but it isn't there (drive unplugged,
    /// folder moved in Finder). Drives the banner in ``ContentView``.
    private(set) var isLibraryMissing = false
    /// Set when saving the profile list fails; shown as an alert.
    var lastError: String?

    @ObservationIgnored private let paths: ProfilePaths
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let jobStores: [any ProfileScopedJobStore]
    @ObservationIgnored private let gallery: GalleryStore
    @ObservationIgnored private let coordinator: GenerationCoordinator
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The profile to delete once the switch away from it completes.
    @ObservationIgnored private var pendingRemoval: UUID?

    var profiles: [Profile] {
        registry.profiles
    }

    var activeProfile: Profile? {
        registry.activeProfile
    }

    var activeProfileID: UUID? {
        activeProfile?.id
    }

    /// The first profile — the one migration created. It can't be removed, and
    /// removing any other profile switches back to it.
    var defaultProfileID: UUID? {
        registry.profiles.first?.id
    }

    /// Remove acts on the active profile, which means switching away from it,
    /// so it's unavailable for the default profile and while switching is blocked.
    var canRemoveActiveProfile: Bool {
        phase == .ready && activeProfileID != defaultProfileID && switchBlockReason == nil
    }

    /// Why the active profile (or its folder) can't change right now, or `nil`.
    /// Output paths resolve when a job starts, so running or queued work would
    /// land in the next profile's library.
    var switchBlockReason: String? {
        ProfileSwitchGate.blockReason(
            isGenerating: coordinator.activeFamily != nil || jobStores.contains { $0.isRunning },
            queuedCount: jobStores.reduce(0) { $0 + $1.queuedCount }
        )
    }

    /// Loads the registry — migrating a pre-profiles install on first launch —
    /// and activates the active profile. Runs before anything else writes
    /// settings, so the migration reads `settings.json` as the old build left it.
    init(
        settings: AppSettings,
        jobStores: [any ProfileScopedJobStore],
        gallery: GalleryStore,
        coordinator: GenerationCoordinator,
        paths: ProfilePaths = .live,
        defaults: LegacyDefaults = UserDefaults.standard
    ) {
        self.settings = settings
        self.jobStores = jobStores
        self.gallery = gallery
        self.coordinator = coordinator
        self.paths = paths

        switch ProfileBootstrap.loadOrMigrate(paths: paths, defaults: defaults) {
        case let .failed(message):
            settings.suspendPersistence()
            phase = .failed(message)
            return
        case let .loaded(loaded):
            registry = loaded
            ProfileBootstrap.cleanUp(registry: loaded, paths: paths, defaults: defaults)
            let root = paths.thumbnailsRoot
            Task.detached(priority: .utility) { ProfileBootstrap.removeLooseThumbnails(in: root) }
        case let .migrated(migrated):
            registry = migrated
            ProfileBootstrap.cleanUp(registry: migrated, paths: paths, defaults: defaults)
            settings.persistGlobalNow()
            if let id = migrated.activeProfile?.id {
                let root = paths.thumbnailsRoot
                let target = paths.thumbnailDirectory(for: id)
                Task.detached(priority: .utility) {
                    ProfileBootstrap.adoptLooseThumbnails(from: root, into: target)
                }
            }
        }
        activateCurrentProfile()
        observeLibraryAvailability()
    }

    // MARK: - Switching

    /// Starts switching to profile `id`; no-op if switching is blocked.
    func requestSwitch(to id: UUID) {
        guard phase == .ready, id != activeProfileID, profiles.contains(where: { $0.id == id }),
              switchBlockReason == nil else { return }
        NotificationCenter.default.post(name: Self.willDeactivateNotification, object: self)
        for window in NSApp.windows {
            // Commit an in-progress text edit while the old profile is active,
            // and drop undo history that could restore its text afterwards.
            window.makeFirstResponder(nil)
            window.undoManager?.removeAllActions()
        }
        phase = .switching(id)
    }

    /// Finishes a switch once the old window content is gone. Safe to call
    /// more than once.
    func completePendingSwitch() {
        guard case let .switching(id) = phase else { return }
        let removing = pendingRemoval
        pendingRemoval = nil
        var next = registry
        next.activeProfileID = id
        next.profiles.removeAll { $0.id == removing }
        if save(next) {
            registry = next
            // Activation flushes the outgoing profile's pending saves into its
            // folders, so a removed profile's data is deleted only after that.
            activateCurrentProfile()
            if let removing {
                deleteData(for: removing)
            }
        }
        phase = .ready
    }

    private func activateCurrentProfile() {
        guard let profile = activeProfile else { return }
        let dir = paths.dataDirectory(for: profile.id)
        settings.activateProfile(contentURL: paths.profileFile(for: profile.id), libraryPath: profile.libraryPath)
        for store in jobStores {
            store.activate(profileDirectory: dir)
        }
        gallery.activate(thumbnailDirectory: paths.thumbnailDirectory(for: profile.id))
        refreshLibraryAvailability()
    }

    // MARK: - Creating, renaming, removing

    /// Adds a profile and returns its ID, or the reason it can't be created.
    func createProfile(name: String, libraryPath: String) -> Result<UUID, ProfileError> {
        if let problem = ProfileRules.nameProblem(name, profiles: profiles, excluding: nil) {
            return .failure(ProfileError(problem.message))
        }
        if let problem = libraryProblem(for: libraryPath, excluding: nil) {
            return .failure(ProfileError(problem))
        }
        let profile = Profile(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            libraryPath: Self.resolvedPath(libraryPath)
        )
        var next = registry
        next.profiles.append(profile)
        guard save(next) else { return .failure(ProfileError(lastError ?? "Couldn't save the profile list.")) }
        registry = next
        return .success(profile.id)
    }

    func renameProfile(_ id: UUID, to name: String) -> ProfileError? {
        if let problem = ProfileRules.nameProblem(name, profiles: profiles, excluding: id) {
            return ProfileError(problem.message)
        }
        guard let idx = registry.profiles.firstIndex(where: { $0.id == id }) else { return nil }
        var next = registry
        next.profiles[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard save(next) else { return ProfileError(lastError ?? "Couldn't save the profile list.") }
        registry = next
        return nil
    }

    /// Removes the active profile with its app-side data (notepad, history,
    /// templates, drafts, job history, thumbnails), switching to the default
    /// profile. Its library folder and images are left on disk.
    func removeActiveProfile() {
        guard canRemoveActiveProfile, let id = activeProfileID, let fallback = defaultProfileID else { return }
        pendingRemoval = id
        requestSwitch(to: fallback)
        if phase == .ready {
            pendingRemoval = nil
        }
    }

    // MARK: - Library folder

    /// Points the active profile at another library folder. `createIfMissing`
    /// is only for the first-run default (`~/MLXBits Image Studio`); a chosen
    /// folder must already exist.
    func changeActiveLibrary(to path: String, createIfMissing: Bool = false) -> ProfileError? {
        guard let id = activeProfileID, let idx = registry.profiles.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        if let reason = switchBlockReason {
            return ProfileError(reason)
        }
        let resolved = Self.resolvedPath(path)
        if createIfMissing, ruleProblem(for: resolved, excluding: id) == nil {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: resolved), withIntermediateDirectories: true
            )
        }
        if let problem = libraryProblem(for: resolved, excluding: id) {
            return ProfileError(problem)
        }
        var next = registry
        next.profiles[idx].libraryPath = resolved
        guard save(next) else { return ProfileError(lastError ?? "Couldn't save the profile list.") }
        registry = next
        settings.applyLibraryPath(resolved)
        gallery.activate(thumbnailDirectory: paths.thumbnailDirectory(for: id), preservingLocks: true)
        gallery.scan(outputDir: resolved)
        refreshLibraryAvailability()
        return nil
    }

    /// Why `path` can't be a library for a profile other than `excluding`, or
    /// `nil`. Resolves symlinks so a link to another library is caught too.
    func libraryProblem(for path: String, excluding: UUID?) -> String? {
        if let problem = ruleProblem(for: path, excluding: excluding) {
            return problem
        }
        let resolved = Self.resolvedPath(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            return "That folder doesn't exist."
        }
        guard isDir.boolValue else { return "That's a file, not a folder." }
        guard FileManager.default.isWritableFile(atPath: resolved) else { return "That folder isn't writable." }
        return nil
    }

    /// Re-checks whether the active library folder is present, rescanning when
    /// it comes back.
    func refreshLibraryAvailability() {
        let missing = !settings.outputDir.isEmpty && !settings.libraryRootExists()
        let cameBack = isLibraryMissing && !missing
        isLibraryMissing = missing
        if cameBack {
            gallery.scan(outputDir: settings.outputDir)
        }
    }

    // MARK: - Private

    /// The same/inside/contains rules against every other profile, with all
    /// paths symlink-resolved first.
    private func ruleProblem(for path: String, excluding: UUID?) -> String? {
        let others = profiles.map {
            Profile(id: $0.id, name: $0.name, libraryPath: Self.resolvedPath($0.libraryPath))
        }
        return ProfileRules.libraryProblem(path: Self.resolvedPath(path), profiles: others, excluding: excluding)?
            .message
    }

    private func deleteData(for id: UUID) {
        try? FileManager.default.removeItem(at: paths.dataDirectory(for: id))
        try? FileManager.default.removeItem(at: paths.thumbnailDirectory(for: id))
    }

    private func save(_ next: ProfileRegistry) -> Bool {
        do {
            try ProfileBootstrap.write(next, to: paths.registry)
            return true
        } catch {
            lastError = "Couldn't save the profile list: \(error.localizedDescription)"
            return false
        }
    }

    private func observeLibraryAvailability() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLibraryAvailability() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLibraryAvailability() }
        })
    }
}

/// A user-facing reason a profile action was refused.
struct ProfileError: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
