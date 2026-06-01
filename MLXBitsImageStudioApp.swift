import SwiftUI

@main
struct MLXBitsImageStudioApp: App {
    @State private var settings = AppSettings()
    @State private var store = JobStore()
    @State private var gallery = GalleryStore()
    @State private var runner = FluxJobRunner()

    init() {
        UserDefaults.standard.set(300, forKey: "NSInitialToolTipDelay")
    }

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

        Settings {
            SettingsView()
                .environment(settings)
                .environment(gallery)
        }
    }
}
