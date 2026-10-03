@testable import MLXBits_Image_Studio
import Testing

/// The app keeps a test run away from the real profile data only if it can
/// tell it is the test host. If Xcode stops setting the variables this relies
/// on, this fails — before a later run migrates or cleans up real data.
struct TestHostTests {
    @Test func appRecognisesItIsTheTestHost() {
        #expect(TestHost.isActive)
    }
}
