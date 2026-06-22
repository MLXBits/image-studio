import SwiftUI

@main
struct MLXBitsImageStudioApp: App {
    @State private var settings = AppSettings()
    @State private var store = JobStore()
    @State private var gallery = GalleryStore()
    @State private var runner = FluxJobRunner()
    @State private var ideogram4Store = Ideogram4JobStore()
    @State private var ideogram4Runner = Ideogram4JobRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(store)
                .environment(gallery)
                .environment(runner)
                .environment(ideogram4Store)
                .environment(ideogram4Runner)
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
