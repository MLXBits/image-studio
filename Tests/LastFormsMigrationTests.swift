import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// PR 9a moves each family's last-used form into one `lastForms` object per
/// profile. A profile saved before it keeps its forms: the old profile keys and
/// the old global keys (frozen in settings.json) build `lastForms` once.
@MainActor
struct LastFormsMigrationTests {
    /// The keys and value types of a real profile saved before PR 9a, with its
    /// text and paths replaced.
    private let legacyProfile = """
    {
      "lastZImage": {"width": 1024, "steps": 9, "negativePrompt": "z-neg", "pidDecode": false, "board": "Z Board",
                     "variant": "z-image-turbo", "imageStrength": 0.75, "pidDegradeSigma": 0, "imagePath": "",
                     "loras": [], "height": 1280, "prompt": "z prompt", "guidance": 3.5, "quantize": 8},
      "promptHistory": [],
      "lastPrompt": "flux prompt",
      "defaultBoard": "Board",
      "customTemplates": [],
      "lastKrea2": {"width": 1152, "steps": 8, "negativePrompt": "", "pidDecode": true, "board": "K Board",
                    "imageStrength": 0.6, "pidDegradeSigma": 0.2, "imagePath": "/out/k.png",
                    "loras": [{"path": "/loras/k.safetensors", "notes": "", "modelFamily": "Krea 2",
                               "strength": 0.8, "enabled": true, "id": "11111111-1111-1111-1111-111111111111"}],
                    "height": 896, "prompt": "krea prompt", "guidance": 1, "quantize": 4},
      "lastIdeogramSeed": 77,
      "lastIdeogramCaption": {
        "compositional_deconstruction": {"background": "bg",
          "elements": [{"bbox": [0, 0, 500, 500], "color_palette": ["#ffffff"], "type": "obj", "desc": "a box"}]},
        "high_level_description": "ideogram caption",
        "style_description": {"lighting": "l", "medium": "m", "photo": "p", "aesthetics": "a", "color_palette": ["#000000"]}
      },
      "lastIdeogramUsePlainPrompt": true,
      "lastScenarioOutline": "outline",
      "notepadText": "notes",
      "lastLoras": [{"id": "22222222-2222-2222-2222-222222222222", "enabled": true, "notes": "", "path": "/loras/f.safetensors",
                     "strength": 0.5, "modelFamily": "FLUX.2"}],
      "lastQwen21": {"steps": 8, "isEditMode": true, "matchReferenceSize": false, "editImagePaths": ["/out/ref.png"],
                     "quantize": 8, "height": 1024, "loras": [], "width": 768, "prompt": "qwen prompt",
                     "board": "Q Board", "enhancePrompt": true},
      "galleryCollapsedBoards": [],
      "activeTemplateIDs": [],
      "lastIdeogramPlainPrompt": "ideogram plain"
    }
    """

    /// The global last-used values settings.json held before PR 9a.
    private let globals = LegacyGlobalForms(
        fluxWidth: 832, fluxHeight: 640, fluxQuantize: 4,
        ideogramPreset: .turbo, ideogramWidth: 512, ideogramHeight: 768, ideogramQuantize: 4
    )

    /// The global keys of a settings.json from before PR 9a.
    private let legacySettings = """
    {"lastWidth": 832, "lastHeight": 640, "lastQuantize": 4, "lastModel": "krea2",
     "lastIdeogramPreset": "V4_TURBO_12", "lastIdeogramWidth": 512, "lastIdeogramHeight": 768,
     "lastIdeogramQuantize": 4, "modelDefaults": {"krea2": {"lowRam": true}}}
    """

    private func decode(_ json: String) throws -> AppSettings.ProfileStored {
        try JSONDecoder().decode(AppSettings.ProfileStored.self, from: Data(json.utf8))
    }

