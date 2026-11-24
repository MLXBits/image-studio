import SwiftUI

/// The header's model button: which model and precision the next job uses, whether it is
/// warm, and the way into the Models window. A split button, built like Generate: the main
/// segment opens the Models window, the chevron switches between downloaded models. The
/// eject button beside it unloads the warm model.
struct ModelButton: View {
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 320

    let model: FluxModelVariant
    let customRepo: String
    let customBase: FluxModelVariant
    let quantize: Int
    /// The selected family runs on ComfyUI, where the local warm driver plays no part.
    let routesToComfy: Bool
    /// A job is running: the chevron's rows are disabled, as **Use** is.
    let busy: Bool
    let onOpen: () -> Void
    let onUse: (ModelManagerRouter.UseRequest) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(MfluxDriverController.self) private var driver
    @Environment(WeightDownloadStore.self) private var weightDownloads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCustom: Bool {
        model == .custom
    }

    private var selection: ModelSelection {
        .picked(model, quantize: quantize, customRepo: customRepo, customBase: customBase)
    }

    private var halo: WarmHalo {
        WarmHalo.of(
            selection: routesToComfy ? nil : selection.key,
            loaded: driver.loadedSelectionKey,
            loading: driver.loadingSelectionKey
        )
    }

    private var quantLabel: String {
        quantize == 0 ? model.baseWeightLabel : "Q\(quantize)"
    }

    private var caption: [ModelButtonCaption.Segment] {
        let ramGB = model.approximateRAMGB(quantize: quantize, settings: settings)
        let onDisk = model.isOnDisk(quantize: quantize, savedIn: settings.effectiveMfluxCacheDir, hubDir: settings.hfHubDir)
        return ModelButtonCaption.segments(for: .init(
            quantLabel: quantLabel,
            overrideRepo: settings.modelSourceOverride(for: model),
            customLoadsAs: isCustom ? customBase.displayName : nil,
            ramGB: ramGB,
            fit: RAMFit.of(ramGB: ramGB, physicalGB: RAMFit.physicalGB),
            downloadGB: onDisk ? nil : model.approximateSizeGB(quantize: quantize),
            warmGB: halo == .warm ? driver.loadedMemoryGB : nil
        ))
    }

    var body: some View {
        // Reading the revision re-checks the cached flags when a download or removal finishes.
        let _ = weightDownloads.revision // swiftlint:disable:this redundant_discardable_let
        HStack(spacing: 6) {
            splitButton
            if driver.isLoaded {
                Button { driver.eject() } label: {
                    Image(systemName: "eject.fill").font(.caption)
                }
                .buttonStyle(.iconButton)
                .disabled(driver.isGenerating)
                .help(driver.isGenerating ? "Generating — cannot eject" : "Eject warm model")
                .accessibilityLabel("Eject warm model")
            }
        }
    }

    // MARK: - Split button

