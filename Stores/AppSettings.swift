import Foundation

// MARK: - Per-model defaults

struct ModelDefaults: Codable, Equatable {
    struct Resolved {
        let steps: Int
        let guidance: Double
        let quantize: Int
        let lowRam: Bool
        let negativePrompt: String
        let loras: [LoraEntry]
        let width: Int
        let height: Int
        let modelRepoOverride: String?
    }

    var steps: Int?
    var guidance: Double?
    var quantize: Int?
    var lowRam: Bool?
    var negativePrompt: String?
    var loras: [LoraEntry]?
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
            loras: loras ?? [],
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
            batchShortcutPreset: Int, batchShortcutCustomCount: Int
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
        }
    }

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

    var defaultLoras: [LoraEntry] {
        didSet { save() }
    }

    var mlxCacheLimitGB: Double {
        didSet { save() }
    }

    var hfHome: String {
        didSet { save() }
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

    /// Per-model overrides, keyed by `FluxModelVariant.rawValue`.
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
        defaultLoras = s.defaultLoras ?? []
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

    // MARK: - Persistence

    func save() {
        let s = Stored(
            mfluxBinaryDir: mfluxBinaryDir, outputDir: outputDir,
            defaultModel: defaultModel, defaultBoard: defaultBoard,
            defaultWidth: defaultWidth, defaultHeight: defaultHeight,
            defaultLoras: defaultLoras,
            mlxCacheLimitGB: mlxCacheLimitGB, hfHome: hfHome,
            mfluxCacheDir: mfluxCacheDir, hfOffline: hfOffline,
            logFontSize: logFontSize, lastPrompt: lastPrompt,
            lastWidth: lastWidth, lastHeight: lastHeight,
            lastLoras: lastLoras, modelDefaults: modelDefaults,
            lastModel: lastModel, lastQuantize: lastQuantize,
            customTemplates: customTemplates, activeTemplateIDs: activeTemplateIDs,
            batchShortcutPreset: batchShortcutPreset,
            batchShortcutCustomCount: batchShortcutCustomCount
        )
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

    func buildEnvironment() -> [String: String] {
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if !hfHome.isEmpty { env["HF_HOME"] = hfHome }
        if !mfluxCacheDir.isEmpty { env["MFLUX_CACHE_DIR"] = mfluxCacheDir }
        if hfOffline { env["HF_HUB_OFFLINE"] = "1" }
        if !hfToken.isEmpty { env["HF_TOKEN"] = hfToken }
        return env
    }
}
