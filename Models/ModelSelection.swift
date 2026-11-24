import Foundation

/// The model the main window will generate with: a model at a precision, or a custom
/// checkpoint and the model it loads as. The model button shows it, and the warm driver
/// compares its ``key`` with the resident model's to light the halo and to evict on a switch.
struct ModelSelection: Equatable {
    /// The selection behind a model picked as `model`: `.custom` means `customRepo`, loading as `customBase`.
    static func picked(
        _ model: FluxModelVariant, quantize: Int, customRepo: String, customBase: FluxModelVariant
    ) -> Self {
        model == .custom
            ? Self(variant: customBase, quantize: quantize, customRepo: customRepo)
            : Self(variant: model, quantize: quantize)
    }

    /// The last path component of a custom repo or path: "my-org/my-finetune" → "my-finetune".
    static func shortName(of repo: String) -> String {
        let trimmed = repo.trimmingCharacters(in: .whitespaces)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// The picked model, or the model a custom checkpoint loads as.
    let variant: FluxModelVariant
    let quantize: Int
    /// The trimmed repo or path of a custom checkpoint, or "" for a built-in model.
    let customRepo: String

    var isCustom: Bool {
        !customRepo.isEmpty
    }

    /// The warm-driver identity. A change of model, precision, custom repo or "loads as" is a
    /// model change. A custom checkpoint carries its own precision, so its key leaves it out.
    var key: String {
        isCustom ? "custom|\(customRepo)|\(variant.rawValue)" : "\(variant.rawValue)|q\(quantize)"
    }

    init(variant: FluxModelVariant, quantize: Int, customRepo: String = "") {
        self.variant = variant
        self.quantize = quantize
        self.customRepo = customRepo.trimmingCharacters(in: .whitespaces)
    }
}

extension FluxJob {
    var selection: ModelSelection {
        .picked(model, quantize: quantize, customRepo: customModelRepo, customBase: customBaseModel)
    }
}

/// The glow around the model button, for the local mflux driver.
enum WarmHalo: Equatable {
    case cold, loading, warm

    /// `selection` is nil when the halo does not apply (the family routes to ComfyUI).
    static func of(selection: String?, loaded: String?, loading: String?) -> Self {
        guard let selection else { return .cold }
        if loading == selection {
            return .loading
        }
        return loaded == selection ? .warm : .cold
    }
}

/// The model button's second line, as pieces the view joins with " · ".
struct ModelButtonCaption: Equatable {
    enum Tone: Equatable {
        case secondary
        case fit(RAMFit)
    }

    struct Segment: Equatable {
        let text: String
        var systemImage: String?
        var tone: Tone = .secondary
    }

    /// What the button knows about the selection. `downloadGB` is nil once the weights are cached.
    struct Input {
        /// The family runs on ComfyUI: no local RAM, download or warm state to show.
        var runsOnComfy = false
        var quantLabel: String
        var overrideRepo: String?
        var customLoadsAs: String?
        var ramGB: Double
        var fit: RAMFit
        var downloadGB: Double?
        var warmGB: Double?
    }

    static func segments(for input: Input) -> [Segment] {
        if input.runsOnComfy {
            return [Segment(text: "runs on ComfyUI")]
        }
        if let repo = input.overrideRepo {
            return [Segment(text: "Override · \(repo)", systemImage: "gearshape")]
        }
        if let target = input.customLoadsAs {
            return [Segment(text: "loads as \(target)")]
        }
        var segments = [Segment(text: input.quantLabel)]
        if let warm = input.warmGB {
            segments.append(Segment(text: String(format: "%.1f GB warm", warm)))
            return segments
        }
        if input.ramGB > 0 {
            segments.append(Segment(text: "≈\(Int(input.ramGB.rounded())) GB RAM", tone: .fit(input.fit)))
        }
        if let download = input.downloadGB {
            segments.append(Segment(text: "\(Int(download.rounded())) GB", systemImage: "arrow.down.circle"))
        }
        return segments
    }
}

/// The model button's chevron menu: the downloaded model × precision pairs, one group per
/// Models window section.
enum ModelSwitchMenu {
    struct Entry: Equatable, Identifiable {
        let model: FluxModelVariant
        /// Nil for a model with a Settings override, whose repo fixes its own precision.
        let quantize: Int?
        let title: String
        let isCurrent: Bool
        /// Why the row is disabled, or nil when it can be picked.
        let unavailableNote: String?

        var id: String {
            "\(model.rawValue)|\(quantize.map(String.init) ?? "override")"
        }
    }

    /// `current` is the selection when it is a built-in model, nil for a custom checkpoint.
    static func groups(
        sections: [ModelSection],
        rows: [FluxModelVariant: ModelRow],
        current: ModelSelection?,
        overridden: Set<FluxModelVariant>
    ) -> [[Entry]] {
        sections.map { section in
            section.models.flatMap { model -> [Entry] in
                guard let row = rows[model] else { return [] }
                let isCurrentModel = current?.variant == model
                // Only the current pair stays enabled when mflux can't run the model.
                let note = { (isCurrent: Bool) in row.toolMissing && !isCurrent ? "not in this mflux install" : nil }
                if overridden.contains(model) {
                    return [
                        Entry(
                            model: model, quantize: nil, title: "\(model.displayName) · Override",
                            isCurrent: isCurrentModel, unavailableNote: note(isCurrentModel)
                        ),
                    ]
                }
                return row.quants.compactMap { status in
                    let isCurrent = isCurrentModel && current?.quantize == status.quantize
                    guard status.cached || isCurrent else { return nil }
                    return Entry(
                        model: model, quantize: status.quantize, title: "\(model.displayName) · \(status.label)",
                        isCurrent: isCurrent, unavailableNote: note(isCurrent)
                    )
                }
            }
        }
        .filter { !$0.isEmpty }
    }
}
