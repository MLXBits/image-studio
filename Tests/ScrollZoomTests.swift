import CoreGraphics
@testable import MLXBits_Image_Studio
import Testing

struct ScrollZoomTests {
    @Test func oneWheelNotchZoomsTwelvePercent() {
        #expect(abs(ScrollZoom.factor(deltaY: 1, precise: false) - 1.12) < 0.0001)
        #expect(abs(ScrollZoom.factor(deltaY: -1, precise: false) - 1 / 1.12) < 0.0001)
    }

    @Test func acceleratedWheelIsCappedAtThreeNotches() {
        let capped = ScrollZoom.factor(deltaY: 40, precise: false)
        #expect(abs(capped - pow(1.12, 3)) < 0.0001)
    }

    @Test func trackpadStaysFine() {
        // A typical small trackpad delta zooms well under one notch.
        let factor = ScrollZoom.factor(deltaY: 2, precise: true)
        #expect(factor > 1 && factor < 1.02)
    }
}
