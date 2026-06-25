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

    /// Non-nil when an Ideogram 4 model-source override is set in Settings.
    /// The override names a specific repo/path, so the precision selector is inert.
    private var ideogramOverride: String? {
        guard model.isIdeogram4 else { return nil }
        let repo = (settings.ideogram4ModelRepoOverride ?? "").trimmingCharacters(in: .whitespaces)
        return repo.isEmpty ? nil : repo
    }

    private var infoDescription: String {
        if let repo = ideogramOverride {
            return "Model source is overridden in Settings → Models → Ideogram (\(repo))."
                + " That repo/path is used as-is, so the precision selector is disabled."
                + " Clear the override in Settings to choose FP8 / Q8 / Q4 again."
        }
        if model.isIdeogram4 {
            return "Ideogram 4 ships as FP8 (~28 GB)."
                + " Q8 (~27 GB) and Q4 (~15 GB) load pre-quantized MLX weights from MLXBits"
                + " with no one-time save step."
                + " All variants are gated — accept terms on the model card and set an HF token"
                + " in Settings → Advanced."
        }
        return "Choose your Flux.2 model variant and weight precision."
            + " Q8 recommended — cuts memory roughly in half with minimal quality loss."
            + " Q4 fits smaller Macs but may reduce detail. BF16 is full precision."
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
                    Divider()
                    modelMenuButton("Custom…", value: .custom)
                } label: {
                    Text(modelMenuLabel)
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityLabel("Model")
                .accessibilityHint("Selects the model for generation")

                if ideogramOverride != nil {
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

                if ideogramOverride == nil, model != .custom,
                   model.isOnDisk(quantize: quantize, savedIn: settings.effectiveMfluxCacheDir) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .accessibilityLabel("Model weights cached on disk")
                }

                InfoButton(title: "Model & Precision", description: infoDescription)

                if model == .custom {
                    customModelFields
                }
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

    private var customModelFields: some View {
        HStack(spacing: 6) {
            TextField("org/repo or /path/to/model", text: $customModelRepo)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(width: 220)
                .accessibilityLabel("Custom model repo or path")
            Text("Base:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Base model", selection: $customBaseModel) {
                ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                    Text(v.displayName).tag(v)
                }
            }
            .labelsHidden()
            .fixedSize()
            .font(.caption)
            .accessibilityLabel("Base model for custom repo")
            .accessibilityHint("Tells mflux which Flux architecture to use when loading the model")
            InfoButton(
                title: "Custom Model",
                description: "Enter a HuggingFace repo ID (e.g. org/my-fine-tune) or an"
                    + " absolute local path to a directory containing MLX-format weights."
                    + " Must be compatible with Flux.2 Klein architecture."
                    + " Base model is passed as --base-model (most fine-tunes use Klein 9B)."
            )
        }
    }

    private var vramEstimate: VRAMEstimate? {
        // A Settings override names an arbitrary repo/path of unknown size — no estimate.
        guard model != .custom, ideogramOverride == nil else { return nil }
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
    private func modelMenuButton(_ title: String, value: FluxModelVariant) -> some View {
        Button {
            model = value
        } label: {
            if model == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
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
