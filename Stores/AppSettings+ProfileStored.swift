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
            guard let url, let data = try? Data(contentsOf: url) else { return Self() }
            if let stored = try? JSONDecoder().decode(Self.self, from: data) {
                return stored
            }
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("profile.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return Self()
        }

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

        init(snapshotOf settings: AppSettings) {
            defaultBoard = settings.defaultBoard
            notepadText = settings.notepadText
            promptHistory = settings.promptHistory
            customTemplates = settings.customTemplates
            activeTemplateIDs = settings.activeTemplateIDs
            lastPrompt = settings.lastPrompt
            lastLoras = settings.lastLoras
            lastIdeogramCaption = settings.lastIdeogramCaption
            lastIdeogramPlainPrompt = settings.lastIdeogramPlainPrompt
            lastIdeogramUsePlainPrompt = settings.lastIdeogramUsePlainPrompt
            lastIdeogramSeed = settings.lastIdeogramSeed
            lastKrea2 = settings.lastKrea2
            lastZImage = settings.lastZImage
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

    /// Replaces every per-profile field. Called only from
    /// ``activateProfile(contentURL:libraryPath:)``, which suppresses the saves.
    func apply(_ stored: ProfileStored) {
        defaultBoard = stored.defaultBoard ?? ""
        notepadText = stored.notepadText ?? ""
        promptHistory = stored.promptHistory ?? []
        customTemplates = stored.customTemplates ?? []
        activeTemplateIDs = stored.resolvedActiveTemplateIDs
        lastPrompt = stored.lastPrompt ?? ""
        lastLoras = stored.lastLoras ?? []
        lastIdeogramCaption = stored.lastIdeogramCaption
        lastIdeogramPlainPrompt = stored.lastIdeogramPlainPrompt
        lastIdeogramUsePlainPrompt = stored.lastIdeogramUsePlainPrompt
        lastIdeogramSeed = stored.lastIdeogramSeed
        lastKrea2 = stored.lastKrea2
        lastZImage = stored.lastZImage
        lastScenarioOutline = stored.lastScenarioOutline ?? ""
        galleryCollapsedBoards = stored.galleryCollapsedBoards ?? []
    }
}
