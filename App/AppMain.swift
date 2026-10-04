import Foundation

/// The process entry point. `--runtime-self-test` runs before any app state
/// exists (no settings, profiles or windows), so a release workflow can run it
/// on a fresh runner and a developer can run it beside their real data.
@main
enum AppMain {
    static func main() {
        if CommandLine.arguments.contains(RuntimeSelfTest.flag) {
            let toolchain = Toolchain(resourcesURL: Bundle.main.resourceURL, customPython: "")
            var environment = Toolchain.environment(
                base: ProcessInfo.processInfo.environment, cachesURL: Toolchain.cachesURL
            )
            environment["HF_HUB_OFFLINE"] = "1" // --help never needs the network
            exit(RuntimeSelfTest.run(toolchain: toolchain, environment: environment) { print($0) })
        }
        MLXBitsImageStudioApp.main()
    }
}
