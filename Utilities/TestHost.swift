import Foundation

/// Whether this process is the unit tests' host. The tests run inside the app,
/// so without this a test run would launch a second copy of the app against the
/// user's real profile data — while their own build may be running on it.
enum TestHost {
    /// Xcode sets these when it injects the test bundle into the app.
    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
    }
}
