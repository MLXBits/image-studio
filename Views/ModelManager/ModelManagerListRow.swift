import SwiftUI

/// One model in the Models window's sidebar: fit dot, name, cached-quant chips.
struct ModelManagerListRow: View {
    let row: ModelRow
    let isDownloading: Bool

    private var fitQuant: QuantStatus? {
        row.quants.first { $0.quantize == 8 }
    }

    var body: some View {
        // Name on top, chips below: the sidebar never has to fit a long name and three chips on one line.
        VStack(alignment: .leading, spacing: 3) {
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
                Spacer(minLength: 4)
                if isDownloading {
                    ProgressView().controlSize(.small)
                }
            }
            ModelManagerRowDetail(
                chips: row.quants.filter(\.cached).map(\.label),
                note: row.toolMissing ? "Not in this mflux install" : nil
            )
            .padding(.leading, fitQuant == nil ? 0 : 14)
        }
    }
}

/// A sidebar row's second line: its cached chips, or a note. Nothing when it has neither.
struct ModelManagerRowDetail: View {
    let chips: [String]
    var note: String?

    var body: some View {
        if !chips.isEmpty || note != nil {
            HStack(spacing: 4) {
                ForEach(chips, id: \.self) { chip in
                    CachedChip(label: chip)
                }
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The green capsule that marks a cached quant or tool in the sidebar.
struct CachedChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.green.opacity(0.15), in: Capsule())
            .foregroundStyle(.green)
            .accessibilityLabel("\(label) cached")
    }
}
