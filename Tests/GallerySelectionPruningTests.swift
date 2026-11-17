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

    /// Select A and B with B previewed, and only B rejected. Deleting B clears
    /// the preview, and the preview observer must keep A selected.
    @Test func deletingThePreviewKeepsSurvivingSelectionThroughObserver() {
        let a = UUID(), b = UUID()
        let pruned = GallerySelectionState(selection: [a, b], anchorId: b, selectedId: b).removing([b])
        #expect(pruned.selectedId == nil)
        let afterObserver = pruned.previewCleared(byDeletion: true)
        #expect(afterObserver.selection == [a])
        #expect(afterObserver.anchorId == nil)
    }

    @Test func externalPreviewClearDropsWholeSelection() {
        let a = UUID(), b = UUID()
        let state = GallerySelectionState(selection: [a, b], anchorId: a, selectedId: nil)
        let result = state.previewCleared(byDeletion: false)
        #expect(result.selection.isEmpty)
        #expect(result.anchorId == nil)
    }

    @Test func hitTestFlipsWindowYIntoGlobalSpace() {
        let p = EventLocationHitTest.globalPoint(windowPoint: CGPoint(x: 10, y: 30), contentHeight: 100)
        #expect(p == CGPoint(x: 10, y: 70))
    }
}
