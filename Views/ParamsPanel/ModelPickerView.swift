import SwiftUI

struct ModelPickerView: View {
    @Binding var model: FluxModelVariant
    @Binding var customModelRepo: String
    @Binding var customBaseModel: FluxModelVariant
    @Binding var quantize: Int

    private let quantizeOptions = [0, 4, 8]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Model", selection: $model) {
                    ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                        Text(v.displayName).tag(v)
                    }
                    Divider()
                    Text("Custom…").tag(FluxModelVariant.custom)
                }
                .labelsHidden()

                Picker("", selection: $quantize) {
                    Text("BF16").tag(0)
                    Text("Q8").tag(8)
                    Text("Q4").tag(4)
                }
                .labelsHidden()
                .frame(width: 60)
            }

            if model == .custom {
                customModelFields
            }

            ramEstimateLabel
        }
    }

    @ViewBuilder
    private var customModelFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("HF repo or local path", text: $customModelRepo)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            HStack {
                Text("Base model:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("", selection: $customBaseModel) {
                    ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                        Text(v.displayName).tag(v)
                    }
                }
                .labelsHidden()
                .font(.caption)
            }
        }
        .padding(.top, 2)
    }

    private var ramEstimateLabel: some View {
        let sizeGB = model == .custom ? 0.0 : model.approximateBF16SizeGB
        let quantFactor: Double = quantize == 4 ? 0.25 : quantize == 8 ? 0.5 : 1.0
        let estimatedGB = sizeGB * quantFactor

        return Group {
            if estimatedGB > 0 {
                Text("~\(String(format: "%.0f", estimatedGB)) GB on disk")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
