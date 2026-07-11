import Foundation

/// Content rating for library LoRAs and stacks. Metadata only for now — future
/// workspace/profile filtering will key on it (see the parked SFW/NSFW spike).
enum LoraRating: String, Codable, CaseIterable {
    case unrated
    case sfw
    case nsfw

    var label: String {
        switch self {
        case .unrated: "Unrated"
        case .sfw: "SFW"
        case .nsfw: "NSFW"
        }
    }
}

/// A curated, reusable LoRA the user has cataloged: identity (`path`) plus the
/// metadata that's easy to forget — most importantly the trigger words that get
/// auto-inserted into the prompt when the LoRA is activated.
///
/// Distinct from ``LoraEntry`` (a per-job instance with a live strength/enabled
/// state). Activating a library entry mints a fresh ``LoraEntry`` via ``toEntry()``.
struct LibraryLora: Identifiable, Codable, Equatable, Hashable {
    enum CodingKeys: String, CodingKey {
        case id, name, path, modelFamily, defaultStrength, triggerWords, tags, rating, thumbnailPath, notes,
             isDefault
    }

    var id = UUID()
    var name: String = ""
    var path: String = ""
    var modelFamily: ModelFamily = .flux
    var defaultStrength: Double = 1.0
    var triggerWords: String = ""
    var tags: [String] = []
    var rating: LoraRating = .unrated
    /// Reserved for a future preview thumbnail; no UI in v1.
    var thumbnailPath: String?
    var notes: String = ""
    /// Auto-applied to every new generation for this entry's model family.
    var isDefault: Bool = false

    /// Display name, falling back to the filename/repo tail of `path`.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return path.isEmpty ? "Unnamed LoRA" : path
    }

    var isValid: Bool {
        !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A per-job entry seeded from this library LoRA's identity and default strength.
    /// Reuses the library `id` so repeated derivations (e.g. the default-LoRA lists
    /// computed from the library each render) compare equal; job lists dedupe by
    /// `path`, so the shared id never collides within one list.
    func toEntry() -> LoraEntry {
        LoraEntry(id: id, path: path, strength: defaultStrength, notes: notes, modelFamily: modelFamily)
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        path: String = "",
        modelFamily: ModelFamily = .flux,
        defaultStrength: Double = 1.0,
        triggerWords: String = "",
        tags: [String] = [],
        rating: LoraRating = .unrated,
        thumbnailPath: String? = nil,
        notes: String = "",
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.modelFamily = modelFamily
        self.defaultStrength = defaultStrength
        self.triggerWords = triggerWords
        self.tags = tags
        self.rating = rating
        self.thumbnailPath = thumbnailPath
        self.notes = notes
        self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        modelFamily = try c.decodeIfPresent(ModelFamily.self, forKey: .modelFamily) ?? .flux
        defaultStrength = try c.decodeIfPresent(Double.self, forKey: .defaultStrength) ?? 1.0
        triggerWords = try c.decodeIfPresent(String.self, forKey: .triggerWords) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        rating = try c.decodeIfPresent(LoraRating.self, forKey: .rating) ?? .unrated
        thumbnailPath = try c.decodeIfPresent(String.self, forKey: .thumbnailPath)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

/// A named, reusable combination of LoRAs at set strengths — applied to a job
/// in one click. Stores self-contained ``LoraEntry`` values (not references to
/// the library) so editing a library entry never silently mutates a saved
/// stack.
struct LoraStack: Identifiable, Codable, Equatable, Hashable {
    enum CodingKeys: String, CodingKey {
        case id, name, modelFamily, loras, tags, rating
    }

    var id = UUID()
    var name: String = ""
    var modelFamily: ModelFamily = .flux
    var loras: [LoraEntry] = []
    var tags: [String] = []
    var rating: LoraRating = .unrated

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled Stack" : trimmed
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        modelFamily: ModelFamily = .flux,
        loras: [LoraEntry] = [],
        tags: [String] = [],
        rating: LoraRating = .unrated
    ) {
        self.id = id
        self.name = name
        self.modelFamily = modelFamily
        self.loras = loras
        self.tags = tags
        self.rating = rating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        modelFamily = try c.decodeIfPresent(ModelFamily.self, forKey: .modelFamily) ?? .flux
        loras = try c.decodeIfPresent([LoraEntry].self, forKey: .loras) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        rating = try c.decodeIfPresent(LoraRating.self, forKey: .rating) ?? .unrated
    }
}
