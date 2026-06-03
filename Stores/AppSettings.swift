import Foundation

// MARK: - Per-model defaults

struct ModelDefaults: Codable, Equatable {
    var steps: Int?
    var guidance: Double?
    var quantize: Int?
    var lowRam: Bool?
    var negativePrompt: String?
    var loras: [LoraEntry]?
    var width: Int?
    var height: Int?
    var modelRepoOverride: String?  // HF repo ID or local path; replaces the mflux default when set
}

extension ModelDefaults {
    /// Resolves all values, using global fallbacks for width/height.
    func resolved(for model: FluxModelVariant) -> Resolved {
        Resolved(
            steps:             steps    ?? model.defaultSteps,
            guidance:          model.isDistilled ? 1.0 : (guidance ?? model.defaultGuidance),
            quantize:          quantize ?? model.recommendedQuantize,
            lowRam:            lowRam   ?? false,
            negativePrompt:    model.isDistilled ? "" : (negativePrompt ?? ""),
            loras:             loras    ?? [],
            width:             width    ?? 1024,
            height:            height   ?? 1024,
            modelRepoOverride: modelRepoOverride.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

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
}

// MARK: - AppSettings

@Observable
class AppSettings {
    static let appSupportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MLXBits Image Studio", isDirectory: true)
    }()

    private static let settingsURL: URL = appSupportURL.appendingPathComponent("settings.json")

    // Global
    var mfluxBinaryDir: String        { didSet { save() } }
    var outputDir: String             { didSet { save() } }
    var defaultModel: FluxModelVariant { didSet { save() } }
    var defaultBoard: String          { didSet { save() } }
    var defaultWidth: Int             { didSet { save() } }
    var defaultHeight: Int            { didSet { save() } }
    var defaultLoras: [LoraEntry]     { didSet { save() } }
    var mlxCacheLimitGB: Double       { didSet { save() } }
    var hfHome: String                { didSet { save() } }
    var mfluxCacheDir: String         { didSet { save() } }
    var hfOffline: Bool               { didSet { save() } }
    var hfToken: String               { didSet { KeychainHelper.set(hfToken, key: "hf_token") } }
    var logFontSize: Double           { didSet { save() } }
    var lastPrompt: String            { didSet { save() } }
    var lastWidth: Int                { didSet { save() } }
    var lastHeight: Int               { didSet { save() } }

    /// Per-model overrides, keyed by `FluxModelVariant.rawValue`.
    var modelDefaults: [String: ModelDefaults] { didSet { save() } }

    init() {
        let home = NSHomeDirectory()
        let s = Self.loadStored()
        let model = s.defaultModel ?? .flux2Klein9B

        mfluxBinaryDir  = s.mfluxBinaryDir  ?? BinaryDetector.detectBinaryDir(for: "mflux-generate-flux2")
        outputDir       = s.outputDir       ?? ""   // empty = not yet chosen; app will prompt on first use
        defaultModel    = model
        defaultBoard    = s.defaultBoard    ?? ""
        defaultWidth    = s.defaultWidth    ?? 1024
        defaultHeight   = s.defaultHeight   ?? 1024
        defaultLoras    = s.defaultLoras    ?? []
        mlxCacheLimitGB = s.mlxCacheLimitGB ?? 0
        hfHome          = s.hfHome          ?? ""
        mfluxCacheDir   = s.mfluxCacheDir   ?? ""
        hfOffline       = s.hfOffline       ?? false
        hfToken         = KeychainHelper.get("hf_token")
        logFontSize     = s.logFontSize     ?? 12.0
        lastPrompt      = s.lastPrompt      ?? ""
        lastWidth       = s.lastWidth       ?? 1024
        lastHeight      = s.lastHeight      ?? 1024
        modelDefaults   = s.modelDefaults   ?? [:]
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
            modelDefaults: modelDefaults
        )
        try? FileManager.default.createDirectory(at: Self.appSupportURL, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(s) { try? data.write(to: Self.settingsURL, options: .atomic) }
    }

    // The mflux cache dir: honours user override, otherwise matches mflux's own default
    // (~/Library/Caches/mflux via platformdirs on macOS).
    var effectiveMfluxCacheDir: URL {
        if !mfluxCacheDir.isEmpty {
            return URL(fileURLWithPath: mfluxCacheDir)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("mflux")
    }

    func ensureOutputDirExists() {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDir), withIntermediateDirectories: true)
    }

    func mfluxBinaryPath() -> String {
        BinaryDetector.mfluxGenerateFlux2(in: mfluxBinaryDir)
    }

    func buildEnvironment() -> [String: String] {
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if !hfHome.isEmpty        { env["HF_HOME"]         = hfHome }
        if !mfluxCacheDir.isEmpty { env["MFLUX_CACHE_DIR"] = mfluxCacheDir }
        if hfOffline              { env["HF_HUB_OFFLINE"]  = "1" }
        if !hfToken.isEmpty       { env["HF_TOKEN"]        = hfToken }
        return env
    }

    // MARK: - Stored

    private static func loadStored() -> Stored {
        guard let data = try? Data(contentsOf: settingsURL) else { return Stored() }
        return (try? JSONDecoder().decode(Stored.self, from: data)) ?? Stored()
    }

    private struct Stored: Codable {
        var mfluxBinaryDir: String?; var outputDir: String?
        var defaultModel: FluxModelVariant?
        var defaultBoard: String?; var defaultWidth: Int?; var defaultHeight: Int?
        var defaultLoras: [LoraEntry]?
        var mlxCacheLimitGB: Double?; var hfHome: String?; var mfluxCacheDir: String?
        var hfOffline: Bool?; var logFontSize: Double?; var lastPrompt: String?
        var lastWidth: Int?; var lastHeight: Int?
        var modelDefaults: [String: ModelDefaults]?

        init() {}
        init(
            mfluxBinaryDir: String, outputDir: String, defaultModel: FluxModelVariant,
            defaultBoard: String, defaultWidth: Int, defaultHeight: Int,
            defaultLoras: [LoraEntry],
            mlxCacheLimitGB: Double, hfHome: String, mfluxCacheDir: String,
            hfOffline: Bool, logFontSize: Double, lastPrompt: String,
            lastWidth: Int, lastHeight: Int,
            modelDefaults: [String: ModelDefaults]
        ) {
            self.mfluxBinaryDir = mfluxBinaryDir; self.outputDir = outputDir
            self.defaultModel   = defaultModel
            self.defaultBoard   = defaultBoard; self.defaultWidth = defaultWidth
            self.defaultHeight  = defaultHeight
            self.defaultLoras   = defaultLoras; self.mlxCacheLimitGB = mlxCacheLimitGB
            self.hfHome = hfHome; self.mfluxCacheDir = mfluxCacheDir
            self.hfOffline = hfOffline; self.logFontSize = logFontSize
            self.lastPrompt = lastPrompt; self.lastWidth = lastWidth; self.lastHeight = lastHeight
            self.modelDefaults = modelDefaults
        }
    }
}
