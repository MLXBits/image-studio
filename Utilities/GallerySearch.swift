import Foundation

/// Pure search and grouping logic for the generation gallery, extracted from
/// `GenerationGalleryView` so it can be unit-tested off the view.
nonisolated enum GallerySearch {
    /// The lowercased blob the search box matches: the file name, then the
    /// sidecar's prompt text, seed, model and LoRA names. Kept separate from the
    /// item so a scan builds it once, at construction.
    static func haystack(filename: String, sidecar: AnySidecar?) -> String {
        var parts: [String] = [filename]
        func appendBasics(_ prompt: String, _ seed: Int, _ loras: [LoraEntry]?) {
            parts.append(prompt)
            parts.append(String(seed))
            parts.append(contentsOf: (loras ?? []).map(\.displayName))
        }
        switch sidecar {
        case let .flux(meta):
            parts.append(meta.prompt)
            parts.append(meta.negativePrompt)
            parts.append(String(meta.seed))
            parts.append("\(meta.model)")
            parts.append(contentsOf: meta.loras.map(\.displayName))
        case let .ideogram4(meta): appendBasics(meta.plainPrompt, meta.seed, meta.loras)
        case let .krea2(meta): appendBasics(meta.prompt, meta.seed, meta.loras)
        case let .zimage(meta): appendBasics(meta.prompt, meta.seed, meta.loras)
        case let .qwen21(meta): appendBasics(meta.prompt, meta.seed, meta.loras)
        case .seedVR2, nil: break
        }
        return parts.joined(separator: " ").lowercased()
    }

    /// ``haystack(filename:sidecar:)`` for `item`.
    static func haystack(for item: GalleryItem) -> String {
        haystack(filename: item.filename, sidecar: item.sidecar)
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
