import SwiftUI

struct ModelPickerView: View {
    // MARK: - VRAM / disk estimate

    private struct VRAMEstimate {
        let label: String
        let color: Color
        let diskLabel: String
        let diskColor: Color
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
            return "Ideogram 4 ships as FP8 (~28 GB, gated)."
                + " Q8 (~27 GB) and Q4 (~15 GB) load pre-quantized MLX weights from MLXBits —"
                + " no Hugging Face token needed for those, and no one-time save step."
                + " FP8 requires accepting terms at huggingface.co/ideogram-ai/ideogram-4-fp8"
                + " plus an HF token in Settings → Advanced."
        }
        return "Choose your Flux.2 model variant and weight precision."
            + " Q8 recommended — cuts memory roughly in half with minimal quality loss."
            + " Q4 fits smaller Macs but may reduce detail. BF16 is full precision."
    }

    var body: some View {
        // Single horizontal row for the top header: model + precision + on-disk +
        // info, then the memory/disk estimate pills inline (beside, not below).
        HStack(spacing: 10) {
            Picker("Model", selection: $model) {
                ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                    Text(v.displayName).tag(v)
                }
                Divider()
                Text("Ideogram 4").tag(FluxModelVariant.ideogram4)
                Divider()
                Text("Custom…").tag(FluxModelVariant.custom)
            }
            .pickerStyle(.menu)
            .labelsHidden()
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
                Picker("Precision", selection: $quantize) {
                    Text(model.baseWeightLabel).tag(0)
                    Text("Q8").tag(8)
                    Text("Q4").tag(4)
                }
                .pickerStyle(.menu)
                .labelsHidden()
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

            if let estimate = vramEstimate {
                estimatePills(estimate)
            }
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
        let color: Color = gb > 30 ? .orange : gb > 18 ? .yellow : .green
        let onDisk = model.isOnDisk(quantize: quantize, savedIn: settings.effectiveMfluxCacheDir)
        let diskLabel = "≈\(String(format: "%.0f", gb)) GB disk"
        let diskColor: Color = onDisk ? .green : (gb > 30 ? .orange : gb > 18 ? .yellow : .secondary)
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
            diskLabel: diskLabel, diskColor: diskColor,
            onDisk: onDisk,
            diskInfoTitle: diskInfoTitle, diskInfoBody: diskInfoBody
        )
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
        Label(estimate.diskLabel, systemImage: "internaldrive")
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
