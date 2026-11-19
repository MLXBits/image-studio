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
    /// the preview, and the preview observer must keep A selected. The anchor
    /// moves to A so the cull keys still act on it.
    @Test func deletingThePreviewKeepsSurvivingSelectionThroughObserver() {
        let a = UUID(), b = UUID()
        let pruned = GallerySelectionState(selection: [a, b], anchorId: b, selectedId: b).removing([b])
        #expect(pruned.selectedId == nil)
        let afterObserver = pruned.previewCleared(byDeletion: true)
        #expect(afterObserver.selection == [a])
        #expect(afterObserver.anchorId == a)
    }

    @Test func deletedAnchorMovesToASurvivingSelectedItem() {
        let a = UUID(), b = UUID(), c = UUID()
        let result = GallerySelectionState(selection: [a, b, c], anchorId: c, selectedId: c).removing([c])
        #expect(result.anchorId.map { [a, b].contains($0) } == true)
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

struct GalleryAnchorAfterDeselectTests {
    private let ids = (0 ..< 6).map { _ in UUID() }

    @Test func movesToTheNextSelectedCell() {
        // Selected: 1, 3, 4. Cmd-click deselects 3 → 4 is one cell forward.
        let next = GallerySelectionState.nearestSelected(to: ids[3], in: ids, selection: [ids[1], ids[4]])
        #expect(next == ids[4])
    }

    @Test func prefersTheCloserCellBehind() {
        // Selected: 2, 5. Deselecting 3 → 2 is one back, 5 is two forward.
        let next = GallerySelectionState.nearestSelected(to: ids[3], in: ids, selection: [ids[2], ids[5]])
        #expect(next == ids[2])
    }

    @Test func emptySelectionHasNoAnchor() {
        #expect(GallerySelectionState.nearestSelected(to: ids[0], in: ids, selection: []) == nil)
    }

    @Test func idOutsideTheGridFallsBackToAnySelected() {
        let next = GallerySelectionState.nearestSelected(to: UUID(), in: ids, selection: [ids[5]])
        #expect(next == ids[5])
    }
}
