import Foundation

/// One remembered prompt. Recorded when a job is queued (Flux and Krea 2),
/// deduplicated on exact trimmed text; re-use bumps ``lastUsedAt`` and
/// ``useCount`` instead of inserting a duplicate. Pinned entries survive the
/// history cap.
struct PromptHistoryEntry: Codable, Equatable, Identifiable {
    var id: UUID = .init()
    var prompt: String
    var lastUsedAt: Date
    var useCount: Int = 1
    var pinned: Bool = false
}
