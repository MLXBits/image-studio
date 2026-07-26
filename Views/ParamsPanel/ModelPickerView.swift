import SwiftUI

struct ModelPickerView: View {
    // MARK: - VRAM / disk estimate

    private struct VRAMEstimate {
        let label: String
        let color: Color
        let diskLabel: String
        let diskColor: Color
        let diskIcon: String
        let onDisk: Bool
        let diskInfoTitle: String
        let diskInfoBody: String
    }

    @Binding var model: FluxModelVariant
    @Binding var customModelRepo: String
    @Binding var customBaseModel: FluxModelVariant
    @Binding var quantize: Int
    @Environment(AppSettings.self) private var settings

    /// Non-nil when a model-source override is set in Settings for the selected
    /// model. The override names a specific repo/path carrying its own
    /// quantization, so the precision selector is inert. Ideogram keeps its own
    /// dedicated setting; every other family uses the per-model default.
    private var settingsOverride: String? {
        guard model != .custom else { return nil }
        let repo = model.isIdeogram4
            ? (settings.ideogram4ModelRepoOverride ?? "")
            : (settings.defaults(for: model).modelRepoOverride ?? "")
        let trimmed = repo.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var infoDescription: String {
        if let repo = settingsOverride {
            return "Model source is overridden in Settings → Models → \(model.displayName) (\(repo))."
                + " That repo/path is used as-is, so the precision selector is disabled."
                + " Clear the override in Settings to choose precision again."
        }
        if model.isIdeogram4 {
            return "Ideogram 4 ships as FP8 (~28 GB)."
                + " Q8 (~27 GB) and Q4 (~15 GB) load pre-quantized MLX weights from MLXBits"
                + " with no one-time save step."
                + " All variants are gated — accept terms on the model card and set an HF token"
                + " in Settings → Advanced."
        }
        return "Choose your model and weight precision."
            + " Q8 recommended — cuts memory roughly in half with minimal quality loss."
            + " Q4 fits smaller Macs but may reduce detail."
            + " \(model.baseWeightLabel) is full precision."
    }

    var body: some View {
        // Top header: selectors on the first row, memory/disk estimate pills
        // below them on a second row.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // A `Menu` (vs `Picker(.menu)`) renders as a pull-down: the menu
                // always anchors below the button and lists every item from the
                // top, regardless of which is selected. A popup Picker instead
                // aligns the selected row to the button, which pushed the Flux
                // variants off-screen when Ideogram (near the list bottom) was
                // selected. Checkmarks below preserve the selection indicator.
                Menu {
                    ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                        modelMenuButton(v.displayName, value: v)
                    }
                    Divider()
                    modelMenuButton("Ideogram 4", value: .ideogram4)
                    modelMenuButton("Krea 2 Turbo", value: .krea2)
                    modelMenuButton("Z-Image Turbo", value: .zimageTurbo)
                    modelMenuButton("Z-Image", value: .zimage)
                    Divider()
                    modelMenuButton("Custom…", value: .custom)
                } label: {
                    Text(modelMenuLabel)
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityLabel("Model")
                .accessibilityHint("Selects the model for generation")

                if settingsOverride != nil {
                    Label("Override", systemImage: "gearshape")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Model source overridden in Settings")
                } else if model != .custom {
                    // Pull-down Menu to match the Model selector above (a popup
                    // Picker would align the selected row to the button instead).
                    Menu {
                        precisionMenuButton(model.baseWeightLabel, value: 0)
                        precisionMenuButton("Q8", value: 8)
                        precisionMenuButton("Q4", value: 4)
                    } label: {
                        Text(precisionMenuLabel)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .accessibilityLabel("Quantization")
                    .accessibilityHint("Controls weight precision. Q8 halves memory use, Q4 quarters it")
                }

                if settingsOverride == nil, model != .custom,
                   model.isOnDisk(quantize: quantize, savedIn: settings.effectiveMfluxCacheDir) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .accessibilityLabel("Model weights cached on disk")
                }

                // Custom has no precision selector and carries its own info button
                // on the row below, so this one would only duplicate it.
                if model != .custom {
                    InfoButton(title: "Model & Precision", description: infoDescription)
                }

                if model == .custom {
                    customRepoField
                }
            }

            // Second row: the repo field alone already fills the header, so the
            // target picker sits under it rather than crowding Generate.
            if model == .custom {
                customTargetRow
            }

            if let estimate = vramEstimate {
                HStack(spacing: 8) {
                    estimatePills(estimate)
                }
            }
        }
    }

    // MARK: - Model menu

    /// Label shown on the closed Model menu button.
    private var modelMenuLabel: String {
        switch model {
        case .custom: "Custom…"
        default: model.displayName
        }
    }

    /// Label shown on the closed Precision menu button.
    private var precisionMenuLabel: String {
        switch quantize {
        case 8: "Q8"
        case 4: "Q4"
        default: model.baseWeightLabel
        }
    }

    // MARK: - Custom model fields (inline)

    /// Models a custom checkpoint can be loaded as: those the installed mflux
    /// ships a generation CLI for. Falls back to the full list while mflux is
    /// still being installed (nothing detected yet) so the picker is never empty,
    /// and always keeps the current selection so it can't render blank.
    private var customTargets: [FluxModelVariant] {
        let available = settings.availableModels
        guard !available.isEmpty else { return FluxModelVariant.allModels }
        return available.contains(customBaseModel) ? available : available + [customBaseModel]
    }

    private var customRepoField: some View {
        TextField("org/repo or /path/to/model", text: $customModelRepo)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .frame(width: 220)
            .accessibilityLabel("Custom model repo or path")
    }

    private var customTargetRow: some View {
        HStack(spacing: 6) {
            Text("Loads as:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Loads as", selection: $customBaseModel) {
                ForEach(customTargets, id: \.self) { v in
                    Text(v.displayName).tag(v)
                }
            }
            .labelsHidden()
            .fixedSize()
            .font(.caption)
            .accessibilityLabel("Model the custom checkpoint loads as")
            .accessibilityHint("Selects the pipeline, params panel and mflux CLI used to run it")
            InfoButton(
                title: "Custom Model",
                description: "Enter a HuggingFace repo ID (e.g. org/my-fine-tune) or an"
                    + " absolute local path to a directory containing MLX-format weights."
                    + " \"Loads as\" tells the app which pipeline to run it through, so the"
                    + " checkpoint must match that model's architecture — a Krea 2 fine-tune"
                    + " loads as Krea 2, a Flux.2 one as a Klein variant (passed as"
                    + " --base-model; most fine-tunes use Klein 9B)."
                    + " Only models the installed mflux ships a CLI for are listed."
            )
        }
    }

    private var vramEstimate: VRAMEstimate? {
        // A Settings override names an arbitrary repo/path of unknown size — no estimate.
        guard model != .custom, settingsOverride == nil else { return nil }
        let gb = model.approximateSizeGB(quantize: quantize)
        guard gb > 0 else { return nil }
        let label = "≈\(String(format: "%.0f", gb)) GB RAM"
        // Color relative to this machine's physical memory, not fixed GB cutoffs:
        // green with comfortable headroom for activations + OS, yellow when tight,
        // orange when it likely won't fit, red when it almost certainly won't.
        let totalRAMGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let ramFraction = totalRAMGB > 0 ? gb / totalRAMGB : 1.0
        let color: Color = switch ramFraction {
        case ..<0.6: .green
        case ..<0.8: .yellow
        case ..<0.9: .orange
        default: .red
        }
        let onDisk = model.isOnDisk(quantize: quantize, savedIn: settings.effectiveMfluxCacheDir)
        // The disk pill is a binary download-state signal — green when cached,
        // neutral "download" otherwise. Size-based warning colors live on the RAM
        // pill only, so a not-yet-downloaded model never looks like a warning.
        let diskLabel = onDisk
            ? "≈\(String(format: "%.0f", gb)) GB cached"
            : "≈\(String(format: "%.0f", gb)) GB to download"
        let diskColor: Color = onDisk ? .green : .secondary
        let diskIcon = onDisk ? "internaldrive" : "arrow.down.circle"
        let quantName = quantize == 0 ? model.baseWeightLabel : "Q\(quantize)"
        let qualityNote = switch quantize {
        case 0: "Full precision. Highest quality, largest footprint. Best on 64 GB Macs."
        case 8: "~50% smaller than BF16 with minimal quality loss. Recommended for most users."
        case 4: "~75% smaller than BF16. Some quality loss but fits Macs with less RAM."
        default: ""
        }
        let diskInfoTitle = "\(model.displayName) \(quantName)"
        let diskInfoBody = "\(quantName) weights cached locally (~\(Int(gb)) GB). \(qualityNote)"
        return VRAMEstimate(
            label: label, color: color,
            diskLabel: diskLabel, diskColor: diskColor, diskIcon: diskIcon,
            onDisk: onDisk,
            diskInfoTitle: diskInfoTitle, diskInfoBody: diskInfoBody
        )
    }

    /// A menu row that selects `value` and shows a checkmark when active.
    /// A model menu row. Rows whose generation CLI is missing from the selected
    /// mflux install are disabled and say so, rather than being silently dropped
    /// (reads as a bug) or left selectable (fails at spawn time). mflux adds CLIs
    /// between releases and the app installs it unpinned, so this varies per
    /// install — e.g. `mflux-generate-krea2` postdates the current PyPI release.
    private func modelMenuButton(_ title: String, value: FluxModelVariant) -> some View {
        let available = settings.supportsModel(value)
        return Button {
            model = value
        } label: {
            if model == value {
                Label(title, systemImage: "checkmark")
            } else if available {
                Text(title)
            } else {
                Text("\(title) — not in this mflux install")
            }
        }
        .disabled(!available && model != value)
    }

    /// A precision menu row that selects `value` and shows a checkmark when active.
    private func precisionMenuButton(_ title: String, value: Int) -> some View {
        Button {
            quantize = value
        } label: {
            if quantize == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: - Estimate pills (inline, beside the selector)

    @ViewBuilder
    private func estimatePills(_ estimate: VRAMEstimate) -> some View {
        Label(estimate.label, systemImage: "memorychip")
            .font(.caption2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(estimate.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(estimate.color.opacity(0.12), in: Capsule())
        Label(estimate.diskLabel, systemImage: estimate.diskIcon)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(estimate.diskColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(estimate.diskColor.opacity(0.12), in: Capsule())
        if estimate.onDisk, let diskURL = model.onDiskURL(quantize: quantize) {
            InfoButton(
                title: estimate.diskInfoTitle,
                description: estimate.diskInfoBody,
                actionLabel: "Reveal in Finder"
            ) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: diskURL.path) }
        }
    }
}
