import SwiftUI

struct MLXBitsImageStudioApp: App {
    static let mainWindowID = "main"

    /// The support nudge's count: the images every runner saves (spec §5).
    private static func makeSupport(testHost: Bool, runners: [any JobOutcomeReporting]) -> SupportStore {
        let support = SupportStore(
            defaults: testHost ? UserDefaults(suiteName: "MLXBitsImageStudio.TestHost") ?? .standard : .standard
        )
        for runner in runners {
            runner.onImagesLanded = { support.recordImages($0) }
        }
        return support
    }

    private static func makeTipJar(support: SupportStore, testHost: Bool) -> TipJarStore {
        let tipJar = TipJarStore(storefront: StoreKitStorefront()) { support.noteTipped() }
        // Tips interrupted last launch, or approved later, are finished as
        // soon as the app starts (spec §5).
        if BuildFlavor.isAppStore, !testHost {
            tipJar.startFinishingTransactions()
        }
        return tipJar
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var profiles: ProfileStore
    @State private var gallery: GalleryStore
    @State private var driverController: MfluxDriverController
    @State private var families: FamilyRegistry
    /// Nil in a test run, which leaves the dock alone.
    @State private var dockBadge: DockBadge?
    @State private var coordinator: GenerationCoordinator
    @State private var timing = TimingStore()
    @State private var loraLibrary = LoraLibraryStore()
    @State private var updateChecker = UpdateChecker()
    @State private var backendModels = BackendModelStore()
    @State private var modelDownloads = ModelDownloadStore()
    /// Models window downloads, which outlive the Settings window (#27).
    @State private var weightDownloads = WeightDownloadStore()
    @State private var router = ModelManagerRouter()
    @State private var support: SupportStore
    @State private var tipJar: TipJarStore

    var body: some Scene {
        // One main window, as a `Window` scene: macOS lists it in the Window
        // menu, so it can be reopened after it's closed (App Review, guideline 4).
        Window("MLXBits Image Studio", id: Self.mainWindowID) {
            profileContent
                .environment(profiles)
                .environment(settings)
                .environment(gallery)
                .environment(families)
                .environment(coordinator)
                .environment(timing)
                .environment(driverController)
                .environment(loraLibrary)
                .environment(updateChecker)
                .environment(backendModels)
                .environment(modelDownloads)
                // The model button re-checks what is downloaded when a Models window download ends.
                .environment(weightDownloads)
                .environment(router)
                .environment(support)
                .frame(minWidth: 900, minHeight: 600)
                // Launch-time update check; drives the toolbar badge when a newer
                // GitHub release exists. Coalesced, so reopening the window checks once.
                .task { await updateChecker.check() }
                .onAppear {
                    appDelegate.isGenerating = { [coordinator] in coordinator.activeFamily != nil }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            AboutCommands()
            MainWindowCommands()
            KeyboardShortcutsCommands()
            CommandGroup(after: .help) {
                // The bundled runtime's third-party notices (spec §2).
                Button("Acknowledgements") {
                    if let url = settings.toolchain.acknowledgementsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(settings.toolchain.acknowledgementsURL == nil)
            }
        }

        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
        }
        .defaultSize(width: 500, height: 620)

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
                .environment(support)
                .environment(weightDownloads)
                .environment(router)
        }

        Window("Models", id: ModelManagerView.windowID) {
            ModelManagerView()
                .environment(settings)
                .environment(weightDownloads)
                .environment(modelDownloads)
                .environment(router)
                .environment(coordinator)
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window("Support MLXBits Image Studio", id: SupportView.windowID) {
            SupportView()
                .environment(support)
                .environment(tipJar)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
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
        // The models folder and other folder settings stay reachable all
        // session (spec §4). didSet doesn't run for init's own assignments.
        settings.refreshSessionAccess()
        let gallery = GalleryStore()
        let coordinator = GenerationCoordinator()
        // The registry builds every family's store and runner, and is handed to
        // State here: a runner given as a property default and then mutated in
        // init is not the instance SwiftUI installs, so it ran without the driver.
        let driver = MfluxDriverController(settings: settings)
        let families = FamilyRegistry(driver: driver)
        // Before anything else writes settings: the first launch after the
        // profiles update migrates settings.json as the old build left it.
        let profiles = ProfileStore(
            settings: settings,
            jobStores: families.jobStores,
            gallery: gallery,
            coordinator: coordinator,
            paths: testHost ? .throwaway() : .live,
            defaults: testHost ? UserDefaults(suiteName: "MLXBitsImageStudio.TestHost") ?? .standard : .standard
        )
        _settings = State(initialValue: settings)
        _profiles = State(initialValue: profiles)
        _gallery = State(initialValue: gallery)
        _coordinator = State(initialValue: coordinator)
        _driverController = State(initialValue: driver)
        _families = State(initialValue: families)
        let support = Self.makeSupport(testHost: testHost, runners: families.reporters)
        // A test run finishes jobs in the background; it must not post notifications.
        if !testHost {
            for reporter in families.reporters {
                reporter.onJobFinished = { BackgroundSignals.jobFinished($0) }
            }
            _dockBadge = State(initialValue: DockBadge { families.imagesLeft })
        }
        _support = State(initialValue: support)
        _tipJar = State(initialValue: Self.makeTipJar(support: support, testHost: testHost))
        // Partial downloads nothing will resume (#18), off the main thread. Then
        // ask mflux which models are downloaded (#19): the sweep changes the
        // folders it asks about, which would make its answers stale at once.
        if !testHost {
            // The Flux runner's --base-model probe imports mflux (seconds); start it now.
            settings.startProbeWarmUps()
            let hubDir = settings.hfHubDir
            Task {
                await Task.detached(priority: .utility) { ModelDownloadStore.removeAbandonedPartials(hubDir: hubDir) }.value
                await HFCacheVerdictStore.shared.refresh(settings: settings)
            }
        }
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
            Button("Support MLXBits Image Studio…") {
                openWindow(id: SupportView.windowID)
            }
        }
    }
}
