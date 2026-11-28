import Foundation

/// Every picker family's last-used form, saved per profile as `lastForms` in
/// `profile.json`. The keys are on disk: never rename one. Each family decodes
/// on its own, so a malformed entry costs only that family.
///
/// Krea 2, Z-Image and Qwen keep their nil for "never saved", so their forms
/// fall back to the Settings → Models defaults. Flux's and Ideogram's states
/// hold optionals field by field for the same reason.
struct LastForms: Codable {
    var flux = FluxFormState()
    var ideogram4 = Ideogram4FormState()
    var krea2: Krea2FormState?
    var zimage: ZImageFormState?
    var qwen21: Qwen21FormState?

    init() {}

    /// The forms of a profile saved before `lastForms`: its own old keys, plus the
    /// global values settings.json held then.
    init(legacyProfile p: AppSettings.ProfileStored, globals g: LegacyGlobalForms) {
        flux = FluxFormState(
            prompt: p.lastPrompt, loras: p.lastLoras, width: g.fluxWidth, height: g.fluxHeight, quantize: g.fluxQuantize
        )
        ideogram4 = Ideogram4FormState(
            preset: g.ideogramPreset, width: g.ideogramWidth, height: g.ideogramHeight, quantize: g.ideogramQuantize,
            caption: p.lastIdeogramCaption, plainPrompt: p.lastIdeogramPlainPrompt,
            usePlainPrompt: p.lastIdeogramUsePlainPrompt, seed: p.lastIdeogramSeed
        )
        krea2 = p.lastKrea2
        zimage = p.lastZImage
        qwen21 = p.lastQwen21
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flux = (try? c.decode(FluxFormState.self, forKey: .flux)) ?? FluxFormState()
        ideogram4 = (try? c.decode(Ideogram4FormState.self, forKey: .ideogram4)) ?? Ideogram4FormState()
        krea2 = try? c.decode(Krea2FormState.self, forKey: .krea2)
        zimage = try? c.decode(ZImageFormState.self, forKey: .zimage)
        qwen21 = try? c.decode(Qwen21FormState.self, forKey: .qwen21)
    }
}

/// Flux's last-used form. The picked model and the custom checkpoint are global
/// (``AppSettings/lastModel``), so switching profile doesn't change the model.
struct FluxFormState: Codable {
    var prompt: String?
    var loras: [LoraEntry]?
    var width: Int?
    var height: Int?
    var quantize: Int?

    init(prompt: String? = nil, loras: [LoraEntry]? = nil, width: Int? = nil, height: Int? = nil, quantize: Int? = nil) {
        self.prompt = prompt
        self.loras = loras
        self.width = width
        self.height = height
        self.quantize = quantize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try? c.decode(String.self, forKey: .prompt)
        loras = try? c.decode([LoraEntry].self, forKey: .loras)
        width = try? c.decode(Int.self, forKey: .width)
        height = try? c.decode(Int.self, forKey: .height)
        quantize = try? c.decode(Int.self, forKey: .quantize)
    }
}

/// Ideogram 4's last-used form. Its preset, size and precision fall back to the
/// Settings → Models → Ideogram defaults when unsaved.
struct Ideogram4FormState: Codable {
    var preset: Ideogram4Preset?
    var width: Int?
    var height: Int?
    var quantize: Int?
    var caption: IdeogramCaption?
    var plainPrompt: String?
    var usePlainPrompt: Bool?
    var seed: Int?

    init(
        preset: Ideogram4Preset? = nil, width: Int? = nil, height: Int? = nil, quantize: Int? = nil,
        caption: IdeogramCaption? = nil, plainPrompt: String? = nil, usePlainPrompt: Bool? = nil, seed: Int? = nil
    ) {
        self.preset = preset
        self.width = width
        self.height = height
        self.quantize = quantize
        self.caption = caption
        self.plainPrompt = plainPrompt
        self.usePlainPrompt = usePlainPrompt
        self.seed = seed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try? c.decode(Ideogram4Preset.self, forKey: .preset)
        width = try? c.decode(Int.self, forKey: .width)
        height = try? c.decode(Int.self, forKey: .height)
        quantize = try? c.decode(Int.self, forKey: .quantize)
        caption = (try? c.decode(LenientIdeogramCaption.self, forKey: .caption))?.caption
        plainPrompt = try? c.decode(String.self, forKey: .plainPrompt)
        usePlainPrompt = try? c.decode(Bool.self, forKey: .usePlainPrompt)
        seed = try? c.decode(Int.self, forKey: .seed)
    }
}

/// The global last-used values settings.json held before `lastForms`. They stay
/// there, frozen, so a profile not opened since still migrates with them.
struct LegacyGlobalForms {
    var fluxWidth: Int?
    var fluxHeight: Int?
    var fluxQuantize: Int?
    var ideogramPreset: Ideogram4Preset?
    var ideogramWidth: Int?
    var ideogramHeight: Int?
    var ideogramQuantize: Int?

    /// Settings → Models → Ideogram's defaults before any are saved: what that
    /// form edited until now, or nil when nothing was ever set.
    var ideogramDefaults: ModelDefaults? {
        guard ideogramWidth != nil || ideogramHeight != nil || ideogramQuantize != nil else { return nil }
        return ModelDefaults(quantize: ideogramQuantize, width: ideogramWidth, height: ideogramHeight)
    }
}
