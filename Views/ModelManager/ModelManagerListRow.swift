import SwiftUI

/// One model in the Models window's sidebar: fit dot, name, cached-quant chips.
struct ModelManagerListRow: View {
    let row: ModelRow
    let isDownloading: Bool

    private var fitQuant: QuantStatus? {
        row.quants.first { $0.quantize == 8 }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let fitQuant {
                Circle()
                    .fill(fitQuant.fit.color)
                    .frame(width: 8, height: 8)
                    .help(fitQuant.fit.tooltip)
                    .accessibilityHidden(true)
            }
            Text(row.model.displayName)
                .lineLimit(1)
            if row.toolMissing {
                Text("— not in this mflux install")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isDownloading {
                ProgressView().controlSize(.small)
            }
            ForEach(row.quants.filter(\.cached), id: \.quantize) { quant in
                Text(quant.label)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
                    .accessibilityLabel("\(quant.label) cached")
            }
        }
    }
}