    @Test func aLegacyProfileKeepsEveryFamilysForm() throws {
        let forms = try decode(legacyProfile).resolvedLastForms(globals: globals)

        #expect(forms.flux.prompt == "flux prompt")
        #expect(forms.flux.loras?.map(\.path) == ["/loras/f.safetensors"])
        #expect(forms.flux.width == 832)
        #expect(forms.flux.height == 640)
        #expect(forms.flux.quantize == 4)

        #expect(forms.ideogram4.preset == .turbo)
        #expect(forms.ideogram4.width == 512)
        #expect(forms.ideogram4.height == 768)
        #expect(forms.ideogram4.quantize == 4)
        #expect(forms.ideogram4.caption?.highLevelDescription == "ideogram caption")
        #expect(forms.ideogram4.plainPrompt == "ideogram plain")
        #expect(forms.ideogram4.usePlainPrompt == true)
        #expect(forms.ideogram4.seed == 77)

        #expect(forms.krea2?.prompt == "krea prompt")
        #expect(forms.krea2?.width == 1152)
        #expect(forms.krea2?.quantize == 4)
        #expect(forms.krea2?.loras.map(\.path) == ["/loras/k.safetensors"])
        #expect(forms.zimage?.prompt == "z prompt")
        #expect(forms.zimage?.height == 1280)
        #expect(forms.qwen21?.prompt == "qwen prompt")
        #expect(forms.qwen21?.editImagePaths == ["/out/ref.png"])
    }

    /// A migrated profile writes `lastForms` and none of the keys it replaced.
    @Test func aSavedProfileWritesOnlyLastForms() throws {
        let settings = try settings()
        settings.lastForms = try decode(legacyProfile).resolvedLastForms(globals: globals)
        let data = try JSONEncoder().encode(AppSettings.ProfileStored(snapshotOf: settings))
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(keys.contains("lastForms"))
        let replaced: Set = [
            "lastPrompt", "lastLoras", "lastIdeogramCaption", "lastIdeogramPlainPrompt",
            "lastIdeogramUsePlainPrompt", "lastIdeogramSeed", "lastKrea2", "lastZImage", "lastQwen21",
        ]
        #expect(replaced.isDisjoint(with: keys))

        let reread = try JSONDecoder().decode(AppSettings.ProfileStored.self, from: data)
        let forms = reread.resolvedLastForms(globals: LegacyGlobalForms())
        #expect(forms.flux.width == 832)
        #expect(forms.ideogram4.seed == 77)
        #expect(forms.krea2?.prompt == "krea prompt")
    }

    /// Once a profile has `lastForms`, leftover old keys no longer count.
    @Test func lastFormsWinsOverOldKeys() throws {
        let stored = try decode("""
        {"lastPrompt": "old", "lastForms": {"flux": {"prompt": "new"}}}
        """)
        #expect(stored.resolvedLastForms(globals: globals).flux.prompt == "new")
        #expect(stored.resolvedLastForms(globals: globals).flux.width == nil)
    }

    /// One malformed family entry costs only that family.
    @Test func aMalformedFamilyKeepsTheOthers() throws {
        let stored = try decode("""
        {"lastForms": {"krea2": "oops", "flux": {"prompt": "kept", "width": "wide"}, "qwen21": {"prompt": "q"}}}
        """)
        let forms = stored.resolvedLastForms(globals: globals)
        #expect(forms.krea2 == nil)
        #expect(forms.flux.prompt == "kept")
        #expect(forms.flux.width == nil)
        #expect(forms.qwen21?.prompt == "q")
    }

    /// Settings → Models → Ideogram's defaults start from what it showed before:
    /// the old global last-used values.
    @Test func ideogramDefaultsStartFromTheOldGlobals() {
        let defaults = globals.ideogramDefaults
        #expect(defaults?.width == 512)
        #expect(defaults?.height == 768)
        #expect(defaults?.quantize == 4)
        #expect(LegacyGlobalForms().ideogramDefaults == nil)
    }

    /// A profile made after the upgrade has no old keys, so the frozen globals
    /// must not seed it: its forms start from the Settings → Models defaults.
    @Test func aNewProfileStartsFromTheDefaults() {
        let forms = AppSettings.ProfileStored().resolvedLastForms(globals: globals)
        #expect(forms.flux.width == nil)
        #expect(forms.flux.quantize == nil)
        #expect(forms.ideogram4.preset == nil)
        #expect(forms.ideogram4.width == nil)
    }

    // MARK: - Wiring, through AppSettings

    private func settings(_ json: String? = nil) throws -> AppSettings {
        let stored = try JSONDecoder().decode(AppSettings.Stored.self, from: Data((json ?? legacySettings).utf8))
        let settings = AppSettings(stored: stored)
        settings.suspendPersistence()
        return settings
    }

