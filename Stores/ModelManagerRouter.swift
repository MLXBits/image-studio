import Observation
import SwiftUI

/// Which entry the Models window shows, and the hand-off back to the main window.
@Observable
final class ModelManagerRouter {
    enum Item: Hashable {
        case model(FluxModelVariant)
        case seedVR2
        case gemma
    }

    /// A "Use this" request the main window applies to its model and precision pickers.
    struct UseRequest: Equatable {
        let model: FluxModelVariant
        let quantize: Int
        let id = UUID()
    }

    /// What the main window does with a ``UseRequest``.
    enum UseOutcome: Equatable {
        /// A job is running, so the pickers stay where they are.
        case ignore
        /// The model is already picked: only the precision changes.
        case setQuantize
        /// Move the model picker, then set the precision after its reset to defaults.
        case switchModel
    }

    /// A custom checkpoint has no entry of its own, so it maps to the default model.
    static func item(for model: FluxModelVariant) -> Item {
        .model(model == .custom ? .flux3Klein : model)
    }

    /// The main window's answer to `request` while it shows `currentModel`.
    static func outcome(of request: UseRequest, currentModel: FluxModelVariant, busy: Bool) -> UseOutcome {
        if busy {
            return .ignore
        }
        return request.model == currentModel ? .setQuantize : .switchModel
    }

    var selection: Item? = .model(.flux3Klein)
    var pendingUse: UseRequest?

    func show(_ item: Item, open: OpenWindowAction) {
        selection = item
        open(id: ModelManagerView.windowID)
    }
}
