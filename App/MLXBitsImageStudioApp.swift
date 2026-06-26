import SwiftUI

@main
struct MLXBitsImageStudioApp: App {
    @State private var settings = AppSettings()
    @State private var store = JobStore()
    @State private var gallery = GalleryStore()
    @State private var runner = FluxJobRunner()
    @State private var ideogram4Store = Ideogram4JobStore()
    @State private var ideogram4Runner = Ideogram4JobRunner()
    @State private var krea2Store = Krea2JobStore()
    @State private var krea2Runner = Krea2JobRunner()
    @State private var coordinator = GenerationCoordinator()
    @State private var timing = TimingStore()

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
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(gallery)
        }
    }
}
