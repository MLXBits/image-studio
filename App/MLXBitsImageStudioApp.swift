import SwiftUI

@main
struct MLXBitsImageStudioApp: App {
    @State private var settings: AppSettings
    @State private var store = JobStore()
    @State private var gallery = GalleryStore()
    @State private var runner: FluxJobRunner
    @State private var driverController: MfluxDriverController
    @State private var ideogram4Store = Ideogram4JobStore()
    @State private var ideogram4Runner = Ideogram4JobRunner()
    @State private var krea2Store = Krea2JobStore()
    @State private var krea2Runner = Krea2JobRunner()
    @State private var coordinator = GenerationCoordinator()
    @State private var timing = TimingStore()
    @State private var loraLibrary = LoraLibraryStore()
    @State private var updateChecker = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(store)
                .environment(gallery)
                .environment(runner)
                .environment(ideogram4Store)
                .environment(ideogram4Runner)
                .environment(krea2Store)
                .environment(krea2Runner)
                .environment(coordinator)
                .environment(timing)
                .environment(driverController)
                .environment(loraLibrary)
                .environment(updateChecker)
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
                .environment(settings)
                .environment(gallery)
                .environment(driverController)
                .environment(loraLibrary)
        }
    }

    init() {
        let settings = AppSettings()
        let driver = MfluxDriverController(settings: settings)
        let runner = FluxJobRunner()
        runner.driver = driver
        _settings = State(initialValue: settings)
        _driverController = State(initialValue: driver)
        _runner = State(initialValue: runner)
        // One shared driver across families — it keeps a single warm model,
        // so cross-family switches evict before loading (see coordinator gate).
        ideogram4Runner.driver = driver
        krea2Runner.driver = driver
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
