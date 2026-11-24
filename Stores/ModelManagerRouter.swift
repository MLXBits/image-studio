import Observation
import SwiftUI

/// Which entry the Models window shows, and the hand-off back to the main window.
@Observable
final class ModelManagerRouter {
    enum Item: Hashable {
        case model(FluxModelVariant)
        case custom
        case seedVR2
        case gemma
    }

    /// A custom checkpoint: its repo or path, and the model it loads as.
    struct CustomCheckpoint: Equatable {
        var repo: String
        var loadsAs: FluxModelVariant
    }

    /// A "Use this" request the main window applies to its model and precision.
    struct UseRequest: Equatable {
        let model: FluxModelVariant
        let quantize: Int
        /// Set when `model` is `.custom`.
        var custom: CustomCheckpoint?
        let id = UUID()

        init(model: FluxModelVariant, quantize: Int) {
            self.model = model
            self.quantize = quantize
        }

        init(custom: CustomCheckpoint) {
            model = .custom
            quantize = 0
            self.custom = custom
        }
    }

    /// What the main window does with a ``UseRequest``.
    enum UseOutcome: Equatable {
        /// A job is running, so the selection stays where it is.
        case ignore
        /// The model is already picked: only the precision changes.
        case setQuantize
        /// A custom checkpoint is already picked: only its repo and target change.
        case setCustom
        /// Switch the model, then set the precision after its reset to defaults.
        case switchModel
    }

    /// The Models window entry for `model`: a custom checkpoint has its own.
    static func item(for model: FluxModelVariant) -> Item {
        model == .custom ? .custom : .model(model)
    }

    /// The main window's answer to `request` while it shows `currentModel`.
    static func outcome(of request: UseRequest, currentModel: FluxModelVariant, busy: Bool) -> UseOutcome {
        if busy {
            return .ignore
        }
        guard request.model == currentModel else { return .switchModel }
        return request.custom == nil ? .setQuantize : .setCustom
    }

    var selection: Item? = .model(.flux3Klein)
    var pendingUse: UseRequest?
    /// The main window's custom checkpoint, which the Custom entry starts its draft from.
    var mainCustom = CustomCheckpoint(repo: "", loadsAs: .flux2Klein9B)

    func show(_ item: Item, open: OpenWindowAction) {
        selection = item
        open(id: ModelManagerView.windowID)
    }
}
