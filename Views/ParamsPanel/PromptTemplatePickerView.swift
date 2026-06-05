import SwiftUI

struct PromptTemplatePickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let currentPrompt: String
    let currentNegative: String

    @State private var showingAddSheet: Bool = false
    @State private var editingTemplate: PromptTemplate?

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader
            Divider()
            templateList
            Divider()
            pickerFooter
        }
        .frame(width: 360)
        .onExitCommand { dismiss() }
        .sheet(isPresented: $showingAddSheet) {
            TemplateEditSheet(template: nil) { newTemplate in
                settings.customTemplates.append(newTemplate)
            }
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditSheet(template: template) { updated in
                if let idx = settings.customTemplates.firstIndex(where: { $0.id == updated.id }) {
                    settings.customTemplates[idx] = updated
                }
            }
        }
    }

    // MARK: - Header

    private var pickerHeader: some View {
        HStack {
            Text("Style Templates")
                .font(.headline)
            Spacer()
            if !settings.activeTemplateIDs.isEmpty {
                Button("Clear") { settings.activeTemplateIDs = [] }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button { showingAddSheet = true } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Add custom template")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var pickerFooter: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Template list

    private var templateList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if !settings.customTemplates.isEmpty {
                    templateSection(
                        category: .custom,
                        templates: settings.customTemplates,
                        allowsEdit: true
                    )
                }
                ForEach(TemplateCategory.allCases.filter { $0 != .custom }, id: \.rawValue) { category in
                    let templates = BuiltInTemplates.all.filter { $0.category == category }
                    if !templates.isEmpty {
                        templateSection(category: category, templates: templates, allowsEdit: false)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxHeight: 520)
    }

    @ViewBuilder
    private func templateSection(
        category: TemplateCategory,
        templates: [PromptTemplate],
        allowsEdit: Bool
    ) -> some View {
        Section {
            ForEach(templates) { template in
                templateRow(template, allowsEdit: allowsEdit)
            }
        } header: {
            Text(category.displayName.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private func templateRow(_ template: PromptTemplate, allowsEdit: Bool) -> some View {
        let isActive = settings.activeTemplateIDs.contains(template.id)
        HStack(alignment: .top, spacing: 10) {
            thumbnailView(for: template)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(template.name)
                        .font(.callout)
                        .fontWeight(.medium)
                    Spacer()
                    if allowsEdit {
                        editButtons(for: template)
                    }
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                if !template.useCases.isEmpty {
                    Text(template.useCases)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                previewText(for: template)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            settings.toggleTemplate(template.id)
        }
    }

    @ViewBuilder
    private func thumbnailView(for template: PromptTemplate) -> some View {
        Group {
            if let name = template.exampleImageName {
                if template.isBuiltIn {
                    // Asset catalog — use SwiftUI Image directly (NSImage(named:) is unreliable for xcassets)
                    Image(name)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if FileManager.default.fileExists(atPath: name),
                          let img = NSImage(contentsOfFile: name) {
                    // Custom template — file path on disk
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholderIcon(for: template.category)
                }
            } else {
                placeholderIcon(for: template.category)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func placeholderIcon(for category: TemplateCategory) -> some View {
        Image(systemName: categorySymbol(for: category))
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.fill.quaternary)
    }

    @ViewBuilder
    private func previewText(for template: PromptTemplate) -> some View {
        let preview = template.apply(
            to: currentPrompt,
            negativePrompt: currentNegative,
            supportsNegativePrompt: true
        )
        let base = currentPrompt.isEmpty ? "(your prompt)" : currentPrompt
        let appended = appendedPart(
            positive: preview.positive,
            base: base,
            template: template
        )

        Group {
            if appended.isEmpty {
                Text(base)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                // Bold = user text, regular = template additions
                (boldBase(base) + Text(", \(appended)").font(.caption).foregroundStyle(.tertiary))
                    .lineLimit(2)
            }
        }
    }

    private func boldBase(_ text: String) -> Text {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    // Extracts the template-contributed text for display.
    private func appendedPart(positive: String, base: String, template: PromptTemplate) -> String {
        let trimmed = template.positiveTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("{prompt}") {
            // Anything after the substituted base
            let resolved = trimmed.replacingOccurrences(of: "{prompt}", with: "")
            return resolved
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    @ViewBuilder
    private func editButtons(for template: PromptTemplate) -> some View {
        HStack(spacing: 2) {
            Button {
                editingTemplate = template
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Edit template")

            Button {
                deleteCustomTemplate(id: template.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
            .help("Delete template")
        }
    }

    private func deleteCustomTemplate(id: UUID) {
        settings.customTemplates.removeAll { $0.id == id }
        settings.activeTemplateIDs.removeAll { $0 == id }
    }

    private func categorySymbol(for category: TemplateCategory) -> String {
        switch category {
        case .lighting: "sun.max"
        case .camera: "camera"
        case .detail: "sparkles"
        case .shotType: "viewfinder"
        case .custom: "person.crop.square"
        }
    }
}

// MARK: - Add / Edit Sheet

struct TemplateEditSheet: View {
    let template: PromptTemplate?
    let onSave: (PromptTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var positiveTemplate: String
    @State private var negativeTemplate: String
    @State private var useCases: String
    @State private var exampleImagePath: String

    init(template: PromptTemplate?, onSave: @escaping (PromptTemplate) -> Void) {
        self.template = template
        self.onSave = onSave
        _name = State(initialValue: template?.name ?? "")
        _positiveTemplate = State(initialValue: template?.positiveTemplate ?? "")
        _negativeTemplate = State(initialValue: template?.negativeTemplate ?? "")
        _useCases = State(initialValue: template?.useCases ?? "")
        _exampleImagePath = State(initialValue: template?.exampleImageName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(template == nil ? "New Template" : "Edit Template")
                .font(.headline)

            nameField
            useCasesField
            positiveField
            negativeField
            imageField

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(template == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                        || positiveTemplate.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. Moody Portrait", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var useCasesField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Use Cases")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("— one line, shown as a hint in the picker")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TextField("e.g. Headshots, editorial, social media", text: $useCases)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var positiveField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Positive Template")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("— use {prompt} as placeholder for the user's text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TextEditor(text: $positiveTemplate)
                .font(.body)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if positiveTemplate.isEmpty {
                        Text("{prompt}, your style additions here…")
                            .foregroundStyle(.tertiary)
                            .font(.body)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var negativeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Negative Template")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("— optional, only used by models that support negative prompts")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TextEditor(text: $negativeTemplate)
                .font(.body)
                .frame(minHeight: 44)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if negativeTemplate.isEmpty {
                        Text("Things to avoid (optional)…")
                            .foregroundStyle(.tertiary)
                            .font(.body)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var imageField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Example Image")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if !exampleImagePath.isEmpty,
                   FileManager.default.fileExists(atPath: exampleImagePath),
                   let img = NSImage(contentsOfFile: exampleImagePath) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button {
                        exampleImagePath = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove example image")
                }
                Button("Choose Image…") { browseExampleImage() }
                    .controlSize(.small)
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let saved = PromptTemplate(
            id: template?.id ?? UUID(),
            name: trimmedName,
            positiveTemplate: positiveTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
            negativeTemplate: negativeTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
            category: .custom,
            isBuiltIn: false,
            useCases: useCases.trimmingCharacters(in: .whitespaces),
            exampleImageName: exampleImagePath.isEmpty ? nil : exampleImagePath
        )
        onSave(saved)
        dismiss()
    }

    private func browseExampleImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.title = "Choose Example Image"
        panel.message = "Select an image that represents this style"
        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "webp"].contains(ext) {
                exampleImagePath = url.path
            }
        }
    }
}
