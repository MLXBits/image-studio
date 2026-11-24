import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// A family's queue history on disk. A save that can't land says so, rather than
/// leaving the queue to come back without its newest change next launch.
@MainActor
struct JobHistoryFileTests {
    @Test func aSaveThatCannotLandReportsUntilOneLands() throws {
        let root = FakeRuntime.tempDirectory("JobHistoryFileTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the profile's data folder should be, so the folder can't be made.
        let blocked = root.appendingPathComponent("profile")
        try Data().write(to: blocked)

        let history = JobHistoryFile(fileName: "jobs.json", directory: blocked)
        history.write(["queued"])
        #expect(history.saveError != nil)

        history.retarget(to: root.appendingPathComponent("profile-2"))
        history.write(["queued"])
        #expect(history.saveError == nil)
        #expect(history.read([String].self) == ["queued"])
    }
}
