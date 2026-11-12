import Foundation

/// Pure search and grouping logic for the generation gallery, extracted from
/// `GenerationGalleryView` so it can be unit-tested off the view.
nonisolated enum GallerySearch {
    /// Lower-cased blob of the sidecar fields the search box matches against:
    /// prompt text, seed, model, and LoRA names.
    static func haystack(for item: GalleryItem) -> String {
        var parts: [String] = [item.filename]
        if let meta = item.metadata {
            parts.append(meta.prompt)
            parts.append(meta.negativePrompt)
            parts.append(String(meta.seed))
            parts.append("\(meta.model)")
            parts.append(contentsOf: meta.loras.map(\.displayName))
        }
        if let meta = item.ideogram4Metadata {
            parts.append(meta.plainPrompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        if let meta = item.krea2Metadata {
            parts.append(meta.prompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        if let meta = item.zimageMetadata {
            parts.append(meta.prompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        return parts.joined(separator: " ").lowercased()
    }

    /// Store items limited to the selected model family — the source of truth
    /// for everything the gallery displays and navigates (sections, board
    /// counts, adjacency, range selection). Mutating operations still address
    /// the full store by id, so they are unaffected by this filter.
    static func filter(
        _ items: [GalleryItem],
        family: ModelFamily,
        query: String,
        flag: FlagFilter,
        minRating: Int
    ) -> [GalleryItem] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            guard item.modelFamily == family else {
                return false
            }
            switch flag {
            case .all:
                break
            case .picks:
                if item.flag != .pick {
                    return false
                }
            case .rejects:
                if item.flag != .reject {
                    return false
                }
            case .unflagged:
                if item.flag != nil {
                    return false
                }
            }
            if item.rating < minRating {
                return false
            }
            if !query.isEmpty, !Self.haystack(for: item).contains(query) {
                return false
            }
            return true
        }
    }

    /// Board order for an already-filtered item set, so callers that have one
    /// in hand don't trigger another full filtered pass.
    static func orderedBoards(for items: [GalleryItem], boards: [String]) -> [String] {
        let hasDefault = items.contains { $0.board == "Default" }
        let others = boards.filter { $0 != "Default" }.sorted()
        return (hasDefault ? ["Default"] : []) + others
    }

    // Named folders are shown even when empty (their header acts as the drop
    // target and delete affordance); the implicit "Default" board only appears
    // when it actually holds loose images at the output root.
    //
    // `Dictionary(grouping:)` keeps each group in encounter order, matching
    // the previous per-board `filter`.
    static func sections(_ items: [GalleryItem], boards: [String], collapsed: Set<String>) -> [GallerySection] {
        let byBoard = Dictionary(grouping: items, by: \.board)
        return Self.orderedBoards(for: items, boards: boards).map { board in
            GallerySection(
                board: board,
                items: byBoard[board] ?? [],
                isExpanded: !collapsed.contains(board)
            )
        }
    }
}
