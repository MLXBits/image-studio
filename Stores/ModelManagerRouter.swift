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

    /// A custom checkpoint has no entry of its own, so it maps to the default model.
    static func item(for model: FluxModelVariant) -> Item {
        .model(model == .custom ? .flux3Klein : model)
    }

    var selection: Item? = .model(.flux3Klein)
    var pendingUse: UseRequest?

    func show(_ item: Item, open: OpenWindowAction) {
        selection = item
        open(id: ModelManagerView.windowID)
    }
}
