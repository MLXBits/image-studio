import Foundation

/// Pure search and grouping logic for the generation gallery, extracted from
/// `GenerationGalleryView` so it can be unit-tested off the view.
nonisolated enum GallerySearch {
    /// The parts a haystack is built from, given by family. Kept separate from
    /// the item so a scan can build the blob once at construction time.
    static func haystack(
        filename: String,
        flux: GenerationMetadata?,
        ideogram4: Ideogram4Metadata?,
        krea2: Krea2Metadata?,
        zimage: ZImageMetadata?
    ) -> String {
        var parts: [String] = [filename]
        if let meta = flux {
            parts.append(meta.prompt)
            parts.append(meta.negativePrompt)
            parts.append(String(meta.seed))
            parts.append("\(meta.model)")
            parts.append(contentsOf: meta.loras.map(\.displayName))
        }
        if let meta = ideogram4 {
            parts.append(meta.plainPrompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        if let meta = krea2 {
            parts.append(meta.prompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        if let meta = zimage {
            parts.append(meta.prompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        return parts.joined(separator: " ").lowercased()
    }

    /// Lower-cased blob of the sidecar fields the search box matches against:
    /// prompt text, seed, model, and LoRA names.
    static func haystack(for item: GalleryItem) -> String {
        haystack(
            filename: item.filename,
            flux: item.metadata,
            ideogram4: item.ideogram4Metadata,
            krea2: item.krea2Metadata,
            zimage: item.zimageMetadata
        )
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
            if !query.isEmpty, !item.searchHaystack.contains(query) {
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
