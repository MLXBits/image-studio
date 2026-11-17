import Foundation

/// Gallery selection state after some items were deleted out from under it.
struct GallerySelectionState: Equatable {
    var selection: Set<UUID>
    var anchorId: UUID?
    var selectedId: UUID?

    /// Drops every deleted id from the selection, and clears the anchor and the
    /// previewed item if either was deleted.
    func removing(_ deletedIds: Set<UUID>) -> Self {
        Self(
            selection: selection.subtracting(deletedIds),
            anchorId: anchorId.flatMap { deletedIds.contains($0) ? nil : $0 },
            selectedId: selectedId.flatMap { deletedIds.contains($0) ? nil : $0 }
        )
    }
}
