import Foundation

/// Every picker family's params form, for one window. ``ContentView`` holds it
/// as state, not ``FamilyRegistry``: a profile switch rebuilds ContentView, and
/// with it these forms from the new profile, while the queues outlive it.
struct FamilyForms {
    let flux = ParamsPanelState()
    let ideogram4 = Ideogram4ParamsPanelState()
    let krea2 = Krea2ParamsPanelState()
    let zimage = ZImageParamsPanelState()
    let qwen21 = Qwen21ParamsPanelState()

    /// One form per picker family, in ``ModelFamily/generative`` order.
    var all: [any FamilyParamsForm] {
        [flux, ideogram4, krea2, zimage, qwen21]
    }

    /// The form the next Generate reads: the family the Flux picker selects
    /// (a custom checkpoint's is the family it loads as).
    var active: (any FamilyParamsForm)? {
        form(for: flux.modelFamily)
    }

    /// Every image a form holds as an img2img source or an edit reference. The
    /// gallery refuses to delete these. Qwen keeps its references in Generate
    /// mode, but only Edit mode uses them.
    var lockedSourcePaths: Set<String> {
        var paths = Set([flux.imagePath, krea2.imagePath, zimage.imagePath].filter { !$0.isEmpty })
        paths.formUnion(flux.editImagePaths)
        if qwen21.isEditMode {
            paths.formUnion(qwen21.editImagePaths)
        }
        return paths
    }

    /// `family`'s form, or nil for SeedVR2, which is never picked.
    func form(for family: ModelFamily) -> (any FamilyParamsForm)? {
        switch family {
        case .flux: flux
        case .ideogram4: ideogram4
        case .krea2: krea2
        case .zimage: zimage
        case .qwen21: qwen21
        case .seedvr2: nil
        }
    }

    /// Sets every family's seed back to random, as the Fixed Seed pill's clear does.
    func clearFixedSeeds() {
        for form in all {
            form.seed = -1
        }
    }

    /// Every family's form as the profile saves it.
    func snapshot() -> LastForms {
        var saved = LastForms()
        saved.flux = flux.snapshot()
        saved.ideogram4 = ideogram4.snapshot()
        saved.krea2 = krea2.snapshot()
        saved.zimage = zimage.snapshot()
        saved.qwen21 = qwen21.snapshot()
        return saved
    }

    /// Follows a LoRA-library edit from `old` to `updated`. Flux keeps its own
    /// stack, with moved paths and new defaults carried in; every other family
    /// takes the library's defaults for it.
    func followLibraryDefaults(from old: [LoraEntry], to updated: [LoraEntry]) {
        let followed = LoraLibraryStore.followingDefaults(flux.loras, from: old, to: updated)
        if followed != flux.loras {
            flux.loras = followed
        }
        for family in ModelFamily.generative where family != .flux {
            form(for: family)?.loras = updated.filter { $0.modelFamily == family }
        }
    }
}

/// What every picker family's params form has, so the window reads the active
/// one without a switch per family. A job, the img2img source, the edit
/// references and the prompt field differ by family, so they stay on the
/// concrete types.
protocol FamilyParamsForm: AnyObject {
    /// -1 is a random seed.
    var seed: Int { get set }
    var board: String { get set }
    var quantize: Int { get set }
    var loras: [LoraEntry] { get set }
    /// Whether the form can queue a job as it is: a prompt, plus a reference
    /// in Edit mode. A scenario batch brings its own prompts, so Generate
    /// checks it separately.
    var canGenerate: Bool { get }
    /// Restores the last-used form, else the Settings → Models defaults.
    func applyDefaults(settings: AppSettings, library: LoraLibraryStore)
}

extension ParamsPanelState: FamilyParamsForm {}
extension Ideogram4ParamsPanelState: FamilyParamsForm {}
extension Krea2ParamsPanelState: FamilyParamsForm {}
extension ZImageParamsPanelState: FamilyParamsForm {}
extension Qwen21ParamsPanelState: FamilyParamsForm {}
