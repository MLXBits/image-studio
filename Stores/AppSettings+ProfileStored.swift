import Foundation

extension AppSettings {
    /// The per-profile half of the settings: everything that carries a
    /// profile's content (notes, prompts, drafts, templates, boards), written to
    /// `Profiles/<id>/profile.json`. Global preferences stay in ``Stored``.
    ///
    /// Keys match the pre-profiles `settings.json`, so migration decodes that
    /// file straight into this type and ignores the global keys around them.
    struct ProfileStored: Codable {
        var defaultBoard: String?
        var notepadText: String?
        var promptHistory: [PromptHistoryEntry]?
        var customTemplates: [PromptTemplate]?
        var activeTemplateIDs: [UUID]?
        /// Legacy single-ID field, decoded for migration only; never written.
        var activeTemplateID: UUID?
        var lastPrompt: String?
        var lastLoras: [LoraEntry]?
        var lastIdeogramCaption: IdeogramCaption?
        var lastIdeogramPlainPrompt: String?
        var lastIdeogramUsePlainPrompt: Bool?
        var lastIdeogramSeed: Int?
        var lastKrea2: Krea2FormState?
        var lastZImage: ZImageFormState?
        var lastScenarioOutline: String?
        /// Gallery boards the user collapsed (was a global UserDefaults key).
        var galleryCollapsedBoards: [String]?

        /// The template selection, migrating the legacy single-ID form.
        var resolvedActiveTemplateIDs: [UUID] {
            activeTemplateIDs ?? activeTemplateID.map { [$0] } ?? []
        }

        init() {}

        /// Decodes field by field so one malformed entry (a bad history item, a
        /// draft from a newer build) costs only that field, not the notepad.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultBoard = try? c.decode(String.self, forKey: .defaultBoard)
            notepadText = try? c.decode(String.self, forKey: .notepadText)
            promptHistory = try? c.decode([PromptHistoryEntry].self, forKey: .promptHistory)
            customTemplates = try? c.decode([PromptTemplate].self, forKey: .customTemplates)
            activeTemplateIDs = try? c.decode([UUID].self, forKey: .activeTemplateIDs)
            activeTemplateID = try? c.decode(UUID.self, forKey: .activeTemplateID)
            lastPrompt = try? c.decode(String.self, forKey: .lastPrompt)
            lastLoras = try? c.decode([LoraEntry].self, forKey: .lastLoras)
            lastIdeogramCaption = try? c.decode(IdeogramCaption.self, forKey: .lastIdeogramCaption)
            lastIdeogramPlainPrompt = try? c.decode(String.self, forKey: .lastIdeogramPlainPrompt)
            lastIdeogramUsePlainPrompt = try? c.decode(Bool.self, forKey: .lastIdeogramUsePlainPrompt)
            lastIdeogramSeed = try? c.decode(Int.self, forKey: .lastIdeogramSeed)
            lastKrea2 = try? c.decode(Krea2FormState.self, forKey: .lastKrea2)
            lastZImage = try? c.decode(ZImageFormState.self, forKey: .lastZImage)
            lastScenarioOutline = try? c.decode(String.self, forKey: .lastScenarioOutline)
            galleryCollapsedBoards = try? c.decode([String].self, forKey: .galleryCollapsedBoards)
        }
    }
}
