import SwiftUI

struct ModelPickerView: View {
    @Binding var model: FluxModelVariant
    @Binding var customModelRepo: String
    @Binding var customBaseModel: FluxModelVariant
    @Binding var quantize: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Model + quantize row
            HStack(spacing: 6) {
                Picker("Model", selection: $model) {
                    ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                        Text(v.displayName).tag(v)
                    }
                    Divider()
                    Text("Custom…").tag(FluxModelVariant.custom)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Flux model")
                .accessibilityHint("Selects which Flux.2 model variant to use")

                Picker("Precision", selection: $quantize) {
                    Text("BF16").tag(0)
                    Text("Q8").tag(8)
                    Text("Q4").tag(4)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 70)
                .accessibilityLabel("Quantization")
                .accessibilityHint("Controls weight precision. Q8 halves memory use, Q4 quarters it")

                if model != .custom && model.isOnDisk(quantize: quantize) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .accessibilityLabel("Model weights cached on disk")
                }

                InfoButton(
                    title: "Model & Precision",
                    description: "Choose your Flux.2 model variant and weight precision."
                        + " Q8 recommended — cuts memory roughly in half with minimal quality loss."
                        + " Q4 fits smaller Macs but may reduce detail. BF16 is full precision."
                )
            }

            if model == .custom {
                customModelFields
            }

            // Memory + disk estimates
            if let estimate = vramEstimate {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
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
                    Spacer(minLength: 0)
                }
                .accessibilityLabel("Estimated unified memory: \(estimate.label). Disk: \(estimate.diskLabel)")
            }
        }
    }

    // MARK: - Custom model fields

    @ViewBuilder
    private var customModelFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Repo / path").font(.caption2).foregroundStyle(.secondary)
                InfoButton(
                    title: "Custom Model",
                    description: "Enter a HuggingFace repo ID (e.g. org/my-fine-tune) or an"
                        + " absolute local path to a directory containing MLX-format weights."
                        + " Must be compatible with Flux.2 Klein architecture."
                )
            }
            TextField("org/repo or /path/to/model", text: $customModelRepo)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityLabel("Custom model repo or path")

            HStack {
                Text("Base model:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("Base model", selection: $customBaseModel) {
                    ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                        Text(v.displayName).tag(v)
                    }
                }
                .labelsHidden()
                .font(.caption)
                .accessibilityLabel("Base model for custom repo")
                .accessibilityHint("Tells mflux which Flux architecture to use when loading the model")
                InfoButton(
                    title: "Base Model",
                    description: "Specifies the base architecture for your custom model —"
                        + " passed as --base-model. Most Flux.2 fine-tunes are built on Klein 9B."
                )
            }
        }
        .padding(.top, 2)
    }

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

    private var vramEstimate: VRAMEstimate? {
        guard model != .custom else { return nil }
        let sizeGB = model.approximateBF16SizeGB
        let factor: Double = quantize == 4 ? 0.25 : quantize == 8 ? 0.5 : 1.0
        let gb = sizeGB * factor
        guard gb > 0 else { return nil }
        let label = "≈\(String(format: "%.0f", gb)) GB RAM"
        let color: Color = gb > 30 ? .orange : gb > 18 ? .yellow : .green
        let onDisk = model.isOnDisk(quantize: quantize)
        let diskLabel = "≈\(String(format: "%.0f", gb)) GB disk"
        let diskColor: Color = onDisk ? .green : (gb > 30 ? .orange : gb > 18 ? .yellow : .secondary)
        let quantName = quantize == 0 ? "BF16" : "Q\(quantize)"
        let qualityNote: String
        switch quantize {
        case 0:  qualityNote = "Full precision. Highest quality, largest footprint. Best on 64 GB Macs."
        case 8:  qualityNote = "~50% smaller than BF16 with minimal quality loss. Recommended for most users."
        case 4:  qualityNote = "~75% smaller than BF16. Some quality loss but fits Macs with less RAM."
        default: qualityNote = ""
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
}
