// swiftlint:disable file_length
import Foundation

// MARK: - Per-model defaults

struct ModelDefaults: Codable, Equatable {
    struct Resolved {
        let steps: Int
        let guidance: Double
        let quantize: Int
        let lowRam: Bool
        let negativePrompt: String
        let width: Int
        let height: Int
        let modelRepoOverride: String?
    }

    var steps: Int?
    var guidance: Double?
    var quantize: Int?
    var lowRam: Bool?
    var negativePrompt: String?
    var width: Int?
    var height: Int?
    var modelRepoOverride: String? // HF repo ID or local path; replaces the mflux default when set
}

extension ModelDefaults {
    /// Resolves all values, using global fallbacks for width/height.
    func resolved(for model: FluxModelVariant) -> Resolved {
        Resolved(
            steps: steps ?? model.defaultSteps,
            guidance: model.isDistilled ? 1.0 : (guidance ?? model.defaultGuidance),
            quantize: quantize ?? model.recommendedQuantize,
            lowRam: lowRam ?? false,
            negativePrompt: model.supportsNegativePrompt ? (negativePrompt ?? "") : "",
            width: width ?? 1024,
            height: height ?? 1024,
            modelRepoOverride: modelRepoOverride.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - AppSettings

/// Persistent user preferences for the application.
///
/// Every settable property calls ``save()`` in its `didSet` observer, so the JSON file on
/// disk is always up to date after a mutation. The HuggingFace token is the only value stored
/// in the system Keychain rather than the JSON file.
///
/// `AppSettings` is injected into the SwiftUI environment at the app root and accessed
/// via `@Environment(AppSettings.self)` throughout the view hierarchy.
@Observable
class AppSettings {
    // MARK: - Stored

    private struct Stored: Codable {
        var mfluxBinaryDir: String?; var outputDir: String?
        var defaultModel: FluxModelVariant?
        var defaultBoard: String?; var defaultWidth: Int?; var defaultHeight: Int?
        var defaultLoras: [LoraEntry]?
        var mlxCacheLimitGB: Double?; var hfHome: String?; var mfluxCacheDir: String?
        var hfOffline: Bool?; var logFontSize: Double?; var lastPrompt: String?
        var lastWidth: Int?; var lastHeight: Int?; var lastLoras: [LoraEntry]?
        var lastModel: FluxModelVariant?; var lastQuantize: Int?
        var modelDefaults: [String: ModelDefaults]?
        var customTemplates: [PromptTemplate]?
        /// Legacy single-ID field kept for migration only; new writes use activeTemplateIDs.
        var activeTemplateID: UUID?
        var activeTemplateIDs: [UUID]?
        var batchShortcutPreset: Int?
        var batchShortcutCustomCount: Int?
        // Ideogram 4
        var gemmaModelPath: String?
        var ideogram4ModelRepoOverride: String?
        var lastIdeogramPreset: Ideogram4Preset?
        var lastIdeogramWidth: Int?
        var lastIdeogramHeight: Int?
        var lastIdeogramQuantize: Int?
        var lastIdeogramCaption: IdeogramCaption?
        var lastIdeogramPlainPrompt: String?
        var lastIdeogramUsePlainPrompt: Bool?
        var lastIdeogramSeed: Int?
        var ideogram4LowRam: Bool?
        var ideogram4StrictValidation: Bool?
        var ideogram4CfgEnd: Double?
        /// Krea 2 last-used form (remembered across launches)
        var lastKrea2: Krea2FormState?
        /// SeedVR2 upscale defaults (remembered across launches)
        var seedVR2Use7B: Bool?
        var seedVR2Quantize: Int?
        var seedVR2Scale: Int?
        var seedVR2Softness: Double?
        /// Notepad
        var notepadText: String?
        /// Prompt history (recorded on job enqueue)
        var promptHistory: [PromptHistoryEntry]?
        /// Warm-model driver
        var keepModelWarm: Bool?
        var warmIdleMinutes: Int?
        var warmTextEncoderPolicy: WarmTextEncoderPolicy?
        /// Scenario generator (raw values so future category changes degrade
        /// gracefully instead of failing the whole settings decode)
        var lastScenarioOutline: String?
        var scenarioCategories: [String]?
        var scenarioWildcardMode: Bool?
        /// Prompt-writing LLM backend (local Gemma vs OpenAI-compatible endpoint).
        /// The API key is Keychain-backed and never stored here.
        var llmBackend: LLMBackendKind?
        var openAIBaseURL: String?
        var openAIModel: String?
        var openAITemperature: Double?
        var openAITopP: Double?
        var openAITopK: Int?

        init() {}
        init(
            mfluxBinaryDir: String, outputDir: String, defaultModel: FluxModelVariant,
            defaultBoard: String, defaultWidth: Int, defaultHeight: Int,
            defaultLoras: [LoraEntry],
            mlxCacheLimitGB: Double, hfHome: String, mfluxCacheDir: String,
            hfOffline: Bool, logFontSize: Double, lastPrompt: String,
            lastWidth: Int, lastHeight: Int, lastLoras: [LoraEntry],
            modelDefaults: [String: ModelDefaults],
            lastModel: FluxModelVariant, lastQuantize: Int,
            customTemplates: [PromptTemplate], activeTemplateIDs: [UUID],
            batchShortcutPreset: Int, batchShortcutCustomCount: Int,
            gemmaModelPath: String, ideogram4ModelRepoOverride: String?,
            lastIdeogramPreset: Ideogram4Preset?, lastIdeogramWidth: Int?,
            lastIdeogramHeight: Int?, lastIdeogramQuantize: Int?
        ) {
            self.mfluxBinaryDir = mfluxBinaryDir; self.outputDir = outputDir
            self.defaultModel = defaultModel
            self.defaultBoard = defaultBoard; self.defaultWidth = defaultWidth
            self.defaultHeight = defaultHeight
            self.defaultLoras = defaultLoras; self.mlxCacheLimitGB = mlxCacheLimitGB
            self.hfHome = hfHome; self.mfluxCacheDir = mfluxCacheDir
            self.hfOffline = hfOffline; self.logFontSize = logFontSize
            self.lastPrompt = lastPrompt; self.lastWidth = lastWidth; self.lastHeight = lastHeight
            self.lastLoras = lastLoras; self.modelDefaults = modelDefaults
            self.lastModel = lastModel; self.lastQuantize = lastQuantize
            self.customTemplates = customTemplates; self.activeTemplateIDs = activeTemplateIDs
            self.batchShortcutPreset = batchShortcutPreset
            self.batchShortcutCustomCount = batchShortcutCustomCount
            self.gemmaModelPath = gemmaModelPath
            self.ideogram4ModelRepoOverride = ideogram4ModelRepoOverride
            self.lastIdeogramPreset = lastIdeogramPreset
            self.lastIdeogramWidth = lastIdeogramWidth
            self.lastIdeogramHeight = lastIdeogramHeight
            self.lastIdeogramQuantize = lastIdeogramQuantize
        }
    }

    /// Maximum number of unpinned ``promptHistory`` entries kept.
    static let promptHistoryCap = 200

    static let appSupportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MLXBits Image Studio", isDirectory: true)
    }()

    private static let settingsURL: URL = appSupportURL.appendingPathComponent("settings.json")

    private static func loadStored() -> Stored {
        guard let data = try? Data(contentsOf: settingsURL) else { return Stored() }
        return (try? JSONDecoder().decode(Stored.self, from: data)) ?? Stored()
    }

    /// Global
    var mfluxBinaryDir: String {
        didSet { save() }
    }

    var outputDir: String {
        didSet { save() }
    }

    var defaultModel: FluxModelVariant {
        didSet { save() }
    }

    var defaultBoard: String {
        didSet { save() }
    }

    var defaultWidth: Int {
        didSet { save() }
    }

    var defaultHeight: Int {
        didSet { save() }
    }

    /// Legacy pre-library default list. Kept only so ``drainLegacyDefaultLoras()``
    /// can fold it into `LibraryLora.isDefault` at launch; always empty afterwards.
    private var legacyDefaultLoras: [LoraEntry] {
        didSet { save() }
    }

    var mlxCacheLimitGB: Double {
        didSet { save() }
    }

    var hfHome: String {
        didSet { save() }
    }

    /// The Hugging Face hub cache directory (`$HF_HOME/hub`, or the default under ~/.cache).
    var hfHubDir: URL {
        if !hfHome.isEmpty {
            URL(fileURLWithPath: hfHome).appendingPathComponent("hub")
        } else {
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub")
        }
    }

    var mfluxCacheDir: String {
        didSet { save() }
    }

    var hfOffline: Bool {
        didSet { save() }
    }

    var hfToken: String {
        didSet { KeychainHelper.set(hfToken, key: "hf_token") }
    }

    var logFontSize: Double {
        didSet { save() }
    }

    var lastPrompt: String {
        didSet { save() }
    }

    var lastWidth: Int {
        didSet { save() }
    }

    var lastHeight: Int {
        didSet { save() }
    }

    var lastLoras: [LoraEntry] {
        didSet { save() }
    }

    var lastModel: FluxModelVariant {
        didSet { save() }
    }

    var lastQuantize: Int {
        didSet { save() }
    }

    /// Batch shortcut preset: 3, 5, or 10 for fixed sizes; 0 for custom.
    var batchShortcutPreset: Int {
        didSet { save() }
    }

    /// Custom batch count used when ``batchShortcutPreset`` is 0. Clamped to 11–100.
    var batchShortcutCustomCount: Int {
        didSet { save() }
    }

    /// The effective count triggered by ⌘⌥↵.
    var batchShortcutCount: Int {
        batchShortcutPreset == 0 ? batchShortcutCustomCount : batchShortcutPreset
    }

    // MARK: - Ideogram 4

    /// HF repo ID or local path for the Gemma model used to generate captions.
    var gemmaModelPath: String {
        didSet { save() }
    }

    /// Optional HF repo ID or local path override for the Ideogram 4 model.
    var ideogram4ModelRepoOverride: String? {
        didSet { save() }
    }

    var lastIdeogramPreset: Ideogram4Preset? {
        didSet { save() }
    }

    var lastIdeogramWidth: Int? {
        didSet { save() }
    }

    var lastIdeogramHeight: Int? {
        didSet { save() }
    }

    var lastIdeogramQuantize: Int? {
        didSet { save() }
    }

    var lastIdeogramCaption: IdeogramCaption? {
        didSet { save() }
    }

    var lastIdeogramPlainPrompt: String? {
        didSet { save() }
    }

    var lastIdeogramUsePlainPrompt: Bool? {
        didSet { save() }
    }

    /// Last Ideogram 4 seed (-1 = random), restored on next launch.
    var lastIdeogramSeed: Int? {
        didSet { save() }
    }

    /// Last-used Krea 2 form, restored on next launch.
    var lastKrea2: Krea2FormState? {
        didSet { save() }
    }

    // MARK: - SeedVR2 upscale defaults

    /// Default SeedVR2 model size: false = 3B (fast), true = 7B (quality).
    var seedVR2Use7B: Bool {
        didSet { save() }
    }

    /// Default SeedVR2 quantize level (0 = none, 8, or 4).
    var seedVR2Quantize: Int {
        didSet { save() }
    }

    /// Default SeedVR2 scale factor (2, 3, or 4).
    var seedVR2Scale: Int {
        didSet { save() }
    }

    /// Default SeedVR2 softness (0.0–1.0).
    var seedVR2Softness: Double {
        didSet { save() }
    }

    /// Stream Ideogram 4 transformer blocks from disk to reduce peak memory.
    var ideogram4LowRam: Bool {
        didSet { save() }
    }

    /// Pass `--strict-caption-validation` to reject captions that don't match the schema.
    var ideogram4StrictValidation: Bool {
        didSet { save() }
    }

    /// Fraction of steps (0–1) that run CFG before switching to cond-only (`--cfg-end`).
    /// `nil` = full CFG every step.
    var ideogram4CfgEnd: Double? {
        didSet { save() }
    }

    // MARK: - Notepad

    /// Free-form markdown scratchpad for reusable prompt notes. Autosaves on edit.
    var notepadText: String {
        didSet { save() }
    }

    // MARK: - Prompt history

    /// Prompts recorded when jobs are queued, newest first. Unpinned entries are
    /// capped at ``promptHistoryCap``; pinned entries are never evicted.
    var promptHistory: [PromptHistoryEntry] {
        didSet { save() }
    }

    // MARK: - Warm-model driver

    /// Route eligible Flux jobs through the persistent driver that keeps the
    /// model loaded between generations (see ``MfluxDriverController``).
    var keepModelWarm: Bool {
        didSet { save() }
    }

    /// Minutes of idleness before the warm model is evicted. 0 = never.
    var warmIdleMinutes: Int {
        didSet { save() }
    }

    /// Text-encoder residency policy for warm generations.
    var warmTextEncoderPolicy: WarmTextEncoderPolicy {
        didSet { save() }
    }

    // MARK: - Scenario generator

    /// Last outline entered in the scenario generator, restored across launches.
    var lastScenarioOutline: String {
        didSet { save() }
    }

    /// Detail categories the scenario generator is allowed to invent.
    var scenarioCategories: Set<ScenarioCategory> {
        didSet { save() }
    }

    /// Whether the scenario generator emits {a|b|c} wildcard groups.
    var scenarioWildcardMode: Bool {
        didSet { save() }
    }

    // MARK: - Prompt-writing LLM backend

    /// Which engine serves the Scenario Generator and Ideogram 4 captions:
    /// local Gemma via `uv`/`mlx_lm`, or a remote OpenAI-compatible endpoint.
    var llmBackend: LLMBackendKind {
        didSet { save() }
    }

    /// Base URL of the OpenAI-compatible endpoint, e.g. `http://localhost:1234/v1`.
    var openAIBaseURL: String {
        didSet { save() }
    }

    /// Model id sent to the endpoint (as shown by `GET /v1/models`).
    var openAIModel: String {
        didSet { save() }
    }

    /// Sampling temperature sent to the endpoint for both remote features.
    /// Match the model's recommendation (e.g. Gemma 4 favors 1.0).
    var openAITemperature: Double {
        didSet { save() }
    }

    /// Nucleus-sampling cutoff (`top_p`) sent to the endpoint. Gemma favors 0.95.
    var openAITopP: Double {
        didSet { save() }
    }

    /// Top-k sampling sent to the endpoint. Gemma favors 64; 0 omits the field.
    var openAITopK: Int {
        didSet { save() }
    }

    /// Optional bearer token for the endpoint. Blank for LM Studio; required for
    /// secured/hosted servers. Stored in the Keychain (mirrors ``hfToken``).
    var openAIAPIKey: String {
        didSet { KeychainHelper.set(openAIAPIKey, key: "openai_api_key") }
    }

    // MARK: - Per-model overrides, keyed by `FluxModelVariant.rawValue`.
    var modelDefaults: [String: ModelDefaults] {
        didSet { save() }
    }

    /// User-created prompt templates (built-ins live in `BuiltInTemplates.all`).
    var customTemplates: [PromptTemplate] {
        didSet { save() }
    }

    /// IDs of the currently active prompt templates, in selection order.
    var activeTemplateIDs: [UUID] {
        didSet { save() }
    }

    /// Set to a human-readable message when ``save()`` fails; cleared on the next
    /// successful save. Observed by ``SettingsView`` to display an alert.
    var saveError: String?

    @ObservationIgnored private let saveDebouncer = Debouncer()

    /// All templates: built-ins first, then user customs.
    var allTemplates: [PromptTemplate] {
        BuiltInTemplates.all + customTemplates
    }

    /// The currently active templates in selection order, excluding stale IDs.
    var activeTemplates: [PromptTemplate] {
        activeTemplateIDs.compactMap { id in allTemplates.first { $0.id == id } }
    }

    /// The mflux cache dir: honours user override, otherwise matches mflux's own default
    /// (~/Library/Caches/mflux via platformdirs on macOS).
    var effectiveMfluxCacheDir: URL {
        if !mfluxCacheDir.isEmpty {
            return URL(fileURLWithPath: mfluxCacheDir)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("mflux")
    }

    init() {
        let s = Self.loadStored()
        let model = s.defaultModel ?? .flux2Klein9B

        mfluxBinaryDir = s.mfluxBinaryDir ?? BinaryDetector.detectBinaryDir(for: "mflux-generate-flux2")
        outputDir = s.outputDir ?? "" // empty = not yet chosen; app will prompt on first use
        defaultModel = model
        defaultBoard = s.defaultBoard ?? ""
        defaultWidth = s.defaultWidth ?? 1024
        defaultHeight = s.defaultHeight ?? 1024
        legacyDefaultLoras = s.defaultLoras ?? []
        mlxCacheLimitGB = s.mlxCacheLimitGB ?? 0
        hfHome = s.hfHome ?? ""
        mfluxCacheDir = s.mfluxCacheDir ?? ""
        hfOffline = s.hfOffline ?? false
        hfToken = KeychainHelper.get("hf_token")
        logFontSize = s.logFontSize ?? 12.0
        lastPrompt = s.lastPrompt ?? ""
        lastWidth = s.lastWidth ?? 1024
        lastHeight = s.lastHeight ?? 1024
        lastLoras = s.lastLoras ?? []
        modelDefaults = s.modelDefaults ?? [:]
        let lastM = s.lastModel ?? s.defaultModel ?? .flux2Klein9B
        lastModel = lastM
        lastQuantize = s.lastQuantize
            ?? (s.modelDefaults?[lastM.rawValue]?.quantize ?? lastM.recommendedQuantize)
        batchShortcutPreset = s.batchShortcutPreset ?? 3
        batchShortcutCustomCount = s.batchShortcutCustomCount ?? 25
        gemmaModelPath = s.gemmaModelPath ?? "mlx-community/gemma-3-12b-it-4bit"
        ideogram4ModelRepoOverride = s.ideogram4ModelRepoOverride
        lastIdeogramPreset = s.lastIdeogramPreset
        lastIdeogramWidth = s.lastIdeogramWidth
        lastIdeogramHeight = s.lastIdeogramHeight
        lastIdeogramQuantize = s.lastIdeogramQuantize
        lastIdeogramCaption = s.lastIdeogramCaption
        lastIdeogramPlainPrompt = s.lastIdeogramPlainPrompt
        lastIdeogramUsePlainPrompt = s.lastIdeogramUsePlainPrompt
        lastIdeogramSeed = s.lastIdeogramSeed
        lastKrea2 = s.lastKrea2
        seedVR2Use7B = s.seedVR2Use7B ?? false
        seedVR2Quantize = s.seedVR2Quantize ?? 8
        seedVR2Scale = s.seedVR2Scale ?? 2
        seedVR2Softness = s.seedVR2Softness ?? 0.0
        ideogram4LowRam = s.ideogram4LowRam ?? false
        ideogram4StrictValidation = s.ideogram4StrictValidation ?? false
        ideogram4CfgEnd = s.ideogram4CfgEnd
        notepadText = s.notepadText ?? ""
        promptHistory = s.promptHistory ?? []
        keepModelWarm = s.keepModelWarm ?? false
        warmIdleMinutes = s.warmIdleMinutes ?? 10
        warmTextEncoderPolicy = s.warmTextEncoderPolicy ?? .auto
        lastScenarioOutline = s.lastScenarioOutline ?? ""
        scenarioCategories = s.scenarioCategories
            .map { Set($0.compactMap(ScenarioCategory.init)) }
            ?? Set(ScenarioCategory.allCases)
        scenarioWildcardMode = s.scenarioWildcardMode ?? false
        llmBackend = s.llmBackend ?? .local
        openAIBaseURL = s.openAIBaseURL ?? "http://localhost:1234/v1"
        openAIModel = s.openAIModel ?? ""
        openAITemperature = s.openAITemperature ?? 0.7
        openAITopP = s.openAITopP ?? 0.95
        openAITopK = s.openAITopK ?? 64
        openAIAPIKey = KeychainHelper.get("openai_api_key")
        customTemplates = s.customTemplates ?? []
        // Migrate single-ID storage (written by earlier builds) to array.
        if let ids = s.activeTemplateIDs {
            activeTemplateIDs = ids
        } else if let id = s.activeTemplateID {
            activeTemplateIDs = [id]
        } else {
            activeTemplateIDs = []
        }
    }

    // MARK: - Legacy migration

    /// Returns and clears the legacy default-LoRA list (one-time migration hook;
    /// see `LoraLibraryStore.migrateLegacyDefaults`).
    func drainLegacyDefaultLoras() -> [LoraEntry] {
        let drained = legacyDefaultLoras
        if !drained.isEmpty { legacyDefaultLoras = [] }
        return drained
    }

    // MARK: - Per-model helpers

    /// Returns the ModelDefaults for `model`, creating an empty one if none exists.
    func defaults(for model: FluxModelVariant) -> ModelDefaults {
        modelDefaults[model.rawValue] ?? ModelDefaults()
    }

    func resolvedDefaults(for model: FluxModelVariant) -> ModelDefaults.Resolved {
        defaults(for: model).resolved(for: model)
    }

    func updateDefaults(_ d: ModelDefaults, for model: FluxModelVariant) {
        modelDefaults[model.rawValue] = d
    }

    // MARK: - Template helpers

    /// Toggles `id` in or out of the active selection.
    func toggleTemplate(_ id: UUID) {
        if let idx = activeTemplateIDs.firstIndex(of: id) {
            activeTemplateIDs.remove(at: idx)
        } else {
            activeTemplateIDs.append(id)
        }
    }

    // MARK: - Prompt history helpers

    /// Records a queued prompt: bumps the existing entry on an exact (trimmed)
    /// match, otherwise prepends a new one and evicts the oldest unpinned
    /// entries beyond ``promptHistoryCap``.
    func recordPromptUse(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = promptHistory.firstIndex(where: { $0.prompt == trimmed }) {
            promptHistory[idx].lastUsedAt = Date()
            promptHistory[idx].useCount += 1
        } else {
            promptHistory.insert(PromptHistoryEntry(prompt: trimmed, lastUsedAt: Date()), at: 0)
        }
        let excess = promptHistory.filter { !$0.pinned }.count - Self.promptHistoryCap
        guard excess > 0 else { return }
        let evictable = Set(
            promptHistory
                .filter { !$0.pinned }
                .sorted { $0.lastUsedAt < $1.lastUsedAt }
                .prefix(excess)
                .map(\.id)
        )
        promptHistory.removeAll { evictable.contains($0.id) }
    }

    // MARK: - Persistence

    /// Debounced: every settable property calls this from `didSet`, and the notepad
    /// autosaves per keystroke — coalesce so each burst costs one encode + write.
    /// The Debouncer flushes pending work at app termination.
    func save() {
        saveDebouncer.schedule { [weak self] in self?.saveNow() }
    }

    private func saveNow() {
        var s = Stored(
            mfluxBinaryDir: mfluxBinaryDir, outputDir: outputDir,
            defaultModel: defaultModel, defaultBoard: defaultBoard,
            defaultWidth: defaultWidth, defaultHeight: defaultHeight,
            defaultLoras: legacyDefaultLoras,
            mlxCacheLimitGB: mlxCacheLimitGB, hfHome: hfHome,
            mfluxCacheDir: mfluxCacheDir, hfOffline: hfOffline,
            logFontSize: logFontSize, lastPrompt: lastPrompt,
            lastWidth: lastWidth, lastHeight: lastHeight,
            lastLoras: lastLoras, modelDefaults: modelDefaults,
            lastModel: lastModel, lastQuantize: lastQuantize,
            customTemplates: customTemplates, activeTemplateIDs: activeTemplateIDs,
            batchShortcutPreset: batchShortcutPreset,
            batchShortcutCustomCount: batchShortcutCustomCount,
            gemmaModelPath: gemmaModelPath,
            ideogram4ModelRepoOverride: ideogram4ModelRepoOverride,
            lastIdeogramPreset: lastIdeogramPreset,
            lastIdeogramWidth: lastIdeogramWidth,
            lastIdeogramHeight: lastIdeogramHeight,
            lastIdeogramQuantize: lastIdeogramQuantize
        )
        s.lastIdeogramCaption = lastIdeogramCaption
        s.lastIdeogramPlainPrompt = lastIdeogramPlainPrompt
        s.lastIdeogramUsePlainPrompt = lastIdeogramUsePlainPrompt
        s.lastIdeogramSeed = lastIdeogramSeed
        s.ideogram4LowRam = ideogram4LowRam
        s.ideogram4StrictValidation = ideogram4StrictValidation
        s.ideogram4CfgEnd = ideogram4CfgEnd
        s.lastKrea2 = lastKrea2
        s.seedVR2Use7B = seedVR2Use7B
        s.seedVR2Quantize = seedVR2Quantize
        s.seedVR2Scale = seedVR2Scale
        s.seedVR2Softness = seedVR2Softness
        s.notepadText = notepadText
        s.promptHistory = promptHistory
        s.keepModelWarm = keepModelWarm
        s.warmIdleMinutes = warmIdleMinutes
        s.warmTextEncoderPolicy = warmTextEncoderPolicy
        s.lastScenarioOutline = lastScenarioOutline
        s.scenarioCategories = scenarioCategories.map(\.rawValue).sorted()
        s.scenarioWildcardMode = scenarioWildcardMode
        s.llmBackend = llmBackend
        s.openAIBaseURL = openAIBaseURL
        s.openAIModel = openAIModel
        s.openAITemperature = openAITemperature
        s.openAITopP = openAITopP
        s.openAITopK = openAITopK
        do {
            try FileManager.default.createDirectory(at: Self.appSupportURL, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = .prettyPrinted
            let data = try enc.encode(s)
            try data.write(to: Self.settingsURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func ensureOutputDirExists() {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDir), withIntermediateDirectories: true
        )
    }

    func mfluxBinaryPath() -> String {
        BinaryDetector.mfluxGenerateFlux2(in: mfluxBinaryDir)
    }

    func mfluxEditBinaryPath() -> String {
        BinaryDetector.mfluxGenerateFlux2Edit(in: mfluxBinaryDir)
    }

    func mfluxIdeogram4BinaryPath() -> String {
        BinaryDetector.mfluxGenerateIdeogram4(in: mfluxBinaryDir)
    }

    func mfluxKrea2BinaryPath() -> String {
        BinaryDetector.mfluxGenerateKrea2(in: mfluxBinaryDir)
    }

    func mfluxSeedVR2BinaryPath() -> String {
        BinaryDetector.mfluxUpscaleSeedVR2(in: mfluxBinaryDir)
    }

    func mlxLmBinaryPath() -> String {
        BinaryDetector.mlxLmGenerate(in: mfluxBinaryDir)
    }

    /// Returns true when Ideogram 4 model weights are already cached locally.
    func ideogram4ModelOnDisk(quantize: Int) -> Bool {
        let hfBase = hfHubDir
        if quantize > 0 {
            // Q8/Q4 ship as published MLX repos and load straight from the hub cache.
            // The legacy mflux-save dir is never used for them (and may be stale), so
            // a present pre-quantized repo is the only signal we trust.
            if let repo = FluxModelVariant.ideogram4.preQuantizedRepoID(quantize: quantize) {
                let cacheName = "models--" + repo.replacingOccurrences(of: "/", with: "--")
                let snapshots = hfBase.appendingPathComponent(cacheName + "/snapshots")
                return FileManager.default.fileExists(atPath: snapshots.path)
            }
            let savedPath = effectiveMfluxCacheDir
                .appendingPathComponent("saved/ideogram4-q\(quantize)", isDirectory: true)
            return FluxModelVariant.hasSavedWeights(at: savedPath)
        }
        // Check HF hub cache for the FP8 base checkpoint.
        let snapshots = hfBase.appendingPathComponent("models--ideogram-ai--ideogram-4-fp8/snapshots")
        return FileManager.default.fileExists(atPath: snapshots.path)
    }

    func buildEnvironment() -> [String: String] {
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        if !hfHome.isEmpty { env["HF_HOME"] = hfHome }
        if !mfluxCacheDir.isEmpty { env["MFLUX_CACHE_DIR"] = mfluxCacheDir }
        if hfOffline { env["HF_HUB_OFFLINE"] = "1" }
        if !hfToken.isEmpty { env["HF_TOKEN"] = hfToken }
        return env
    }
}
