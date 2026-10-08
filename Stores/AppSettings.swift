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
        /// Read-only legacy key: migrated into `customPython` at launch
        /// (``ToolchainMigration``) and never written again.
        var mfluxBinaryDir: String?
        /// DMG only: the Custom Python override (spec §3). Absent until the
        /// first launch of 0.16.0 migrates `mfluxBinaryDir` into it.
        var customPython: String?
        var defaultModel: FluxModelVariant?
        var defaultWidth: Int?; var defaultHeight: Int?
        var defaultLoras: [LoraEntry]?
        var mlxCacheLimitGB: Double?; var hfHome: String?; var mfluxCacheDir: String?
        var hfOffline: Bool?; var logFontSize: Double?
        var lastWidth: Int?; var lastHeight: Int?
        var lastModel: FluxModelVariant?; var lastQuantize: Int?
        var modelDefaults: [String: ModelDefaults]?
        var batchShortcutPreset: Int?
        var batchShortcutCustomCount: Int?
        /// Aspect-preset area targets, in megapixels: normal quality and rapid iteration.
        var targetMegapixels: Double?
        var rapidTargetMegapixels: Double?
        // Ideogram 4
        var gemmaModelPath: String?
        var ideogram4ModelRepoOverride: String?
        var lastIdeogramPreset: Ideogram4Preset?
        var lastIdeogramWidth: Int?
        var lastIdeogramHeight: Int?
        var lastIdeogramQuantize: Int?
        var ideogram4LowRam: Bool?
        var ideogram4StrictValidation: Bool?
        var ideogram4CfgEnd: Double?
        /// Custom model picker entry (remembered across launches)
        var lastCustomModelRepo: String?
        var lastCustomBaseModel: FluxModelVariant?
        // ComfyUI remote inference backend (per-family server-side filenames, keyed by `ModelFamily.id`)
        var comfyURL: String?
        var comfyUNet: [String: String]?
        var comfyClip: [String: String]?
        var comfyVae: [String: String]?
        /// Per-family backend choice (true = ComfyUI remote, false/absent = local mflux), keyed by `ModelFamily.id`.
        var comfyBackendEnabled: [String: Bool]?
        /// Legacy single-checkpoint slot, kept only to decode pre-split settings files; migrated to ``comfyUNet``.
        var comfyCheckpoint: [String: String]?
        /// SeedVR2 upscale defaults (remembered across launches)
        var seedVR2Use7B: Bool?
        var seedVR2Quantize: Int?
        var seedVR2Scale: Int?
        var seedVR2Softness: Double?
        /// Warm-model driver
        var keepModelWarm: Bool?
        var warmIdleMinutes: Int?
        var warmTextEncoderPolicy: WarmTextEncoderPolicy?
        /// Scenario generator (raw values so future category changes degrade
        /// gracefully instead of failing the whole settings decode)
        var scenarioCategories: [String]?
        var scenarioWildcardMode: Bool?
        var scenarioQueueCount: Int?
        /// Prompt-writing LLM backend (local Gemma vs OpenAI-compatible endpoint).
        /// The API key is Keychain-backed and never stored here.
        var llmBackend: LLMBackendKind?
        var openAIBaseURL: String?
        var openAIModel: String?
        /// Legacy key: temperature was remote-only before it governed both backends.
        /// Read as a fallback for ``llmTemperature``; no longer written.
        var openAITemperature: Double?
        var llmTemperature: Double?
        var openAITopP: Double?
        var openAITopK: Int?

        init() {}
        init(
            defaultModel: FluxModelVariant,
            defaultWidth: Int, defaultHeight: Int,
            defaultLoras: [LoraEntry],
            mlxCacheLimitGB: Double, hfHome: String, mfluxCacheDir: String,
            hfOffline: Bool, logFontSize: Double,
            lastWidth: Int, lastHeight: Int,
            modelDefaults: [String: ModelDefaults],
            lastModel: FluxModelVariant, lastQuantize: Int,
            batchShortcutPreset: Int, batchShortcutCustomCount: Int,
            gemmaModelPath: String, ideogram4ModelRepoOverride: String?,
            lastIdeogramPreset: Ideogram4Preset?, lastIdeogramWidth: Int?,
            lastIdeogramHeight: Int?, lastIdeogramQuantize: Int?
        ) {
            self.defaultModel = defaultModel
            self.defaultWidth = defaultWidth
            self.defaultHeight = defaultHeight
            self.defaultLoras = defaultLoras; self.mlxCacheLimitGB = mlxCacheLimitGB
            self.hfHome = hfHome; self.mfluxCacheDir = mfluxCacheDir
            self.hfOffline = hfOffline; self.logFontSize = logFontSize
            self.lastWidth = lastWidth; self.lastHeight = lastHeight
            self.modelDefaults = modelDefaults
            self.lastModel = lastModel; self.lastQuantize = lastQuantize
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

    /// The Custom Python to start with: the saved one or, on the first launch of
    /// 0.16.0, what the old mflux folder setting migrates to (spec §3). A dev
    /// checkout carries over; a uv-managed install (or none) means the bundled runtime.
    private static func customPython(migrating s: Stored) -> String {
        s.customPython ?? ToolchainMigration.customPython(fromLegacyBinaryDir: s.mfluxBinaryDir ?? "") ?? ""
    }

    /// Global, DMG only: an interpreter that runs mflux and the warm driver in
    /// place of the bundled runtime, such as a dev checkout's `.venv/bin/python`.
    var customPythonPath: String {
        didSet {
            refreshToolchain()
            save()
        }
    }

    /// How Python tools run. Rebuilt by ``refreshToolchain()``.
    private(set) var toolchain = Toolchain(resourcesURL: nil, customPython: "")

    /// Models the current toolchain ships a generation tool for. Cached rather
    /// than probed per view update; recomputed by ``refreshToolchain()``.
    private(set) var availableModels: [FluxModelVariant] = []

    /// The active profile's library folder. Read-only here: the profile registry
    /// owns it, and ``activateProfile(contentURL:libraryPath:)`` /
    /// ``applyLibraryPath(_:)`` are the only writers.
    private(set) var outputDir: String

    var defaultModel: FluxModelVariant {
        didSet { save() }
    }

    var defaultBoard: String {
        didSet { saveProfile() }
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
        didSet {
            save()
            refreshSessionAccess()
        }
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
        didSet {
            save()
            refreshSessionAccess()
        }
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
        didSet { saveProfile() }
    }

    var lastWidth: Int {
        didSet { save() }
    }

    var lastHeight: Int {
        didSet { save() }
    }

    var lastLoras: [LoraEntry] {
        didSet { saveProfile() }
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

    /// Total area the aspect-ratio preset buttons aim for, in megapixels.
    /// Clamped to ``DimensionConstraints/megapixelTargetRange``.
    var targetMegapixels: Double {
        didSet { save() }
    }

    /// Area the preset buttons aim for while rapid iteration (⚡) is on — draft sizes
    /// meant to be upscaled later in img-2-img.
    var rapidTargetMegapixels: Double {
        didSet { save() }
    }

    // MARK: - Ideogram 4

    /// HF repo ID or local path for the Gemma model used to generate captions.
    var gemmaModelPath: String {
        didSet {
            save()
            refreshSessionAccess()
        }
    }

    /// Optional HF repo ID or local path override for the Ideogram 4 model.
    var ideogram4ModelRepoOverride: String? {
        didSet {
            save()
            refreshSessionAccess()
        }
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
        didSet { saveProfile() }
    }

    var lastIdeogramPlainPrompt: String? {
        didSet { saveProfile() }
    }

    var lastIdeogramUsePlainPrompt: Bool? {
        didSet { saveProfile() }
    }

    /// Last Ideogram 4 seed (-1 = random), restored on next launch.
    var lastIdeogramSeed: Int? {
        didSet { saveProfile() }
    }

    /// Repo ID or path last entered for the picker's `Custom…` entry. Persisted
    /// because a custom checkpoint is now how a whole family gets run, not a
    /// one-field detour off the built-in Flux variants.
    var lastCustomModelRepo: String {
        didSet { save() }
    }

    /// Which known model that custom checkpoint was last loaded as.
    var lastCustomBaseModel: FluxModelVariant {
        didSet { save() }
    }

    /// Last-used Krea 2 form, restored on next launch.
    var lastKrea2: Krea2FormState? {
        didSet { saveProfile() }
    }

    // MARK: - ComfyUI remote inference backend

    /// Base URL of a running ComfyUI server used as an alternate inference backend (empty = use local mflux).
    var comfyURL: String {
        didSet { save() }
    }

    /// Per-family server-side UNet/diffusion-model filename (`models/unet`), keyed by `ModelFamily.id`.
    var comfyUNet: [String: String] {
        didSet { save() }
    }

    /// Per-family server-side CLIP text-encoder filename (`models/clip`), keyed by `ModelFamily.id`.
    var comfyClip: [String: String] {
        didSet { save() }
    }

    /// Per-family server-side VAE filename (`models/vae`), keyed by `ModelFamily.id`.
    var comfyVae: [String: String] {
        didSet { save() }
    }

    /// Per-family inference-backend choice (true = ComfyUI remote, false/absent = local mflux), keyed by `ModelFamily.id`.
    var comfyBackendEnabled: [String: Bool] {
        didSet { save() }
    }

    /// The ComfyUI server in use: the trimmed ``comfyURL`` while at least one family routes to it, else `nil`.
    var activeComfyURL: String? {
        let url = comfyURL.trimmed()
        return url.isEmpty || !comfyBackendEnabled.values.contains(true) ? nil : url
    }

    /// Last-used Z-Image form, restored on next launch.
    var lastZImage: ZImageFormState? {
        didSet { saveProfile() }
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
        didSet { saveProfile() }
    }

    // MARK: - Prompt history

    /// Prompts recorded when jobs are queued, newest first. Unpinned entries are
    /// capped at ``promptHistoryCap``; pinned entries are never evicted.
    var promptHistory: [PromptHistoryEntry] {
        didSet { saveProfile() }
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
        didSet { saveProfile() }
    }

    /// Detail categories the scenario generator is allowed to invent.
    var scenarioCategories: Set<ScenarioCategory> {
        didSet { save() }
    }

    /// Whether the scenario generator emits {a|b|c} wildcard groups.
    var scenarioWildcardMode: Bool {
        didSet { save() }
    }

    /// How many prompts the scenario generator's "Queue" button rolls — one image
    /// each. Remembers the last count picked from its menu.
    var scenarioQueueCount: Int {
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

    /// Sampling temperature for the Scenario Generator, on **both** backends —
    /// sent to the endpoint on the remote path and to `make_sampler` on the local
    /// one. Match the model's recommendation (e.g. Gemma 4 favors 1.0); raise it
    /// (~1.1) to make batch prompt rolls diverge.
    var llmTemperature: Double {
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
        didSet {
            save()
            refreshSessionAccess()
        }
    }

    /// User-created prompt templates (built-ins live in `BuiltInTemplates.all`).
    var customTemplates: [PromptTemplate] {
        didSet { saveProfile() }
    }

    /// IDs of the currently active prompt templates, in selection order.
    var activeTemplateIDs: [UUID] {
        didSet { saveProfile() }
    }

    /// Set to a human-readable message when ``save()`` fails; cleared on the next
    /// successful save. Observed by ``SettingsView`` to display an alert.
    var saveError: String?

    @ObservationIgnored private let saveDebouncer = Debouncer()

    /// How the app reaches folders and files outside its own (spec §4): paths
    /// pass through in the DMG; the App Store build keeps security-scoped
    /// grants. Settable so tests can swap in a recording one.
    @ObservationIgnored var fileAccess: any FileAccess = FileAccessFactory.make()
    /// Holds the folder settings' grants for the session; see ``refreshSessionAccess()``.
    @ObservationIgnored var sessionLease: FileAccessLease?

    // MARK: - Per-profile persistence

    /// Gallery boards the user collapsed in the active profile's library.
    var galleryCollapsedBoards: [String] {
        didSet { saveProfile() }
    }

    /// The active profile's `profile.json`; `nil` until a profile is activated.
    /// The debounced save reads it when it runs, which is why activation flushes
    /// before swapping it.
    @ObservationIgnored private(set) var profileFileURL: URL?
    @ObservationIgnored private let profileSaveDebouncer = Debouncer()
    /// Set while a profile's fields are being loaded, so the `didSet` observers
    /// don't write the half-loaded state straight back.
    @ObservationIgnored private var isApplyingProfile = false
    /// Set when the profile registry can't be read: nothing is written until the
    /// user fixes or removes it, so no data is overwritten while it's unreadable.
    @ObservationIgnored private var persistenceSuspended = false

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

        customPythonPath = Self.customPython(migrating: s)
        // Per-profile fields start empty; ProfileStore activates a profile right
        // after init, which loads them from that profile's profile.json.
        outputDir = ""
        defaultModel = model
        defaultBoard = ""
        defaultWidth = s.defaultWidth ?? 1024
        defaultHeight = s.defaultHeight ?? 1024
        legacyDefaultLoras = s.defaultLoras ?? []
        mlxCacheLimitGB = s.mlxCacheLimitGB ?? 0
        hfHome = s.hfHome ?? ""
        mfluxCacheDir = s.mfluxCacheDir ?? ""
        hfOffline = s.hfOffline ?? false
        hfToken = KeychainHelper.get("hf_token")
        logFontSize = s.logFontSize ?? 12.0
        lastPrompt = ""
        lastWidth = s.lastWidth ?? 1024
        lastHeight = s.lastHeight ?? 1024
        lastLoras = []
        modelDefaults = s.modelDefaults ?? [:]
        let lastM = s.lastModel ?? s.defaultModel ?? .flux2Klein9B
        lastModel = lastM
        lastQuantize = s.lastQuantize
            ?? (s.modelDefaults?[lastM.rawValue]?.quantize ?? lastM.recommendedQuantize)
        batchShortcutPreset = s.batchShortcutPreset ?? 3
        batchShortcutCustomCount = s.batchShortcutCustomCount ?? 25
        targetMegapixels = DimensionConstraints.clampMegapixels(s.targetMegapixels ?? 1.0)
        rapidTargetMegapixels = DimensionConstraints.clampMegapixels(s.rapidTargetMegapixels ?? 0.25)
        gemmaModelPath = s.gemmaModelPath ?? "mlx-community/gemma-3-12b-it-4bit"
        ideogram4ModelRepoOverride = s.ideogram4ModelRepoOverride
        lastIdeogramPreset = s.lastIdeogramPreset
        lastIdeogramWidth = s.lastIdeogramWidth
        lastIdeogramHeight = s.lastIdeogramHeight
        lastIdeogramQuantize = s.lastIdeogramQuantize
        lastIdeogramCaption = nil
        lastIdeogramPlainPrompt = nil
        lastIdeogramUsePlainPrompt = nil
        lastIdeogramSeed = nil
        lastCustomModelRepo = s.lastCustomModelRepo ?? ""
        lastCustomBaseModel = s.lastCustomBaseModel ?? .flux2Klein9B
        lastKrea2 = nil
        lastZImage = nil
        comfyURL = s.comfyURL ?? ""
        // Migrate a pre-split saved `comfyCheckpoint` entry into the UNet slot so existing config keeps working.
        var unetMap = s.comfyUNet ?? [:]
        if let legacy = s.comfyCheckpoint {
            for (key, val) in legacy where unetMap[key] == nil && !val.isEmpty {
                unetMap[key] = val
            }
        }
        comfyUNet = unetMap
        comfyClip = s.comfyClip ?? [:]
        comfyVae = s.comfyVae ?? [:]
        // Migrate backend intent: an existing remote setup (URL + all three model files present for a family)
        // stays remote; everything else defaults to mflux so the segment matches prior behavior.
        var backendMap = s.comfyBackendEnabled ?? [:]
        let urlConfigured = !(s.comfyURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for family in ModelFamily.allCases {
            let id = family.id
            guard backendMap[id] == nil else { continue }
            let hasModels = unetMap[id].map { !$0.isEmpty } ?? false
                && (s.comfyClip?[id]).map { !$0.isEmpty } ?? false
                && (s.comfyVae?[id]).map { !$0.isEmpty } ?? false
            backendMap[id] = urlConfigured && hasModels
        }
        comfyBackendEnabled = backendMap
        seedVR2Use7B = s.seedVR2Use7B ?? false
        seedVR2Quantize = s.seedVR2Quantize ?? 8
        seedVR2Scale = s.seedVR2Scale ?? 2
        seedVR2Softness = s.seedVR2Softness ?? 0.0
        ideogram4LowRam = s.ideogram4LowRam ?? false
        ideogram4StrictValidation = s.ideogram4StrictValidation ?? false
        ideogram4CfgEnd = s.ideogram4CfgEnd
        notepadText = ""
        promptHistory = []
        keepModelWarm = s.keepModelWarm ?? false
        warmIdleMinutes = s.warmIdleMinutes ?? 10
        warmTextEncoderPolicy = s.warmTextEncoderPolicy ?? .auto
        lastScenarioOutline = ""
        scenarioCategories = s.scenarioCategories
            .map { Set($0.compactMap(ScenarioCategory.init)) }
            ?? Set(ScenarioCategory.allCases)
        scenarioWildcardMode = s.scenarioWildcardMode ?? false
        scenarioQueueCount = s.scenarioQueueCount ?? 5
        llmBackend = s.llmBackend ?? .local
        openAIBaseURL = s.openAIBaseURL ?? "http://localhost:1234/v1"
        openAIModel = s.openAIModel ?? ""
        llmTemperature = s.llmTemperature ?? s.openAITemperature ?? 0.7
        openAITopP = s.openAITopP ?? 0.95
        openAITopK = s.openAITopK ?? 64
        openAIAPIKey = KeychainHelper.get("openai_api_key")
        customTemplates = []
        activeTemplateIDs = []
        galleryCollapsedBoards = []
        refreshToolchain()
    }

    // MARK: - Model availability

    /// Rebuilds the toolchain from ``customPythonPath``, which the App Store build
    /// ignores (spec §3), and re-checks which families it can run.
    func refreshToolchain() {
        toolchain = Toolchain(
            resourcesURL: Bundle.main.resourceURL,
            customPython: BuildFlavor.isAppStore ? "" : customPythonPath
        )
        refreshAvailableModels()
    }

    /// Re-checks which families the current toolchain can run.
    func refreshAvailableModels() {
        availableModels = FluxModelVariant.customTargets(toolchain: toolchain)
    }

    /// Whether the toolchain can run `model`'s generation tool. `custom` has no
    /// tool of its own — its target is what gets checked.
    ///
    /// An empty ``availableModels`` means nothing was detected at all (no runtime
    /// and no usable Custom Python). Gating on that would leave the picker with
    /// nothing selectable, so nothing is gated until at least one tool is found.
    func supportsModel(_ model: FluxModelVariant) -> Bool {
        model == .custom || availableModels.isEmpty || availableModels.contains(model)
    }

    // MARK: - Legacy migration

    /// Returns and clears the legacy default-LoRA list (one-time migration hook;
    /// see `LoraLibraryStore.migrateLegacyDefaults`).
    func drainLegacyDefaultLoras() -> [LoraEntry] {
        let drained = legacyDefaultLoras
        if !drained.isEmpty {
            legacyDefaultLoras = []
        }
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
        guard !persistenceSuspended else { return }
        saveDebouncer.schedule { [weak self] in self?.saveNow() }
    }

    /// Writes settings.json now. Used once after migration, so the moved
    /// per-profile keys are dropped from the global file straight away.
    func persistGlobalNow() {
        guard !persistenceSuspended else { return }
        saveDebouncer.flush()
        saveNow()
    }

    /// Stops all settings writes for the rest of the session. See
    /// ``persistenceSuspended``.
    func suspendPersistence() {
        persistenceSuspended = true
    }

    /// Points the per-profile fields at another profile: pending edits are
    /// written to the current profile's file first, then the new profile's
    /// fields load without triggering saves.
    func activateProfile(contentURL: URL?, libraryPath: String) {
        profileSaveDebouncer.flush()
        profileFileURL = contentURL
        isApplyingProfile = true
        defer { isApplyingProfile = false }
        outputDir = libraryPath
        apply(ProfileStored.load(from: contentURL))
    }

    /// Re-points the active profile at a different library folder (Change Folder).
    func applyLibraryPath(_ path: String) {
        outputDir = path
    }

    /// Debounced save of the per-profile fields to the active profile's file.
    func saveProfile() {
        guard !isApplyingProfile, !persistenceSuspended, profileFileURL != nil else { return }
        profileSaveDebouncer.schedule { [weak self] in self?.saveProfileNow() }
    }

    private func saveProfileNow() {
        guard let url = profileFileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let enc = JSONEncoder()
            enc.outputFormatting = .prettyPrinted
            try enc.encode(ProfileStored(snapshotOf: self)).write(to: url, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Could not save profile: \(error.localizedDescription)"
        }
    }

    private func saveNow() {
        var s = Stored(
            defaultModel: defaultModel,
            defaultWidth: defaultWidth, defaultHeight: defaultHeight,
            defaultLoras: legacyDefaultLoras,
            mlxCacheLimitGB: mlxCacheLimitGB, hfHome: hfHome,
            mfluxCacheDir: mfluxCacheDir, hfOffline: hfOffline,
            logFontSize: logFontSize,
            lastWidth: lastWidth, lastHeight: lastHeight,
            modelDefaults: modelDefaults,
            lastModel: lastModel, lastQuantize: lastQuantize,
            batchShortcutPreset: batchShortcutPreset,
            batchShortcutCustomCount: batchShortcutCustomCount,
            gemmaModelPath: gemmaModelPath,
            ideogram4ModelRepoOverride: ideogram4ModelRepoOverride,
            lastIdeogramPreset: lastIdeogramPreset,
            lastIdeogramWidth: lastIdeogramWidth,
            lastIdeogramHeight: lastIdeogramHeight,
            lastIdeogramQuantize: lastIdeogramQuantize
        )
        s.customPython = customPythonPath
        s.targetMegapixels = targetMegapixels
        s.rapidTargetMegapixels = rapidTargetMegapixels
        s.ideogram4LowRam = ideogram4LowRam
        s.ideogram4StrictValidation = ideogram4StrictValidation
        s.ideogram4CfgEnd = ideogram4CfgEnd
        s.lastCustomModelRepo = lastCustomModelRepo
        s.lastCustomBaseModel = lastCustomBaseModel
        s.comfyURL = comfyURL
        s.comfyUNet = comfyUNet
        s.comfyClip = comfyClip
        s.comfyVae = comfyVae
        s.comfyBackendEnabled = comfyBackendEnabled
        s.seedVR2Use7B = seedVR2Use7B
        s.seedVR2Quantize = seedVR2Quantize
        s.seedVR2Scale = seedVR2Scale
        s.seedVR2Softness = seedVR2Softness
        s.keepModelWarm = keepModelWarm
        s.warmIdleMinutes = warmIdleMinutes
        s.warmTextEncoderPolicy = warmTextEncoderPolicy
        s.scenarioCategories = scenarioCategories.map(\.rawValue).sorted()
        s.scenarioWildcardMode = scenarioWildcardMode
        s.scenarioQueueCount = scenarioQueueCount
        s.llmBackend = llmBackend
        s.openAIBaseURL = openAIBaseURL
        s.openAIModel = openAIModel
        s.llmTemperature = llmTemperature
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

    /// Whether the library folder exists — on its own drive. The root is never
    /// created implicitly: a path on an unplugged drive would be recreated on
    /// the boot disk (as older builds did, which can leave such a folder behind).
    func libraryRootExists() -> Bool {
        var isDir: ObjCBool = false
        guard !outputDir.isEmpty,
              FileManager.default.fileExists(atPath: outputDir, isDirectory: &isDir),
              isDir.boolValue
        else { return false }
        // Resolved first: `/Volumes/Macintosh HD` is a link to the boot volume.
        let root = URL(fileURLWithPath: outputDir).resolvingSymlinksInPath()
        let volume = try? root.resourceValues(forKeys: [.volumeURLKey]).volume
        return ProfileRules.isOnExpectedVolume(path: root.path, volumePath: volume?.path ?? "/")
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
        if !hfHome.isEmpty {
            env["HF_HOME"] = hfHome
        }
        if !mfluxCacheDir.isEmpty {
            env["MFLUX_CACHE_DIR"] = mfluxCacheDir
        }
        if hfOffline {
            env["HF_HUB_OFFLINE"] = "1"
        }
        if !hfToken.isEmpty {
            env["HF_TOKEN"] = hfToken
        }
        return Toolchain.environment(base: env, cachesURL: Toolchain.cachesURL)
    }
}
