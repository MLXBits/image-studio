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
