import CoreGraphics
@testable import MLXBits_Image_Studio
import Testing

/// The zoom and pan math the full-size viewer and Compare share.
struct ImageZoomStateTests {
    /// A 440pt pane: 400×400 inside 20pt padding, at the window's origin.
    private let frame = CGRect(x: 0, y: 0, width: 440, height: 440)
    private let square = CGSize(width: 800, height: 800)

    private func fit(_ images: CGSize...) -> ImageZoomState.Fit {
        ImageZoomState.Fit(images: images, frame: frame, padding: 20)
    }

    // MARK: - Pan limits

    @Test func aFittedImageCannotPan() {
        #expect(ImageZoomState.panLimit(imageSize: square, pane: frame.size, padding: 20, scale: 1) == .zero)
    }

    @Test func aZoomedSquareCanPanBothWays() {
        // 400 × 3 = 1200 shown in a 440 pane → (1200 − 440) / 2 = 380 each way.
        let limit = ImageZoomState.panLimit(imageSize: square, pane: frame.size, padding: 20, scale: 3)
        #expect(limit == CGSize(width: 380, height: 380))
    }

    @Test func portraitAndLandscapeLimitDifferentAxes() {
        // At 2×, a landscape image has no vertical room left, but a portrait one does.
        let landscape = ImageZoomState.panLimit(
            imageSize: CGSize(width: 1600, height: 800), pane: frame.size, padding: 20, scale: 2
        )
        let portrait = ImageZoomState.panLimit(
            imageSize: CGSize(width: 800, height: 1600), pane: frame.size, padding: 20, scale: 2
        )
        #expect(landscape.height == 0 && portrait.height > 0)
        #expect(landscape.width > 0 && portrait.width == 0)
    }

    @Test func twoImagesPanAsFarAsTheFurtherOfThemOnEachAxis() {
        // Compare's two panes share one offset: a Select-only limit stopped
        // a candidate of another aspect ratio short of its own edges.
        let both = fit(CGSize(width: 1600, height: 800), CGSize(width: 800, height: 1600))
        let limit = both.limit(at: 2)
        #expect(limit.width > 0 && limit.height > 0)
        #expect(limit.width == limit.height)
    }

    @Test func noImageCannotPan() {
        #expect(fit().limit(at: 4) == .zero)
    }

    // MARK: - Zoom

    @Test func zoomStaysBetweenFitAndTwelveTimes() {
        var state = ImageZoomState()
        state.zoom(by: 0.5, toward: nil, in: fit(square))
        #expect(state.scale == 1 && !state.isZoomed)

        state.zoom(by: 100, toward: nil, in: fit(square))
        #expect(state.scale == ImageZoomState.maxScale && state.isZoomed)
    }

    @Test func zoomKeepsThePointUnderThePointerStill() {
        var state = ImageZoomState()
        // 100pt right of centre. Before: shown at +100. After 2×: offset + 2 × 100.
        state.zoom(by: 2, toward: CGPoint(x: 320, y: 220), in: fit(square))
        #expect(state.offset == CGSize(width: -100, height: 0))
        #expect(state.offset.width + 2 * 100 == 100)
    }

    @Test func zoomTowardAnEdgeStopsAtThePanLimit() {
        var state = ImageZoomState()
        // At 2× the limit is (800 − 440) / 2 = 180; the corner would ask for −220.
        state.zoom(by: 2, toward: CGPoint(x: 440, y: 440), in: fit(square))
        #expect(state.offset == CGSize(width: -180, height: -180))
    }

    @Test func zoomWithoutAPointerKeepsTheOffset() {
        var state = ImageZoomState()
        state.zoom(by: 4, toward: nil, in: fit(square))
        state.pan(by: CGSize(width: 50, height: -30), in: fit(square))
        state.endPan(in: fit(square))
        state.zoom(by: 1.5, toward: nil, in: fit(square))
        #expect(state.scale == 6)
        #expect(state.offset == CGSize(width: 50, height: -30))
    }

    @Test func zoomingBackToFitCentresTheImage() {
        var state = ImageZoomState()
        state.zoom(by: 3, toward: CGPoint(x: 400, y: 100), in: fit(square))
        #expect(state.offset != .zero)
        state.zoom(by: 0.1, toward: CGPoint(x: 10, y: 10), in: fit(square))
        #expect(state.scale == 1 && state.offset == .zero)
    }

    @Test func zoomBeforeLayoutDoesNothing() {
        var state = ImageZoomState()
        state.zoom(by: 2, toward: .zero, in: ImageZoomState.Fit(images: [square], frame: .zero, padding: 20))
        #expect(state == ImageZoomState())
    }

    // MARK: - Pan

    @Test func aDragPansFromWhereItStartedAndStopsAtTheEdge() {
        var state = ImageZoomState()
        state.zoom(by: 2, toward: nil, in: fit(square))
        state.pan(by: CGSize(width: 40, height: 0), in: fit(square))
        // The drag reports its total translation, not a step.
        state.pan(by: CGSize(width: 60, height: 500), in: fit(square))
        #expect(state.offset == CGSize(width: 60, height: 180))

        state.endPan(in: fit(square))
        state.pan(by: CGSize(width: -10, height: -80), in: fit(square))
        #expect(state.offset == CGSize(width: 50, height: 100))
    }

    @Test func zoomingMidDragKeepsTheDragFromJumping() {
        var state = ImageZoomState()
        state.zoom(by: 2, toward: nil, in: fit(square))
        state.pan(by: CGSize(width: 40, height: 0), in: fit(square))
        // Scrolling during the drag: 2× → 4× about the centre doubles the offset.
        state.zoom(by: 2, toward: CGPoint(x: 220, y: 220), in: fit(square))
        #expect(state.offset == CGSize(width: 80, height: 0))
        // The drag moves 10 more: the image follows from where the zoom left it.
        state.pan(by: CGSize(width: 50, height: 0), in: fit(square))
        #expect(state.offset == CGSize(width: 90, height: 0))
    }

    @Test func resetReturnsToFit() {
        var state = ImageZoomState()
        state.zoom(by: 5, toward: CGPoint(x: 400, y: 400), in: fit(square))
        state.pan(by: CGSize(width: 10, height: 10), in: fit(square))
        state.reset()
        #expect(state == ImageZoomState())
    }
}
