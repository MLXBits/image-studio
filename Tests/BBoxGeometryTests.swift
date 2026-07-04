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

    // MARK: - Guides

    @Test func gridLinesAtThirdsAndCenter() {
        let g = BBoxGeometry.gridLines(in: CGSize(width: 900, height: 600))
        #expect(g.verticalThirds == [300, 600])
        #expect(g.horizontalThirds == [200, 400])
        #expect(g.centerX == 450)
        #expect(g.centerY == 300)
    }

    // MARK: - Frame zones

    @Test func frameZoneNamesCorners() {
        #expect(BBoxGeometry.frameZone(forNorm: CGPoint(x: 100, y: 900)) == "bottom left of frame")
        #expect(BBoxGeometry.frameZone(forNorm: CGPoint(x: 500, y: 100)) == "top center of frame")
        #expect(BBoxGeometry.frameZone(forNorm: CGPoint(x: 900, y: 500)) == "center right of frame")
        #expect(BBoxGeometry.frameZone(forNorm: CGPoint(x: 500, y: 500)) == "center of frame")
    }
}

// MARK: - Photo dimensions (angle / shot size / lens / depth of field)

struct PhotoDimensionTests {
    @Test func horizonMapsToPOV() {
        #expect(CameraPOV.forHorizon(150) == .high)
        #expect(CameraPOV.forHorizon(500) == .eye)
        #expect(CameraPOV.forHorizon(850) == .low)
    }

    @Test func writeReplacesSameDimensionKeepingOthers() {
        // The existing angle token is replaced; free text and the DoF token survive.
        let photo = "low-angle shot looking up, 35mm, shallow depth of field"
        #expect(CameraPOV.high.write(to: photo)
            == "35mm, shallow depth of field, high-angle shot looking down")
    }

    @Test func writeToEmptyGivesClauseOnly() {
        #expect(CameraPOV.low.write(to: nil) == "low-angle shot looking up")
        #expect(ShotSize.medium.write(to: "") == "medium shot")
    }

    @Test func dimensionsAreIndependent() {
        var photo: String?
        photo = ShotSize.closeUp.write(to: photo)
        photo = Lens.telephoto.write(to: photo)
        photo = DepthOfField.shallow.write(to: photo)
        #expect(photo == "close-up shot, telephoto lens, shallow depth of field (f/2.8)")
        // Replacing the lens leaves the other two intact.
        photo = Lens.macro.write(to: photo)
        #expect(photo == "close-up shot, shallow depth of field (f/2.8), macro lens")
    }

    @Test func currentDetectsPresentToken() {
        let photo = "wide shot, 50mm lens, high-angle shot looking down"
        #expect(ShotSize.current(in: photo) == .wide)
        #expect(Lens.current(in: photo) == .normal)
        #expect(CameraPOV.current(in: photo) == .high)
        #expect(DepthOfField.current(in: photo) == nil)
    }

    @Test func clearRemovesOnlyThatDimension() {
        #expect(Lens.clear(in: "wide shot, 50mm lens") == "wide shot")
    }

    @Test func freeTextPreserved() {
        #expect(ShotSize.medium.write(to: "golden hour, bokeh") == "golden hour, bokeh, medium shot")
    }
}

// MARK: - Orientation clause

struct OrientationClauseTests {
    @Test func applyAppendsToDescription() {
        let result = OrientationClause.apply(
            partA: "head", zoneA: "bottom left of frame",
            partB: "feet", zoneB: "top center of frame",
            to: "a reclining figure"
        )
        #expect(result == "a reclining figure, head at bottom left of frame, feet at top center of frame")
    }

    @Test func applyReplacesPriorClauseNoDuplicate() {
        let first = OrientationClause.apply(
            partA: "head", zoneA: "top left of frame",
            partB: "feet", zoneB: "bottom right of frame",
            to: "a figure"
        )
        let second = OrientationClause.apply(
            partA: "head", zoneA: "bottom left of frame",
            partB: "feet", zoneB: "top center of frame",
            to: first
        )
        #expect(second == "a figure, head at bottom left of frame, feet at top center of frame")
    }

    @Test func applyToEmptyDescGivesClauseOnly() {
        let result = OrientationClause.apply(
            partA: "head", zoneA: "center of frame",
            partB: "feet", zoneB: "bottom center of frame",
            to: ""
        )
        #expect(result == "head at center of frame, feet at bottom center of frame")
    }
}

// MARK: - Composition templates

struct BBoxTemplateTests {
    @Test func libraryBoxesAreValid() {
        for template in BBoxTemplate.library {
            #expect(!template.elements.isEmpty)
            for element in template.elements {
                #expect(element.isBBoxValid)
                #expect(element.type == .obj)
            }
        }
    }
}
