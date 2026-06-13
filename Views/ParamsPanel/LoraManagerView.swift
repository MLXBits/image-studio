import SwiftUI

struct LoraManagerView: View {
    @Binding var loras: [LoraEntry]
    var showNotes: Bool = false
    var alwaysExpanded: Bool = false
    var showAdd: Bool = true
    var defaultLoras: [LoraEntry] = []
    var onReset: (() -> Void)?
    @AppStorage("lorasSectionExpanded") private var isExpanded: Bool = false
    @State private var showingAdd: Bool = false
    @State private var newPath: String = ""
    @State private var editingID: UUID?

    var body: some View {
        if alwaysExpanded {
            VStack(spacing: 8) {
                header
                loraList
            }
            .sheet(isPresented: $showingAdd) { addLoraSheet }
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                loraList
            } label: {
                header
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { isExpanded.toggle() } }
            }
            .sheet(isPresented: $showingAdd) { addLoraSheet }
        }
    }

    private var header: some View {
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
            if let onReset {
                Button("Reset", action: onReset)
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if showAdd {
                Button { if !alwaysExpanded { isExpanded = true }; showingAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var loraList: some View {
        VStack(spacing: 19) {
            ForEach($loras) { $lora in
                LoraRowView(
                    lora: $lora,
                    showNotes: showNotes,
                    showDelete: showAdd
                ) { remove(id: lora.id) }
            }
            .onMove { from, to in loras.move(fromOffsets: from, toOffset: to) }
        }
        .padding(.top, 4)
    }

    private var missingDefaults: [LoraEntry] {
        let current = Set(loras.map(\.path))
        return defaultLoras.filter { !current.contains($0.path) }
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

            if !missingDefaults.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Missing from defaults")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(missingDefaults) { lora in
                        HStack {
                            Text(lora.displayName)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Restore") { loras.append(lora) }
                                .controlSize(.small)
                        }
                    }
                    Button("Restore All") { missingDefaults.forEach { loras.append($0) } }
                        .controlSize(.small)
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
    var showNotes: Bool = false
    var showDelete: Bool = true
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: $lora.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.7)
                    .frame(width: 32, height: 20)
                Text(lora.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showDelete {
                    Button { onDelete() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Slider(value: $lora.strength, in: -1...1)
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
            if abs(v - rounded) > 1e-10 { lora.strength = rounded }
        }
    }
}
