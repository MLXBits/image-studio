/// Which gallery images the full-size viewer pages through and Compare cycles:
/// the images on screen beside the current one, so the arrows never leave them.
enum GalleryCull {
    /// The images the gallery shows with `item`: its board, in the active family.
    static func siblings(of item: GalleryItem, in items: [GalleryItem], family: ModelFamily) -> [GalleryItem] {
        items.filter { $0.board == item.board && $0.modelFamily == family }
    }

    /// The sibling `delta` places from `item`, kept at the ends; nil when that is
    /// `item` itself, or `item` is not among the shown images.
    static func step(from item: GalleryItem, by delta: Int, in items: [GalleryItem], family: ModelFamily) -> GalleryItem? {
        let shown = siblings(of: item, in: items, family: family)
        guard let index = shown.firstIndex(where: { $0.id == item.id }) else { return nil }
        let next = max(0, min(shown.count - 1, index + delta))
        return next == index ? nil : shown[next]
    }

    /// Whether the viewer's previous and next arrows have an image to go to.
    static func edges(of item: GalleryItem, in items: [GalleryItem], family: ModelFamily) -> (hasPrev: Bool, hasNext: Bool) {
        let shown = siblings(of: item, in: items, family: family)
        guard let index = shown.firstIndex(where: { $0.id == item.id }) else { return (false, false) }
        return (index > 0, index < shown.count - 1)
    }

    /// The flag after a flag key: pressing the image's own flag again clears it.
    static func toggled(_ current: PickFlag?, pressing flag: PickFlag?) -> PickFlag? {
        current == flag ? nil : flag
    }
}

extension ComparePair {
    /// The select and the candidate change places.
    var swapped: ComparePair {
        ComparePair(selectId: candidateId, candidateId: selectId)
    }

    /// The pair with the candidate moved `delta` places through `siblings`,
    /// wrapping, and passing over the select. Nil when nothing else is there.
    func cyclingCandidate(by delta: Int, through siblings: [GalleryItem]) -> ComparePair? {
        let others = siblings.filter { $0.id != selectId }
        guard !others.isEmpty else { return nil }
        let current = others.firstIndex { $0.id == candidateId } ?? 0
        let next = ((current + delta) % others.count + others.count) % others.count
        return ComparePair(selectId: selectId, candidateId: others[next].id)
    }
}
