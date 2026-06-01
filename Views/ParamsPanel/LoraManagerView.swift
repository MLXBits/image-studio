import SwiftUI

struct LoraManagerView: View {
    @Binding var loras: [LoraEntry]
    @AppStorage("lorasSectionExpanded") private var isExpanded: Bool = false
    @State private var showingAdd: Bool = false
    @State private var newPath: String = ""
    @State private var editingID: UUID? = nil

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: { loraList },
            label: {
                HStack {
                    Text("LoRAs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !loras.isEmpty {
                        Text("\(loras.count)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.2), in: Capsule())
                    }
                    Spacer()
                    Button { isExpanded = true; showingAdd = true } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        )
        .sheet(isPresented: $showingAdd) { addLoraSheet }
    }

    @ViewBuilder
    private var loraList: some View {
        VStack(spacing: 4) {
            ForEach($loras) { $lora in
                LoraRowView(lora: $lora, onDelete: { remove(id: lora.id) })
            }
            .onMove { from, to in loras.move(fromOffsets: from, toOffset: to) }
        }
        .padding(.top, 4)
    }

    private var addLoraSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add LoRA").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("HuggingFace repo ID or local path")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("org/repo or /path/to/lora.safetensors", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { browseLocalFile() }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { showingAdd = false; newPath = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addLora() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
    }

    private func addLora() {
        let trimmed = newPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        loras.append(LoraEntry(path: trimmed))
        newPath = ""
        showingAdd = false
    }

    private func browseLocalFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.title = "Select LoRA"
        panel.message = "Choose a .safetensors LoRA file"
        if panel.runModal() == .OK, let url = panel.url {
            newPath = url.path
        }
    }

    private func remove(id: UUID) {
        loras.removeAll { $0.id == id }
    }
}

private struct LoraRowView: View {
    @Binding var lora: LoraEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $lora.enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Text(lora.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Slider(value: $lora.strength, in: 0...2, step: 0.05)
                .frame(width: 60)

            Text(String(format: "%.2f", lora.strength))
                .font(.caption2)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)

            Button { onDelete() } label: {
                Image(systemName: "trash").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
        }
        .padding(.vertical, 2)
    }
}
