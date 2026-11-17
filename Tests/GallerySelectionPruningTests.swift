import Foundation
@testable import MLXBits_Image_Studio
import Testing

struct GallerySelectionPruningTests {
    @Test func subtractsAllDeletedIdsEvenWhenAnchorSurvives() {
        let a = UUID(), b = UUID(), c = UUID()
        let state = GallerySelectionState(selection: [a, b, c], anchorId: a, selectedId: a)
        let result = state.removing([b, c])
        #expect(result.selection == [a])
        #expect(result.anchorId == a)
        #expect(result.selectedId == a)
    }

    @Test func clearsAnchorAndSelectedWhenDeleted() {
        let a = UUID(), b = UUID()
        let state = GallerySelectionState(selection: [a, b], anchorId: a, selectedId: a)
        let result = state.removing([a, b])
        #expect(result.selection.isEmpty)
        #expect(result.anchorId == nil)
        #expect(result.selectedId == nil)
    }

    @Test func hitTestFlipsWindowYIntoGlobalSpace() {
        let p = EventLocationHitTest.globalPoint(windowPoint: CGPoint(x: 10, y: 30), contentHeight: 100)
        #expect(p == CGPoint(x: 10, y: 70))
    }
}
