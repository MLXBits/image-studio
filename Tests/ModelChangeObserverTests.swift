@testable import MLXBits_Image_Studio
import Testing

struct ModelChangeObserverTests {
    @Test func sameSelectionFiresNothing() {
        let fired = ModelChangeObserver.firing(
            from: (.krea2, .flux2Klein9B),
            to: (.krea2, .flux2Klein9B)
        )
        #expect(fired.isEmpty)
    }

    @Test func stockToStockFiresModelOnly() {
        let fired = ModelChangeObserver.firing(
            from: (.zimageTurbo, .flux2Klein9B),
            to: (.zimage, .flux2Klein9B)
        )
        #expect(fired == [.model])
    }

    @Test func stockToCustomWithNewTargetFiresBoth() {
        let fired = ModelChangeObserver.firing(
            from: (.krea2, .flux2Klein9B),
            to: (.custom, .krea2)
        )
        #expect(fired == [.model, .customBase])
    }

    @Test func customTargetChangeAloneFiresCustomBaseOnly() {
        let fired = ModelChangeObserver.firing(
            from: (.custom, .zimageTurbo),
            to: (.custom, .krea2)
        )
        #expect(fired == [.customBase])
    }

    /// The custom-base handler returns early off `Custom…`, so arming it would
    /// swallow the user's next real target change.
    @Test func customBaseChangeOffCustomIsNotArmed() {
        let fired = ModelChangeObserver.firing(
            from: (.custom, .krea2),
            to: (.qwen21Turbo, .flux2Klein9B)
        )
        #expect(fired == [.model])
    }
}
