@testable import MLXBits_Image_Studio
import SwiftUI
import Testing

struct BBoxGeometryTests {
    private let unitCanvas = CGSize(width: 1000, height: 1000)

    @Test func normRectMapsFullBoxToCanvas() {
        let rect = BBoxGeometry.normRect([0, 0, 1000, 1000], in: unitCanvas)
        #expect(rect == CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    @Test func normRectInvalidBoxIsZero() {
        #expect(BBoxGeometry.normRect([0, 0, 1000], in: unitCanvas) == .zero)
    }

    @Test func toNormScalesByCanvas() {
        let pt = BBoxGeometry.toNorm(CGPoint(x: 500, y: 250), in: unitCanvas)
        #expect(pt == CGPoint(x: 500, y: 250))
    }

    @Test func normalizeBoxOrdersAndClamps() {
        // Endpoints given out of order (bottom-right first) must come back min/max ordered.
        let box = BBoxGeometry.normalizeBox(
            from: CGPoint(x: 400, y: 300), to: CGPoint(x: 100, y: 100), in: unitCanvas
        )
        #expect(box == [100, 100, 300, 400])
    }

    @Test func containsRespectsBounds() {
        let bbox = [100, 100, 300, 400]
        #expect(BBoxGeometry.contains(CGPoint(x: 150, y: 150), bbox: bbox))
        #expect(!BBoxGeometry.contains(CGPoint(x: 50, y: 50), bbox: bbox))
    }

    @Test func movedKeepsSize() {
        #expect(BBoxGeometry.moved([100, 100, 200, 200], delta: CGSize(width: 50, height: 50))
            == [150, 150, 250, 250])
    }

    @Test func movedClampsAtBounds() {
        // Already near the edge; moving further must not exceed 1000 or change size.
        #expect(BBoxGeometry.moved([900, 900, 1000, 1000], delta: CGSize(width: 100, height: 100))
            == [900, 900, 1000, 1000])
    }

    @Test func resizedBottomRightGrows() {
        #expect(BBoxGeometry.resized(
            [100, 100, 200, 200], handle: .bottomRight, delta: CGSize(width: 50, height: 50), minBox: 10
        ) == [100, 100, 250, 250])
    }

    @Test func resizedEnforcesMinimumBox() {
        // Dragging the bottom-right far past the top-left collapses to the minimum size.
        let box = BBoxGeometry.resized(
            [100, 100, 200, 200], handle: .bottomRight, delta: CGSize(width: -300, height: -300), minBox: 10
        )
        #expect(box == [100, 100, 110, 110])
    }

    @Test func fitCanvasHonorsAspectRatio() {
        // Wide target constrained by width.
        #expect(BBoxGeometry.fitCanvas(width: 2000, height: 1000, in: CGSize(width: 500, height: 500))
            == CGSize(width: 500, height: 250))
        // Square target constrained by height.
        #expect(BBoxGeometry.fitCanvas(width: 1000, height: 1000, in: CGSize(width: 500, height: 400))
            == CGSize(width: 400, height: 400))
    }
}
