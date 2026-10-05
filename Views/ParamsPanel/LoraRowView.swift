import SwiftUI

/// One LoRA in a generation's list: on/off, strength, reorder and remove, and
/// Locate… when its file can't be opened any more.
struct LoraRowView: View {
    @Binding var lora: LoraEntry
    let name: String
    var showNotes: Bool = false
    var showDelete: Bool = true
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var isLost = false
    var onLocate: () -> Void = {}
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: $lora.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.7)
                    .frame(width: 32, height: 20)
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(lora.path)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showDelete {
                    Button { onMoveUp() } label: {
                        Image(systemName: "chevron.up").font(.caption)
                    }
                    .buttonStyle(.iconButtonCompact)
                    .foregroundStyle(.secondary)
                    .disabled(!canMoveUp)
                    .help("Move up")
                    Button { onMoveDown() } label: {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .buttonStyle(.iconButtonCompact)
                    .foregroundStyle(.secondary)
                    .disabled(!canMoveDown)
                    .help("Move down")
                    Button { onDelete() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.iconButtonCompact)
                }
            }
            if isLost {
                HStack(spacing: 6) {
                    Label("Access lost", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Locate…", action: onLocate)
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
            HStack(spacing: 6) {
                Slider(value: $lora.strength, in: -1 ... 1)
                TextField("", value: $lora.strength, format: .number.precision(.fractionLength(2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .textFieldStyle(.roundedBorder)
            }
            if showNotes {
                TextField("Notes (trigger words, recommended strength…)", text: $lora.notes)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            } else if !lora.notes.isEmpty {
                Text(lora.notes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: lora.strength) { _, v in
            let rounded = round(v / 0.05) * 0.05
            if abs(v - rounded) > 1e-10 {
                lora.strength = rounded
            }
        }
    }
}
