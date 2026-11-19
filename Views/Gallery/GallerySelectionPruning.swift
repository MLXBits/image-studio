import Foundation

/// Gallery selection state after some items were deleted out from under it.
struct GallerySelectionState: Equatable {
    var selection: Set<UUID>
    var anchorId: UUID?
    var selectedId: UUID?

    /// Drops every deleted id from the selection and clears the previewed item if
    /// it was deleted. A deleted anchor moves to a surviving selected item, as a
    /// Cmd-click deselect does, so the cull keys still have a target.
    func removing(_ deletedIds: Set<UUID>) -> Self {
        let remaining = selection.subtracting(deletedIds)
        return Self(
            selection: remaining,
            anchorId: anchorId.flatMap { deletedIds.contains($0) ? remaining.first : $0 },
            selectedId: selectedId.flatMap { deletedIds.contains($0) ? nil : $0 }
        )
    }

    /// The state after the previewed item is cleared. An external clear (the
    /// pane's ✕, Escape, a restore to the active job) drops the whole selection
    /// so no highlighted cell lingers. A clear that a deletion caused keeps the
    /// surviving selection, because `removing(_:)` has already pruned it.
    func previewCleared(byDeletion: Bool) -> Self {
        byDeletion
            ? Self(selection: selection, anchorId: anchorId, selectedId: nil)
            : Self(selection: [], anchorId: nil, selectedId: nil)
    }
}

extension GallerySelectionState {
    /// The selected id closest to `removed` in grid `order`, checking the next
    /// cell before the previous one at each distance. For a Cmd-click that
    /// deselects the anchor: the anchor moves to a neighbour, not to whichever id
    /// the set happens to list first. Falls back to any selected id when `removed`
    /// is not in `order`, or no selected id is.
    static func nearestSelected(to removed: UUID, in order: [UUID], selection: Set<UUID>) -> UUID? {
        guard let start = order.firstIndex(of: removed) else { return selection.first }
        for distance in 1 ..< max(order.count, 1) {
            for idx in [start + distance, start - distance] where order.indices.contains(idx) {
                if selection.contains(order[idx]) {
                    return order[idx]
                }
            }
        }
        return selection.first
    }
}