    private func profileFile(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lastforms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("profile.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// A settings save writes the frozen keys back, so a profile not yet opened
    /// still migrates with them.
    @Test func theOldGlobalsSurviveASettingsSave() throws {
        let saved = try settings().storedSnapshot()
        #expect(saved.lastWidth == 832)
        #expect(saved.lastHeight == 640)
        #expect(saved.lastQuantize == 4)
        #expect(saved.lastIdeogramPreset == .turbo)
        #expect(saved.lastIdeogramWidth == 512)
        #expect(saved.lastIdeogramHeight == 768)
        #expect(saved.lastIdeogramQuantize == 4)
    }

    @Test func ideogramDefaultsAreSeededFromTheOldGlobals() throws {
        let settings = try settings()
        #expect(settings.ideogram4Preset == .turbo)
        #expect(settings.defaults(for: .ideogram4).width == 512)
        #expect(settings.defaults(for: .ideogram4).height == 768)
        #expect(settings.defaults(for: .ideogram4).quantize == 4)
        #expect(settings.storedSnapshot().modelDefaults?[FluxModelVariant.ideogram4.rawValue]?.width == 512)
    }

    /// Once Ideogram has defaults of its own, the old globals no longer touch them.
    @Test func savedIdeogramDefaultsAreKept() throws {
        let settings = try settings("""
        {"lastIdeogramWidth": 512, "lastIdeogramPreset": "V4_TURBO_12", "ideogram4Preset": "V4_QUALITY_48",
         "modelDefaults": {"ideogram4": {"width": 640}}}
        """)
        #expect(settings.ideogram4Preset == .quality)
        #expect(settings.defaults(for: .ideogram4).width == 640)
    }

    /// Opening two old profiles, one after the other, migrates both with the globals.
    @Test func activatingOldProfilesMigratesEachWithTheGlobals() throws {
        let settings = try settings()
        try settings.activateProfile(contentURL: profileFile(legacyProfile), libraryPath: "")
        #expect(settings.lastForms.flux.prompt == "flux prompt")
        #expect(settings.lastForms.flux.width == 832)
        #expect(settings.lastForms.ideogram4.preset == .turbo)
        try settings.activateProfile(contentURL: profileFile(#"{"lastPrompt": "second"}"#), libraryPath: "")
        #expect(settings.lastForms.flux.prompt == "second")
        #expect(settings.lastForms.flux.width == 832)
        #expect(settings.lastForms.krea2 == nil)
    }

    /// A family with nothing saved starts from Settings → Models; a saved value wins.
    @Test func eachFormFallsBackToItsDefaults() throws {
        let settings = try settings()
        let library = LoraLibraryStore()
        let ideogram = Ideogram4ParamsPanelState()
        ideogram.applyDefaults(settings: settings, library: library)
        #expect(ideogram.preset == .turbo)
        #expect(ideogram.width == 512)
        #expect(ideogram.quantize == 4)
        settings.lastForms.ideogram4.width = 900
        ideogram.applyDefaults(settings: settings, library: library)
        #expect(ideogram.width == 900)

        let flux = ParamsPanelState()
        flux.applyDefaults(settings: settings, library: library)
        let d = settings.resolvedDefaults(for: settings.lastModel)
        #expect(flux.quantize == d.quantize)
        #expect(flux.width == d.width)
        settings.lastForms.flux.quantize = 4
        settings.lastForms.flux.width = 640
        flux.applyDefaults(settings: settings, library: library)
        #expect(flux.quantize == 4)
        #expect(flux.width == 640)
    }

    /// Profile switches and launches save every family's form, not only the prompts.
    @Test func theFormsSnapshotEveryFamily() {
        let forms = FamilyForms()
        forms.flux.prompt = "f"
        forms.flux.width = 640
        forms.ideogram4.preset = .quality
        forms.ideogram4.seed = 5
        forms.krea2.prompt = "k"
        forms.zimage.prompt = "z"
        forms.qwen21.prompt = "q"
        let saved = forms.snapshot()
        #expect(saved.flux.prompt == "f")
        #expect(saved.flux.width == 640)
        #expect(saved.ideogram4.preset == .quality)
        #expect(saved.ideogram4.seed == 5)
        #expect(saved.krea2?.prompt == "k")
        #expect(saved.zimage?.prompt == "z")
        #expect(saved.qwen21?.prompt == "q")
    }
}
