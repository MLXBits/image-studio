import SwiftUI

@main
struct MLXBitsImageStudioApp: App {
    @State private var settings: AppSettings
    @State private var profiles: ProfileStore
    @State private var store: JobStore
    @State private var gallery: GalleryStore
    @State private var runner: FluxJobRunner
    @State private var driverController: MfluxDriverController
    @State private var ideogram4Store: Ideogram4JobStore
    @State private var ideogram4Runner = Ideogram4JobRunner()
    @State private var krea2Store: Krea2JobStore
    @State private var krea2Runner = Krea2JobRunner()
    @State private var zimageStore: ZImageJobStore
    @State private var zimageRunner = ZImageJobRunner()
    @State private var seedVR2Store: SeedVR2JobStore
    @State private var seedVR2Runner = SeedVR2JobRunner()
    @State private var coordinator: GenerationCoordinator
    @State private var timing = TimingStore()
    @State private var loraLibrary = LoraLibraryStore()
    @State private var updateChecker = UpdateChecker()
    @State private var backendModels = BackendModelStore()

    var body: some Scene {
        WindowGroup {
            profileContent
                .environment(profiles)
                .environment(settings)
                .environment(store)
                .environment(gallery)
                .environment(runner)
                .environment(ideogram4Store)
                .environment(ideogram4Runner)
                .environment(krea2Store)
                .environment(krea2Runner)
                .environment(zimageStore)
                .environment(zimageRunner)
                .environment(seedVR2Store)
                .environment(seedVR2Runner)
                .environment(coordinator)
                .environment(timing)
                .environment(driverController)
                .environment(loraLibrary)
                .environment(updateChecker)
                .environment(backendModels)
                .frame(minWidth: 900, minHeight: 600)
                // Launch-time update check; drives the toolbar badge when a newer
                // GitHub release exists. Coalesced so multiple windows check once.
                .task { await updateChecker.check() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            AboutCommands()
        }

        Window("About MLXBits Image Studio", id: AboutCommands.windowID) {
            AboutView()
                .environment(updateChecker)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(profiles)
                .environment(settings)
                .environment(gallery)
                .environment(driverController)
                .environment(loraLibrary)
        }
    }

    /// The main window's content for the current profile phase. ContentView is
    /// keyed by the profile, so a switch rebuilds it — and all its per-window
    /// state — from the new profile's data.
    @ViewBuilder private var profileContent: some View {
        switch profiles.phase {
        case .ready:
            ContentView().id(profiles.activeProfileID)
        case .switching:
            ProfileSwitchingView()
        case let .failed(message):
            ProfileUnavailableView(message: message)
        }
    }

    init() {
        let settings = AppSettings()
        // The unit tests run inside this app. Keep a test run away from the real
        // profile data — the user's own build may be running against it — by
        // giving it a throwaway profile folder and writing no settings.
        let testHost = TestHost.isActive
        if testHost {
            settings.suspendPersistence()
        }
        let store = JobStore()
        let gallery = GalleryStore()
        let ideogram4Store = Ideogram4JobStore()
        let krea2Store = Krea2JobStore()
        let zimageStore = ZImageJobStore()
        let seedVR2Store = SeedVR2JobStore()
        let coordinator = GenerationCoordinator()
        // Before anything else writes settings: the first launch after the
        // profiles update migrates settings.json as the old build left it.
        let profiles = ProfileStore(
            settings: settings,
            jobStores: [store, ideogram4Store, krea2Store, zimageStore, seedVR2Store],
            gallery: gallery,
            coordinator: coordinator,
            paths: testHost ? .throwaway() : .live,
            defaults: testHost ? UserDefaults(suiteName: "MLXBitsImageStudio.TestHost") ?? .standard : .standard
        )
        let driver = MfluxDriverController(settings: settings)
        let runner = FluxJobRunner()
        runner.driver = driver
        _settings = State(initialValue: settings)
        _profiles = State(initialValue: profiles)
        _store = State(initialValue: store)
        _gallery = State(initialValue: gallery)
        _ideogram4Store = State(initialValue: ideogram4Store)
        _krea2Store = State(initialValue: krea2Store)
        _zimageStore = State(initialValue: zimageStore)
        _seedVR2Store = State(initialValue: seedVR2Store)
        _coordinator = State(initialValue: coordinator)
        _driverController = State(initialValue: driver)
        _runner = State(initialValue: runner)
        // One shared driver across families — it keeps a single warm model,
        // so cross-family switches evict before loading (see coordinator gate).
        ideogram4Runner.driver = driver
        krea2Runner.driver = driver
        zimageRunner.driver = driver
        // Fold any pre-library default-LoRA list into LibraryLora.isDefault flags.
        loraLibrary.migrateLegacyDefaults(from: settings)
    }
}

/// Replaces the standard "About" menu item so it opens our custom About window,
/// which shows the running version and checks GitHub for the latest release.
struct AboutCommands: Commands {
    static let windowID = "about"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MLXBits Image Studio") {
                openWindow(id: Self.windowID)
            }
        }
    }
}
