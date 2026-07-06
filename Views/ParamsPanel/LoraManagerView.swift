import SwiftUI

struct LoraManagerView: View {
    @Binding var loras: [LoraEntry]
    var showNotes: Bool = false
    var alwaysExpanded: Bool = false
    var showAdd: Bool = true
    var defaultLoras: [LoraEntry] = []
    var modelFamily: ModelFamily = .flux
    /// When set, a library/stacks picker button appears in the header. Nil in
    /// contexts that only edit a raw list (e.g. Settings defaults).
    var library: LoraLibraryStore?
    /// Called with a library LoRA's trigger words when it (or a stack) is
    /// activated, so the host can insert them into the prompt.
    var onInsertTriggerWords: ((String) -> Void)?
    var onReset: (() -> Void)?
    @AppStorage("lorasSectionExpanded") private var isExpanded: Bool = false
    @State private var showingAdd: Bool = false
    @State private var showingPicker: Bool = false
    @State private var newPath: String = ""
    @State private var editingID: UUID?

    var body: some View {
        if alwaysExpanded {
            VStack(spacing: 8) {
                header
                loraList
            }
            .sheet(isPresented: $showingAdd) { addLoraSheet }
            .sheet(isPresented: $showingPicker) { pickerSheet }
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                loraList
            } label: {
                header
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { isExpanded.toggle() } }
            }
            .sheet(isPresented: $showingAdd) { addLoraSheet }
            .sheet(isPresented: $showingPicker) { pickerSheet }
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
            if library != nil {
                Button { showingPicker = true } label: {
                    Image(systemName: "books.vertical")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add from library or apply a stack")
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

    /// Rows are editable (delete + reorder) whenever the list can be added to —
    /// either via the manual add button or the library/stacks picker. Prevents
    /// the "can add but can't remove" asymmetry in the Flux/Krea 2 panels, which
    /// hide manual add but still offer the library picker.
    private var rowsEditable: Bool {
        showAdd || library != nil
    }

    private var loraList: some View {
        VStack(spacing: 19) {
            ForEach($loras) { $lora in
                let index = loras.firstIndex { $0.id == lora.id } ?? 0
                LoraRowView(
                    lora: $lora,
                    showNotes: showNotes,
                    showDelete: rowsEditable,
                    canMoveUp: index > 0,
                    canMoveDown: index < loras.count - 1,
                    onMoveUp: { move(from: index, to: index - 1) },
                    onMoveDown: { move(from: index, to: index + 1) },
                    onDelete: { remove(id: lora.id) }
                )
            }
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
        loras.append(LoraEntry(path: trimmed, modelFamily: modelFamily))
        newPath = ""
        showingAdd = false
    }

    // MARK: - Library & stacks picker

    @ViewBuilder
    private var pickerSheet: some View {
        if let library {
            LoraPickerSheet(
                library: library,
                family: modelFamily,
                onAddLibrary: { addFromLibrary($0) },
                onApplyStack: { applyStack($0) }
            )
        }
    }

    /// Adds a library LoRA (deduped by path) and inserts its trigger words.
    private func addFromLibrary(_ lib: LibraryLora) {
        if !loras.contains(where: { $0.path == lib.path }) {
            loras.append(lib.toEntry())
        }
        if let onInsertTriggerWords, !lib.triggerWords.isEmpty {
            onInsertTriggerWords(lib.triggerWords)
        }
    }

    /// Merges a stack into the current list — adds missing entries by path,
    /// updates strength/enabled on existing ones — then inserts every member's
    /// trigger words (looked up in the library by path).
    private func applyStack(_ stack: LoraStack) {
        for entry in stack.loras {
            if let idx = loras.firstIndex(where: { $0.path == entry.path }) {
                loras[idx].strength = entry.strength
                loras[idx].enabled = entry.enabled
            } else {
                loras.append(entry)
            }
        }
        guard let onInsertTriggerWords, let library else { return }
        let triggers = stack.loras
            .compactMap { library.libraryEntry(path: $0.path)?.triggerWords }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !triggers.isEmpty { onInsertTriggerWords(triggers) }
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

    private func move(from: Int, to: Int) {
        guard to >= 0, to < loras.count else { return }
        loras.swapAt(from, to)
    }
}

private struct LoraRowView: View {
    @Binding var lora: LoraEntry
    var showNotes: Bool = false
    var showDelete: Bool = true
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
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
                    Button { onMoveUp() } label: {
                        Image(systemName: "chevron.up").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!canMoveUp)
                    .help("Move up")
                    Button { onMoveDown() } label: {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!canMoveDown)
                    .help("Move down")
                    Button { onDelete() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
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
            if abs(v - rounded) > 1e-10 { lora.strength = rounded }
        }
    }
}

// MARK: - Library & stacks picker sheet

private struct LoraPickerSheet: View {
    let library: LoraLibraryStore
    let family: ModelFamily
    let onAddLibrary: (LibraryLora) -> Void
    let onApplyStack: (LoraStack) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""

    private var entries: [LibraryLora] {
        let all = library.entries(for: family)
        guard !search.isEmpty else { return all }
        let q = search.lowercased()
        return all.filter {
            $0.displayName.lowercased().contains(q)
                || $0.triggerWords.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    private var stacks: [LoraStack] {
        let all = library.stacks(for: family)
        guard !search.isEmpty else { return all }
        let q = search.lowercased()
        return all.filter {
            $0.displayName.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(family.rawValue) LoRA Library").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            TextField("Search name, trigger, or tag", text: $search)
                .textFieldStyle(.roundedBorder)

            if entries.isEmpty && stacks.isEmpty {
                Text(library.entries(for: family).isEmpty && library.stacks(for: family).isEmpty
                    ? "No library LoRAs or stacks for \(family.rawValue). Add them in Settings › LoRAs."
                    : "No matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !stacks.isEmpty {
                            sectionHeader("Stacks")
                            ForEach(stacks) { stack in stackRow(stack) }
                        }
                        if !entries.isEmpty {
                            sectionHeader("LoRAs")
                            ForEach(entries) { entry in libraryRow(entry) }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 460, height: 420)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func libraryRow(_ entry: LibraryLora) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.callout).lineLimit(1).truncationMode(.middle)
                if !entry.triggerWords.isEmpty {
                    Text("Trigger: \(entry.triggerWords)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add") { onAddLibrary(entry) }
                .controlSize(.small)
        }
        .padding(8)
        .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func stackRow(_ stack: LoraStack) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stack.displayName).font(.callout).lineLimit(1)
                    Text("\(stack.loras.count)")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.blue.opacity(0.2), in: Capsule())
                }
                let names = stack.loras.map(\.displayName).joined(separator: ", ")
                if !names.isEmpty {
                    Text(names).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Apply") { onApplyStack(stack) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
