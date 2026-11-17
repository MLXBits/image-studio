import Foundation

/// The two `onChange` handlers in `ContentView` that reset the params form when
/// the model picker moves: one on `params.model`, one on `params.customBaseModel`
/// (which only acts while the picker is on `Custom…`).
///
/// A programmatic change, such as replaying a gallery image's settings or restoring the
/// last-used model at launch, writes the form right after it moves the picker.
/// SwiftUI runs those handlers afterwards, so without suppression their reset
/// would overwrite what was just written. The caller arms the handlers the
/// change will fire. Each handler consumes its own entry once and skips its
/// reset.
enum ModelChangeObserver: Hashable {
    case model
    case customBase

    /// The handlers that moving the picker from `from` to `to` will fire and
    /// that would reset the form. `customBase` only counts when the target is
    /// `Custom…`, because its handler returns early otherwise. Arming a handler
    /// that never fires would swallow the user's next real switch.
    static func firing(
        from: (model: FluxModelVariant, customBase: FluxModelVariant),
        to: (model: FluxModelVariant, customBase: FluxModelVariant)
    ) -> Set<Self> {
        var fired: Set<Self> = []
        if from.model != to.model {
            fired.insert(.model)
        }
        if to.model == .custom, from.customBase != to.customBase {
            fired.insert(.customBase)
        }
        return fired
    }
}
