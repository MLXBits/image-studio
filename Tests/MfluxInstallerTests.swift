@testable import MLXBits_Image_Studio
import Testing

struct MfluxInstallerTests {
    @Test func floorReleaseItselfSatisfies() {
        #expect(MfluxInstaller.satisfiesMinimum(MfluxInstaller.minimumVersion))
    }

    @Test func olderPatchIsBelowFloor() {
        // The case that motivated the floor: 0.18.0 has no mflux-generate-krea2.
        #expect(!MfluxInstaller.satisfiesMinimum("0.18.0"))
        #expect(!MfluxInstaller.satisfiesMinimum("0.17.5"))
    }

    @Test func newerReleasesSatisfy() {
        #expect(MfluxInstaller.satisfiesMinimum("0.18.2"))
        #expect(MfluxInstaller.satisfiesMinimum("0.19.0"))
        #expect(MfluxInstaller.satisfiesMinimum("1.0.0"))
    }

    @Test func componentsCompareNumericallyNotAsText() {
        // "0.9.0" > "0.18.1" under a string compare; "0.18.10" < "0.18.9".
        #expect(!MfluxInstaller.satisfiesMinimum("0.9.0"))
        #expect(MfluxInstaller.satisfiesMinimum("0.18.10"))
    }

    @Test func shorterVersionIsOlderThanItsPatch() {
        #expect(!MfluxInstaller.satisfiesMinimum("0.18"))
        #expect(MfluxInstaller.satisfiesMinimum("0.19"))
    }

    @Test func pep440SuffixesCountAsTheirRelease() {
        // A checkout of the floor release carries the CLIs; don't nag about it.
        #expect(MfluxInstaller.satisfiesMinimum("0.18.1.dev0"))
        #expect(MfluxInstaller.satisfiesMinimum("0.18.1+local"))
        #expect(MfluxInstaller.satisfiesMinimum("0.19.0rc1"))
        #expect(!MfluxInstaller.satisfiesMinimum("0.18.0.dev3"))
    }

    @Test func unparseableVersionIsTreatedAsBelowFloor() {
        #expect(!MfluxInstaller.satisfiesMinimum(""))
        #expect(!MfluxInstaller.satisfiesMinimum("unknown"))
    }
}
