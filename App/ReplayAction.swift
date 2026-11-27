import SwiftUI

/// What a replay does with an image's recorded seed: Remix rolls a new one,
/// Apply Settings keeps it.
enum ReplayMode {
    case remix, applySettings
}

/// One replay of an image's settings. Moves the model picker to the family (and
/// custom checkpoint) the sidecar records, arms the picker handlers that move
/// fires so they don't reset the form, then loads the settings into that
/// family's form. An upscale replays the image it was made from. Remix's
/// Generate press is the caller's, and only when this returns true. Holds
/// references only: ``ContentView`` builds one from its state as needed.
struct ReplayAction {
    let forms: FamilyForms
    /// ``ContentView``'s guard on its two picker handlers (``ModelChangeObserver``).
    let suppressedModelObservers: Binding<Set<ModelChangeObserver>>

    /// False, and nothing changes, when the sidecar has nothing to replay: an
    /// upscale whose sidecar predates carrying its source.
    @discardableResult
    func callAsFunction(_ sidecar: AnySidecar, mode: ReplayMode) -> Bool {
        guard let target = sidecar.replayTarget else { return false }
        let newSeed = mode == .remix
        switch target {
        case let .flux(meta):
            // Flux's form holds the picker fields, so its replay moves the picker itself.
            armGuard(model: meta.model, customBase: meta.customBaseModel)
            forms.flux.apply(metadata: meta, newSeed: newSeed)
        case let .ideogram4(meta):
            selectFamily(.ideogram4, customRepo: meta.customModelRepo)
            forms.ideogram4.apply(metadata: meta, newSeed: newSeed)
        case let .krea2(meta):
            selectFamily(.krea2, customRepo: meta.customModelRepo)
            forms.krea2.apply(metadata: meta, newSeed: newSeed)
        case let .zimage(meta):
            selectFamily(meta.resolvedVariant, customRepo: meta.customModelRepo)
            forms.zimage.apply(metadata: meta, newSeed: newSeed)
        case let .qwen21(meta):
            selectFamily(.qwen21Turbo, customRepo: meta.customModelRepo)
            forms.qwen21.apply(metadata: meta, newSeed: newSeed)
        case .seedVR2:
            return false // `replayTarget` is never an upscale.
        }
        return true
    }

    /// Points the picker at `target`, or at `Custom…` loading as `target` when the
    /// image came from a custom checkpoint, so replaying a custom run restores the
    /// checkpoint, not the stock model of the same family.
    private func selectFamily(_ target: FluxModelVariant, customRepo: String?) {
        let repo = customRepo ?? ""
        armGuard(
            model: repo.isEmpty ? target : .custom,
            customBase: repo.isEmpty ? forms.flux.customBaseModel : target
        )
        if repo.isEmpty {
            forms.flux.model = target
        } else {
            forms.flux.customModelRepo = repo
            forms.flux.customBaseModel = target
            forms.flux.model = .custom
        }
    }

    /// Arms the picker handlers that moving to `model`/`customBase` will fire.
    private func armGuard(model: FluxModelVariant, customBase: FluxModelVariant) {
        suppressedModelObservers.wrappedValue = ModelChangeObserver.firing(
            from: (forms.flux.model, forms.flux.customBaseModel),
            to: (model, customBase)
        )
    }
}
