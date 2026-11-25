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
    let params: ParamsPanelState
    let ideogramParams: Ideogram4ParamsPanelState
    let krea2Params: Krea2ParamsPanelState
    let zimageParams: ZImageParamsPanelState
    let qwen21Params: Qwen21ParamsPanelState
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
            params.apply(metadata: meta, newSeed: newSeed)
        case let .ideogram4(meta):
            selectFamily(.ideogram4, customRepo: meta.customModelRepo)
            ideogramParams.apply(metadata: meta, newSeed: newSeed)
        case let .krea2(meta):
            selectFamily(.krea2, customRepo: meta.customModelRepo)
            krea2Params.apply(metadata: meta, newSeed: newSeed)
        case let .zimage(meta):
            selectFamily(meta.resolvedVariant, customRepo: meta.customModelRepo)
            zimageParams.apply(metadata: meta, newSeed: newSeed)
        case let .qwen21(meta):
            selectFamily(.qwen21Turbo, customRepo: meta.customModelRepo)
            qwen21Params.apply(metadata: meta, newSeed: newSeed)
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
            customBase: repo.isEmpty ? params.customBaseModel : target
        )
        if repo.isEmpty {
            params.model = target
        } else {
            params.customModelRepo = repo
            params.customBaseModel = target
            params.model = .custom
        }
    }

    /// Arms the picker handlers that moving to `model`/`customBase` will fire.
    private func armGuard(model: FluxModelVariant, customBase: FluxModelVariant) {
        suppressedModelObservers.wrappedValue = ModelChangeObserver.firing(
            from: (params.model, params.customBaseModel),
            to: (model, customBase)
        )
    }
}
