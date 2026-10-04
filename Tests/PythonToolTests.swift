import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The runtime build smoke-tests every name in `Runtime/tools.txt`, so the app
/// must ask for exactly those: a renamed command then fails a test, not a job.
struct PythonToolTests {
    /// `Runtime/tools.txt` from the source tree (tests run from a checkout).
    private func listedTools() throws -> Set<String> {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent("Runtime/tools.txt"), encoding: .utf8)
        return Set(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    @Test func everyToolIsOneTheRuntimeBuildSmokeTests() throws {
        let listed = try listedTools()
        #expect(Set(PythonTool.allCases.map(\.rawValue)) == listed)
    }

    @Test func onlyMfluxToolsFollowTheCustomPython() {
        #expect(PythonTool.allCases.filter(\.isMflux)
            == [.flux2, .flux2Edit, .ideogram4, .krea2, .zImage, .zImageTurbo, .seedVR2, .save])
    }
}
