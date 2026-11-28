import Foundation

extension AppSettings {
    /// The per-profile half of the settings: everything that carries a
    /// profile's content (notes, prompts, drafts, templates, boards), written to
    /// `Profiles/<id>/profile.json`. Global preferences stay in ``Stored``.
    ///
    /// Keys match the pre-profiles `settings.json`, so migration decodes that
    /// file straight into this type and ignores the global keys around them.
    struct ProfileStored: Codable {
        /// The profile's saved fields; empty when there is no file yet. A file
        /// that isn't readable JSON at all is moved aside to a uniquely named
        /// `profile.corrupt-….json`, so neither the next save nor a later
        /// corruption can replace it.
        static func load(from url: URL?) -> Self {
            url.flatMap { StoredJSON.load(Self.self, from: $0) } ?? Self()
        }

        var defaultBoard: String?
        var notepadText: String?
        var promptHistory: [PromptHistoryEntry]?
        var customTemplates: [PromptTemplate]?
        var activeTemplateIDs: [UUID]?
        /// Legacy single-ID field, decoded for migration only; never written.
        var activeTemplateID: UUID?
        /// Every family's last-used form. Nil in a profile saved before it.
        var lastForms: LastForms?
        // Legacy keys, decoded once to build `lastForms` and never written again.
        var lastPrompt: String?
        var lastLoras: [LoraEntry]?
        var lastIdeogramCaption: IdeogramCaption?
        var lastIdeogramPlainPrompt: String?
        var lastIdeogramUsePlainPrompt: Bool?
        var lastIdeogramSeed: Int?
        var lastKrea2: Krea2FormState?
        var lastZImage: ZImageFormState?
        var lastQwen21: Qwen21FormState?
        var lastScenarioOutline: String?
        /// Gallery boards the user collapsed (was a global UserDefaults key).
        var galleryCollapsedBoards: [String]?

        /// The template selection, migrating the legacy single-ID form.
        var resolvedActiveTemplateIDs: [UUID] {
            activeTemplateIDs ?? activeTemplateID.map { [$0] } ?? []
        }

        /// Whether this profile was saved before `lastForms`, so the old globals
        /// belong to it. A profile created since has none of the old keys.
        private var hasLegacyForms: Bool {
            lastPrompt != nil || lastLoras != nil || lastIdeogramCaption != nil || lastIdeogramPlainPrompt != nil
                || lastIdeogramUsePlainPrompt != nil || lastIdeogramSeed != nil
                || lastKrea2 != nil || lastZImage != nil || lastQwen21 != nil
        }

        init() {}

        init(snapshotOf settings: AppSettings) {
            defaultBoard = settings.defaultBoard
            notepadText = settings.notepadText
            promptHistory = settings.promptHistory
            customTemplates = settings.customTemplates
            activeTemplateIDs = settings.activeTemplateIDs
            lastForms = settings.lastForms
            lastScenarioOutline = settings.lastScenarioOutline
            galleryCollapsedBoards = settings.galleryCollapsedBoards
        }

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
            lastForms = try? c.decode(LastForms.self, forKey: .lastForms)
            lastPrompt = try? c.decode(String.self, forKey: .lastPrompt)
            lastLoras = try? c.decode([LoraEntry].self, forKey: .lastLoras)
            lastIdeogramCaption = (try? c.decode(LenientIdeogramCaption.self, forKey: .lastIdeogramCaption))?.caption
            lastIdeogramPlainPrompt = try? c.decode(String.self, forKey: .lastIdeogramPlainPrompt)
            lastIdeogramUsePlainPrompt = try? c.decode(Bool.self, forKey: .lastIdeogramUsePlainPrompt)
            lastIdeogramSeed = try? c.decode(Int.self, forKey: .lastIdeogramSeed)
            lastKrea2 = try? c.decode(Krea2FormState.self, forKey: .lastKrea2)
            lastZImage = try? c.decode(ZImageFormState.self, forKey: .lastZImage)
            lastQwen21 = try? c.decode(Qwen21FormState.self, forKey: .lastQwen21)
            lastScenarioOutline = try? c.decode(String.self, forKey: .lastScenarioOutline)
            galleryCollapsedBoards = try? c.decode([String].self, forKey: .galleryCollapsedBoards)
        }

        /// The profile's forms: `lastForms`, or for a profile saved before it, the
        /// old keys and `globals`, the values settings.json held then.
        func resolvedLastForms(globals: LegacyGlobalForms) -> LastForms {
            lastForms ?? LastForms(legacyProfile: self, globals: hasLegacyForms ? globals : LegacyGlobalForms())
        }
    }

    /// Replaces every per-profile field. Called only from
    /// ``activateProfile(contentURL:libraryPath:)``, which suppresses the saves.
    func apply(_ stored: ProfileStored) {
        defaultBoard = stored.defaultBoard ?? ""
        notepadText = stored.notepadText ?? ""
        promptHistory = stored.promptHistory ?? []
        customTemplates = stored.customTemplates ?? []
        activeTemplateIDs = stored.resolvedActiveTemplateIDs
        lastForms = stored.resolvedLastForms(globals: legacyGlobalForms)
        lastScenarioOutline = stored.lastScenarioOutline ?? ""
        galleryCollapsedBoards = stored.galleryCollapsedBoards ?? []
    }
}
