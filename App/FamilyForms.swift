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
}
