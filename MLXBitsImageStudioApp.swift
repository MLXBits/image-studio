import SwiftUI

@main
struct MLXBitsImageStudioApp: App {
    @State private var settings = AppSettings()
    @State private var store = JobStore()
    @State private var gallery = GalleryStore()
    @State private var runner = FluxJobRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(store)
                .environment(gallery)
                .environment(runner)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Preferences…") {}
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
