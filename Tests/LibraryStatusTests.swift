@testable import MLXBits_Image_Studio
import Testing

/// Whether the active library can take images: drives the missing-library
/// banner and the job guard (spec §4: a library without a grant shows the banner).
struct LibraryStatusTests {
    @Test func noFolderIsUnset() {
        #expect(LibraryStatus(path: "", exists: false, reachable: true) == .unset)
    }

    @Test func aMissingFolderIsMissingEvenWithoutAccess() {
        #expect(LibraryStatus(path: "/L", exists: false, reachable: false) == .missing)
    }

    @Test func aFolderWithoutAGrantNeedsAccess() {
        #expect(LibraryStatus(path: "/L", exists: true, reachable: false) == .noAccess)
        #expect(LibraryStatus(path: "/L", exists: true, reachable: true) == .available)
    }

    @Test func jobsFailWithAReasonUnlessAvailable() {
        #expect(LibraryStatus.available.jobFailureReason(path: "/L") == nil)
        #expect(LibraryStatus.unset.jobFailureReason(path: "") == "No library folder chosen — choose one in Settings")
        #expect(LibraryStatus.missing.jobFailureReason(path: "/L")
            == "Library folder not found: /L — reconnect its drive or choose a folder in Settings")
        #expect(LibraryStatus.noAccess.jobFailureReason(path: "/L")
            == "No access to the library folder /L — choose it again in Settings")
    }
}