    private var splitButton: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                // Grows with the name between the two widths; past the maximum, the name truncates.
                CappedWidth(maxWidth: Self.maxWidth - IconButtonMetrics.size - 1) {
                    mainLabel
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(minWidth: Self.minWidth - IconButtonMetrics.size - 1, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Models: learn about, download and pick models")
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens the Models window")

            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 22)

            Menu {
                switchMenu
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .iconMenuLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch to a downloaded model")
            .accessibilityLabel("Switch to a downloaded model")
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.fill.quaternary))
        .modifier(HaloModifier(halo: halo, reduceMotion: reduceMotion))
    }

    private var mainLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            title
            captionLine
        }
    }

    @ViewBuilder private var title: some View {
        if isCustom {
            HStack(spacing: 0) {
                Text("Custom · ").fixedSize()
                Text(customRepo.isEmpty ? "no repo" : ModelSelection.shortName(of: customRepo))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
        } else {
            Text(model.displayName).lineLimit(1)
        }
    }

    private var captionLine: some View {
        let segments = caption
        return HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text("·")
                }
                HStack(spacing: 2) {
                    if let image = segment.systemImage {
                        Image(systemName: image)
                    }
                    Text(segment.text).truncationMode(.middle)
                }
                .foregroundStyle(color(for: segment.tone))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var accessibilityText: String {
        let repo = ModelSelection.shortName(of: customRepo)
        let name = isCustom ? "Custom, \(repo.isEmpty ? "no repo" : repo)" : model.displayName
        let state = switch halo {
        case .warm: "warm"
        case .loading: "loading"
        case .cold: "not loaded"
        }
        let details = caption.map(\.text).joined(separator: ", ")
        return "Model, \(name), \(details), \(state)"
    }

    // MARK: - Chevron menu

    @ViewBuilder private var switchMenu: some View {
        let groups = ModelSwitchMenu.groups(
            sections: ModelInventory.sections,
            rows: Dictionary(uniqueKeysWithValues: ModelInventory.sections.flatMap(\.models).map {
                ($0, settings.inventoryRow(for: $0))
            }),
            current: isCustom ? nil : selection,
            overridden: Set(FluxModelVariant.allModels.filter { settings.modelSourceOverride(for: $0) != nil })
        )
        if groups.isEmpty && customRepo.isEmpty {
            Text("No models downloaded")
        }
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 {
                Divider()
            }
            ForEach(group) { entry in
                Toggle(isOn: Binding(get: { entry.isCurrent }, set: { _ in pick(entry) })) {
                    Text(entry.unavailableNote.map { "\(entry.title) — \($0)" } ?? entry.title)
                }
                .disabled(busy || entry.unavailableNote != nil)
            }
        }
        // A set repo, or the current selection: Custom without a repo, whose row opens its pane.
        let repoName = ModelSelection.shortName(of: customRepo)
        if isCustom || !repoName.isEmpty {
            Divider()
            Toggle(isOn: Binding(get: { isCustom }, set: { _ in repoName.isEmpty ? onOpen() : pickCustom() })) {
                Text("Custom · \(repoName.isEmpty ? "no repo" : repoName)")
            }
            .disabled(busy && !repoName.isEmpty)
        }
        Divider()
        Button("Models…", action: onOpen)
    }

    private func color(for tone: ModelButtonCaption.Tone) -> Color {
        switch tone {
        case .secondary: .secondary
        case let .fit(fit): fit.color
        }
    }

    private func pick(_ entry: ModelSwitchMenu.Entry) {
        // An overridden model keeps the current precision: its repo fixes its own.
        onUse(.init(model: entry.model, quantize: entry.quantize ?? quantize))
    }

    private func pickCustom() {
        onUse(.init(custom: .init(repo: customRepo, loadsAs: customBase)))
    }
}

/// Proposes at most `maxWidth` to its one subview and takes the subview's size: a cap that,
/// unlike `.frame(maxWidth:)`, never stretches the content to the cap.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(capped(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: capped(ProposedViewSize(width: bounds.width, height: bounds.height)))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }
}

/// The accent glow around the model button: steady while warm, pulsing while loading
/// (a steady, dimmer glow under Reduce Motion), none while cold.
private struct HaloModifier: ViewModifier {
    let halo: WarmHalo
    let reduceMotion: Bool

    /// The glow's strengths to cycle through: two while pulsing, one when steady. One shape for
    /// every state, so a change of state never rebuilds the button it wraps.
    private var strengths: [Double] {
        switch halo {
        case .cold: [0]
        case .warm: [1]
        case .loading: reduceMotion ? [0.5] : [0.25, 1]
        }
    }

    func body(content: Content) -> some View {
        content.phaseAnimator(strengths) { view, strength in
            view
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.7 * strength), lineWidth: 1))
                .shadow(color: Color.accentColor.opacity(0.55 * strength), radius: 6)
                .shadow(color: Color.accentColor.opacity(0.3 * strength), radius: 12)
        } animation: { _ in
            .easeInOut(duration: 0.9)
        }
    }
}
