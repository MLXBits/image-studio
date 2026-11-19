import CoreGraphics
@testable import MLXBits_Image_Studio
import Testing

struct ComparePanLimitTests {
    private let pane = CGSize(width: 432, height: 432) // 400×400 inside 16pt padding

    @Test func fittedImageCannotPan() {
        #expect(CompareView.panLimit(imageSize: CGSize(width: 800, height: 800), pane: pane, scale: 1) == .zero)
    }

    @Test func zoomedSquareCanPanBothWays() {
        // 400 × 3 = 1200 shown in a 432 pane → (1200 − 432) / 2 = 384 each way.
        let limit = CompareView.panLimit(imageSize: CGSize(width: 800, height: 800), pane: pane, scale: 3)
        #expect(limit == CGSize(width: 384, height: 384))
    }

    @Test func portraitAndLandscapeLimitDifferentAxes() {
        // The reason Compare takes the larger limit per axis: at 2×, a landscape
        // image has no vertical room left, but a portrait one does.
        let landscape = CompareView.panLimit(imageSize: CGSize(width: 1600, height: 800), pane: pane, scale: 2)
        let portrait = CompareView.panLimit(imageSize: CGSize(width: 800, height: 1600), pane: pane, scale: 2)
        #expect(landscape.height == 0 && portrait.height > 0)
        #expect(landscape.width > 0 && portrait.width == 0)
    }
}
