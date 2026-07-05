import SwiftUI

// MARK: - Shared helpers

/// Splits a comma-separated tag field into trimmed, non-empty tags.
private func parseTags(_ raw: String) -> [String] {
    raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

private struct RatingChip: View {
    let rating: LoraRating
    var body: some View {
        if rating != .unrated {
            Text(rating.label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color.opacity(0.2), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        rating == .nsfw ? .pink : .green
    }
}

private struct TagChips: View {
    let tags: [String]
    var body: some View {
        ForEach(tags, id: \.self) { tag in
            Text(tag)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.fill.tertiary, in: Capsule())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Library editor

/// Manages the curated ``LibraryLora`` entries for a single model family.
struct LoraLibraryEditorView: View {
    let family: ModelFamily
    @Environment(LoraLibraryStore.self) private var libraryStore
    @State private var editing: LibraryLora?

    private var entries: [LibraryLora] {
        libraryStore.entries(for: family)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cataloged LoRAs with trigger words and tags. Add them to a job from the LoRA picker in the params panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editing = LibraryLora(modelFamily: family)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if entries.isEmpty {
                Text("No library LoRAs for \(family.rawValue) yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { entry in
            LibraryLoraEditSheet(draft: entry, family: family)
                .environment(libraryStore)
        }
    }

    private func row(_ entry: LibraryLora) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    RatingChip(rating: entry.rating)
                    TagChips(tags: entry.tags)
                }
                if !entry.triggerWords.isEmpty {
                    Text("Trigger: \(entry.triggerWords)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit") { editing = entry }
                .controlSize(.small)
            Button {
                libraryStore.deleteLibrary(id: entry.id)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LibraryLoraEditSheet: View {
    @State private var draft: LibraryLora
    let family: ModelFamily
    @Environment(LoraLibraryStore.self) private var libraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var tagsText: String

    init(draft: LibraryLora, family: ModelFamily) {
        _draft = State(initialValue: draft)
        self.family = family
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.name.isEmpty && draft.path.isEmpty ? "Add Library LoRA" : "Edit Library LoRA")
                .font(.headline)

            field("Name") {
                TextField("Optional — defaults to file name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            field("HuggingFace repo ID or local path") {
                HStack {
                    TextField("org/repo or /path/to/lora.safetensors", text: $draft.path)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { browse() }
                }
            }

            field("Trigger words (auto-inserted into the prompt)") {
                TextField("e.g. neon glow, cyberpunk", text: $draft.triggerWords)
                    .textFieldStyle(.roundedBorder)
            }

            field("Default strength") {
                HStack(spacing: 6) {
                    Slider(value: $draft.defaultStrength, in: -1 ... 2)
                    TextField("", value: $draft.defaultStrength, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                field("Tags (comma-separated)") {
                    TextField("portrait, film", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rating").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draft.rating) {
                        ForEach(LoraRating.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            field("Notes") {
                TextField("Recommended strength, source…", text: $draft.notes)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        draft.modelFamily = family
        draft.tags = parseTags(tagsText)
        libraryStore.upsert(draft)
        dismiss()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.title = "Select LoRA"
        panel.message = "Choose a .safetensors LoRA file"
        if panel.runModal() == .OK, let url = panel.url {
            draft.path = url.path
        }
    }
}

// MARK: - Stacks editor

/// Manages saved ``LoraStack`` combos for a single model family.
struct LoraStacksEditorView: View {
    let family: ModelFamily
    @Environment(LoraLibraryStore.self) private var libraryStore
    @Environment(AppSettings.self) private var settings
    @State private var editing: LoraStack?

    private var stacks: [LoraStack] {
        libraryStore.stacks(for: family)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Named LoRA combinations. Apply a whole stack to a job in one click from the LoRA picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Empty stack") { editing = LoraStack(modelFamily: family) }
                    let defaults = settings.defaultLoras.filter { $0.modelFamily == family }
                    Button("From current default LoRAs") {
                        editing = LoraStack(modelFamily: family, loras: defaults)
                    }
                    .disabled(defaults.isEmpty)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
            }

            if stacks.isEmpty {
                Text("No saved stacks for \(family.rawValue) yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(stacks) { stack in
                            row(stack)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { stack in
            LoraStackEditSheet(draft: stack, family: family)
                .environment(libraryStore)
        }
    }

    private func row(_ stack: LoraStack) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stack.displayName)
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(stack.loras.count)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.2), in: Capsule())
                    RatingChip(rating: stack.rating)
                    TagChips(tags: stack.tags)
                }
                let names = stack.loras.map(\.displayName).joined(separator: ", ")
                if !names.isEmpty {
                    Text(names)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit") { editing = stack }
                .controlSize(.small)
            Button {
                libraryStore.deleteStack(id: stack.id)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LoraStackEditSheet: View {
    @State private var draft: LoraStack
    let family: ModelFamily
    @Environment(LoraLibraryStore.self) private var libraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var tagsText: String

    init(draft: LoraStack, family: ModelFamily) {
        _draft = State(initialValue: draft)
        self.family = family
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.name.isEmpty ? "New Stack" : "Edit Stack")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Stack name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rating").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draft.rating) {
                        ForEach(LoraRating.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tags (comma-separated)").font(.caption).foregroundStyle(.secondary)
                TextField("portrait, film", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            ScrollView {
                LoraManagerView(
                    loras: $draft.loras,
                    showNotes: false,
                    alwaysExpanded: true,
                    modelFamily: family
                )
            }
            .frame(minHeight: 160, maxHeight: 260)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.loras.isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func save() {
        draft.modelFamily = family
        draft.tags = parseTags(tagsText)
        // Keep member entries tagged to this family so the runner routes them correctly.
        draft.loras = draft.loras.map { var e = $0; e.modelFamily = family; return e }
        libraryStore.upsert(draft)
        dismiss()
    }
}
