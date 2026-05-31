import Foundation

@Observable
class AppSettings {
    static let appSupportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MLXBits Image Studio", isDirectory: true)
    }()

    private static let settingsURL: URL = appSupportURL.appendingPathComponent("settings.json")

    var mfluxBinaryDir: String       { didSet { save() } }
    var outputDir: String            { didSet { save() } }
    var defaultModel: FluxModelVariant { didSet { save() } }
    var defaultQuantize: Int         { didSet { save() } }
    var defaultBoard: String         { didSet { save() } }
    var defaultWidth: Int            { didSet { save() } }
    var defaultHeight: Int           { didSet { save() } }
    var defaultSteps: Int            { didSet { save() } }
    var defaultGuidance: Double      { didSet { save() } }
    var defaultSeed: Int             { didSet { save() } }
    var defaultLowRam: Bool          { didSet { save() } }
    var defaultLoras: [LoraEntry]    { didSet { save() } }
    var mlxCacheLimitGB: Double      { didSet { save() } }
    var hfHome: String               { didSet { save() } }
    var mfluxCacheDir: String        { didSet { save() } }
    var hfOffline: Bool              { didSet { save() } }
    var logFontSize: Double          { didSet { save() } }

    init() {
        let home = NSHomeDirectory()
        let s = Self.loadStored()
        let model = s.defaultModel ?? .flux2Klein9B

        mfluxBinaryDir  = s.mfluxBinaryDir  ?? BinaryDetector.detectBinaryDir(for: "mflux-generate-flux2")
        outputDir       = s.outputDir       ?? "\(home)/Pictures/MLXBits Image Studio"
        defaultModel    = model
        defaultQuantize = s.defaultQuantize ?? model.recommendedQuantize
        defaultBoard    = s.defaultBoard    ?? "Default"
        defaultWidth    = s.defaultWidth    ?? 1024
        defaultHeight   = s.defaultHeight   ?? 1024
        defaultSteps    = s.defaultSteps    ?? model.defaultSteps
        defaultGuidance = s.defaultGuidance ?? model.defaultGuidance
        defaultSeed     = s.defaultSeed     ?? -1
        defaultLowRam   = s.defaultLowRam   ?? false
        defaultLoras    = s.defaultLoras    ?? []
        mlxCacheLimitGB = s.mlxCacheLimitGB ?? 0
        hfHome          = s.hfHome          ?? ""
        mfluxCacheDir   = s.mfluxCacheDir   ?? ""
        hfOffline       = s.hfOffline       ?? false
        logFontSize     = s.logFontSize     ?? 12.0
    }

    func save() {
        let s = Stored(
            mfluxBinaryDir: mfluxBinaryDir, outputDir: outputDir,
            defaultModel: defaultModel, defaultQuantize: defaultQuantize,
            defaultBoard: defaultBoard, defaultWidth: defaultWidth,
            defaultHeight: defaultHeight, defaultSteps: defaultSteps,
            defaultGuidance: defaultGuidance, defaultSeed: defaultSeed,
            defaultLowRam: defaultLowRam, defaultLoras: defaultLoras,
            mlxCacheLimitGB: mlxCacheLimitGB, hfHome: hfHome,
            mfluxCacheDir: mfluxCacheDir, hfOffline: hfOffline,
            logFontSize: logFontSize
        )
        try? FileManager.default.createDirectory(at: Self.appSupportURL, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(s) { try? data.write(to: Self.settingsURL, options: .atomic) }
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
        if !hfHome.isEmpty        { env["HF_HOME"]           = hfHome }
        if !mfluxCacheDir.isEmpty { env["MFLUX_CACHE_DIR"]   = mfluxCacheDir }
        if hfOffline              { env["HF_HUB_OFFLINE"]    = "1" }
        return env
    }

    // MARK: - Stored

    private static func loadStored() -> Stored {
        guard let data = try? Data(contentsOf: settingsURL) else { return Stored() }
        return (try? JSONDecoder().decode(Stored.self, from: data)) ?? Stored()
    }

    private struct Stored: Codable {
        var mfluxBinaryDir: String?; var outputDir: String?
        var defaultModel: FluxModelVariant?; var defaultQuantize: Int?
        var defaultBoard: String?; var defaultWidth: Int?; var defaultHeight: Int?
        var defaultSteps: Int?; var defaultGuidance: Double?; var defaultSeed: Int?
        var defaultLowRam: Bool?; var defaultLoras: [LoraEntry]?
        var mlxCacheLimitGB: Double?; var hfHome: String?; var mfluxCacheDir: String?
        var hfOffline: Bool?; var logFontSize: Double?

        init() {}
        init(
            mfluxBinaryDir: String, outputDir: String, defaultModel: FluxModelVariant,
            defaultQuantize: Int, defaultBoard: String, defaultWidth: Int, defaultHeight: Int,
            defaultSteps: Int, defaultGuidance: Double, defaultSeed: Int, defaultLowRam: Bool,
            defaultLoras: [LoraEntry], mlxCacheLimitGB: Double, hfHome: String,
            mfluxCacheDir: String, hfOffline: Bool, logFontSize: Double
        ) {
            self.mfluxBinaryDir = mfluxBinaryDir; self.outputDir = outputDir
            self.defaultModel = defaultModel; self.defaultQuantize = defaultQuantize
            self.defaultBoard = defaultBoard; self.defaultWidth = defaultWidth
            self.defaultHeight = defaultHeight; self.defaultSteps = defaultSteps
            self.defaultGuidance = defaultGuidance; self.defaultSeed = defaultSeed
            self.defaultLowRam = defaultLowRam; self.defaultLoras = defaultLoras
            self.mlxCacheLimitGB = mlxCacheLimitGB; self.hfHome = hfHome
            self.mfluxCacheDir = mfluxCacheDir; self.hfOffline = hfOffline
            self.logFontSize = logFontSize
        }
    }
}
