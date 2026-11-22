@testable import MLXBits_Image_Studio
import Testing

struct RAMFitTests {
    @Test(arguments: [(9.0, RAMFit.comfortable), (9.6, .tight), (12.8, .strained), (14.4, .tooBig), (20.0, .tooBig)])
    func fitIsTheShareOfPhysicalRAM(ram: Double, expected: RAMFit) {
        #expect(RAMFit.of(ramGB: ram, physicalGB: 16) == expected)
    }

    @Test func unknownPhysicalRAMIsTooBig() {
        #expect(RAMFit.of(ramGB: 1, physicalGB: 0) == .tooBig)
    }

    @Test func everyFitHasATooltip() {
        for fit in [RAMFit.comfortable, .tight, .strained, .tooBig] {
            #expect(!fit.tooltip.isEmpty)
        }
    }
}
