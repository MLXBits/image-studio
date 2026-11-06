@testable import MLXBits_Image_Studio
import Testing

/// Steps typed as 0 or above the cap must not reach mflux (#80).
struct StepClampTests {
    @Test func clampsToFamilyRange() {
        #expect(FluxModelVariant.flux2Klein9B.clampedSteps(0) == 1)
        #expect(FluxModelVariant.flux2Klein9B.clampedSteps(500) == 150)
        #expect(FluxModelVariant.krea2.clampedSteps(80) == 50)
        #expect(FluxModelVariant.zimageTurbo.clampedSteps(-3) == 1)
        #expect(FluxModelVariant.zimage.clampedSteps(30) == 30)
    }

    @Test func savedDefaultIsClamped() {
        let defaults = ModelDefaults(steps: 0)
        #expect(defaults.resolved(for: .krea2).steps == 1)
        #expect(ModelDefaults(steps: 999).resolved(for: .krea2).steps == 50)
    }
}
