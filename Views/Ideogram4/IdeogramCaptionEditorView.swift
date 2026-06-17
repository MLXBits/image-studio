import SwiftUI

/// Full caption editing view: high-level desc, style, bbox canvas, element list, generate button.
struct IdeogramCaptionEditorView: View {
    @Binding var caption: IdeogramCaption
    @Binding var usePlainPrompt: Bool
    @Binding var plainPrompt: String
    let outputWidth: Int
    let outputHeight: Int

    @Environment(AppSettings.self) private var settings
    @State private var isGenerating: Bool = false
    @State private var generateError: String?
    @State private var generatorTask: Task<Void, Never>?
    @State private var lastGemmaLog: String = ""
    @State private var showGemmaLog: Bool = false
    @State private var jsonPasteError: String?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode toggle + Reset
            HStack {
                Toggle(isOn: $usePlainPrompt) {
                    Text("Plain text mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Menu {
                    Button("Copy JSON") { copyJSON() }
                    Button("Paste JSON") { pasteJSON() }
                } label: {
                    Text("JSON")
                        .font(.caption)
                } primaryAction: {
                    copyJSON()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Copy the raw caption payload, or paste JSON to populate these fields")

                Button("Reset") { resetCaption() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            .alert("Couldn't paste JSON", isPresented: Binding(
                get: { jsonPasteError != nil },
                set: { if !$0 { jsonPasteError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(jsonPasteError ?? "")
            }

            if usePlainPrompt {
                plainTextEditor
            } else {
                structuredEditor
            }
        }
    }

    // MARK: - Subviews (instance_property)

    private var plainTextEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            GrowingPromptField(
                text: $plainPrompt,
                placeholder: "Describe your image…",
                label: "Prompt",
                hint: "Describe the image you want to generate"
            )
        }
    }

    private var structuredEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                GrowingPromptField(
                    text: $caption.highLevelDescription,
                    placeholder: "Describe your image…",
                    label: "Description",
                    hint: "High-level description of the image you want to generate"
                )
            }

            styleSection

            VStack(alignment: .leading, spacing: 4) {
                Text("Background")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                TextField("background description…", text: $caption.compositionalDeconstruction.background)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Elements")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(caption.compositionalDeconstruction.elements.count) elements")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                BBoxEditorView(
                    elements: $caption.compositionalDeconstruction.elements,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
            }

            if !caption.compositionalDeconstruction.elements.isEmpty {
                elementList
            }

            generateButton
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Style")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                if styleIsEmpty {
                    Text("not set")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)

            styleFields
                .padding(.leading, 12)
        }
    }

    private var styleIsEmpty: Bool {
        caption.styleDescription?.isEmpty ?? true
    }

    private var styleFields: some View {
        let isPhoto = caption.styleDescription?.isPhotoMode ?? false
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                Button("Photo") { enterPhotoMode() }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(isPhoto ? Color.accentColor : Color.primary.opacity(0.08))
                    .foregroundStyle(isPhoto ? Color.white : Color.primary)
                Button("Art Style") { enterArtStyleMode() }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(!isPhoto ? Color.accentColor : Color.primary.opacity(0.08))
                    .foregroundStyle(!isPhoto ? Color.white : Color.primary)
            }
            .font(.subheadline)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .help("Photo: uses camera/lens field. Art Style: uses style description field. These are mutually exclusive.")

            styleTextField("Aesthetics", keyPath: \.aesthetics)
            styleTextField("Lighting", keyPath: \.lighting)

            if caption.styleDescription?.isPhotoMode ?? false {
                // Photo key order: aesthetics → lighting → photo → medium → color_palette
                cameraLensField
                styleTextField("Medium", keyPath: \.medium)
            } else {
                // Art key order: aesthetics → lighting → medium → art_style → color_palette
                styleTextField("Medium", keyPath: \.medium)
                styleTextField("Art Style", keyPath: \.artStyle)
            }
            colorPaletteField
        }
    }

    /// Camera/lens field — never sets `photo` to nil so `isPhotoMode` stays true while editing.
    private var cameraLensField: some View {
        let binding = Binding<String>(
            get: { caption.styleDescription?.photo ?? "" },
            set: { value in
                if caption.styleDescription == nil { caption.styleDescription = IdeogramCaptionStyle() }
                caption.styleDescription?.photo = value
            }
        )
        return LabeledContent("Camera / Lens") {
            TextField("camera / lens…", text: binding)
                .textFieldStyle(.plain)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .font(.callout)
        }
        .font(.caption)
    }

    /// Comma-separated hex color palette field backed by `[String]?`.
    private var colorPaletteField: some View {
        let binding = Binding<String>(
            get: { (caption.styleDescription?.colorPalette ?? []).joined(separator: ", ") },
            set: { raw in
                if caption.styleDescription == nil { caption.styleDescription = IdeogramCaptionStyle() }
                let values = raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                caption.styleDescription?.colorPalette = values.isEmpty ? nil : values
            }
        )
        return LabeledContent("Color Palette") {
            TextField("#hex, #hex…", text: binding)
                .textFieldStyle(.plain)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .font(.callout)
        }
        .font(.caption)
    }

    private var elementList: some View {
        VStack(spacing: 2) {
            ForEach($caption.compositionalDeconstruction.elements) { $el in
                elementRow(element: $el)
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var generateButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Button {
                    startGenerate()
                } label: {
                    HStack(spacing: 6) {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGenerating ? "Generating…" : "Generate with Gemma")
                    }
                }
                .disabled(
                    isGenerating
                        || caption.highLevelDescription.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if isGenerating {
                    Button("Cancel") { generatorTask?.cancel() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !lastGemmaLog.isEmpty {
                    Button {
                        showGemmaLog = true
                    } label: {
                        Image(systemName: "text.alignleft")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show Gemma generation log")
                }
                Spacer()
            }
            .sheet(isPresented: $showGemmaLog) {
                NavigationStack {
                    ScrollView {
                        Text(lastGemmaLog)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Gemma Log")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showGemmaLog = false }
                        }
                    }
                }
                .frame(width: 680, height: 500)
            }

            if let err = generateError {
                ScrollView {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(6)
                .background(Color.red.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Methods (other_method)

    private func enterPhotoMode() {
        if caption.styleDescription == nil { caption.styleDescription = IdeogramCaptionStyle() }
        caption.styleDescription?.artStyle = nil
        if caption.styleDescription?.photo == nil { caption.styleDescription?.photo = "" }
        if (caption.styleDescription?.medium ?? "").isEmpty { caption.styleDescription?.medium = "photograph" }
    }

    private func enterArtStyleMode() {
        if caption.styleDescription == nil { caption.styleDescription = IdeogramCaptionStyle() }
        caption.styleDescription?.photo = nil
    }

    private func setStyle(_ kp: WritableKeyPath<IdeogramCaptionStyle, String?>, _ value: String) {
        if caption.styleDescription == nil {
            caption.styleDescription = IdeogramCaptionStyle()
        }
        caption.styleDescription?[keyPath: kp] = value.isEmpty ? nil : value
    }

    private func styleTextField(
        _ label: String, keyPath: WritableKeyPath<IdeogramCaptionStyle, String?>
    ) -> some View {
        let binding = Binding<String>(
            get: { caption.styleDescription?[keyPath: keyPath] ?? "" },
            set: { setStyle(keyPath, $0) }
        )
        return LabeledContent(label) {
            TextField(label.lowercased() + "…", text: binding)
                .textFieldStyle(.plain)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .font(.callout)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func elementRow(element: Binding<IdeogramCaptionElement>) -> some View {
        let el = element.wrappedValue
        HStack(spacing: 6) {
            Text(el.type == .text ? "T" : "•")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(el.type == .text ? Color.blue : Color.green)
                .frame(width: 18, height: 18)
                .background((el.type == .text ? Color.blue : Color.green).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                if el.type == .text, let txt = el.text, !txt.isEmpty {
                    TextField("text…", text: Binding(
                        get: { el.text ?? "" },
                        set: { element.wrappedValue.text = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.caption)
                    .textFieldStyle(.plain)
                }
                TextField("description…", text: element.desc)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if el.bbox.count == 4 {
                Text("[\(el.bbox[1]),\(el.bbox[0])→\(el.bbox[3]),\(el.bbox[2])]")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Button {
                caption.compositionalDeconstruction.elements.removeAll { $0.id == el.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Copies the exact caption payload (the JSON handed to mflux) to the clipboard.
    /// In plain-text mode there is no structured payload, so the prompt text is copied.
    private func copyJSON() {
        let payload = usePlainPrompt ? plainPrompt : (caption.toPrettyJSON() ?? "")
        guard !payload.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    /// Parses a caption payload from the clipboard into the structured fields.
    /// Leaves plain-text mode (the pasted JSON drives the structured editor).
    private func pasteJSON() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            jsonPasteError = "The clipboard is empty."
            return
        }
        guard let parsed = IdeogramCaption.from(jsonString: raw) else {
            jsonPasteError = "The clipboard doesn't contain a valid Ideogram caption JSON object."
            return
        }
        caption = parsed
        usePlainPrompt = false
    }

    private func resetCaption() {
        caption.highLevelDescription = ""
        caption.styleDescription = nil
        caption.compositionalDeconstruction.background = ""
        caption.compositionalDeconstruction.elements = []
        plainPrompt = ""
    }

    private func startGenerate() {
        generateError = nil
        isGenerating = true
        let desc = caption.highLevelDescription
        let generator = IdeogramCaptionGenerator()
        generatorTask = Task { @MainActor in
            do {
                let result = try await generator.generate(from: desc, settings: settings)
                lastGemmaLog = generator.lastLog
                caption.highLevelDescription = result.highLevelDescription
                if let style = result.styleDescription { caption.styleDescription = style }
                caption.compositionalDeconstruction.background =
                    result.compositionalDeconstruction.background
                if !result.compositionalDeconstruction.elements.isEmpty {
                    caption.compositionalDeconstruction.elements =
                        result.compositionalDeconstruction.elements
                }
            } catch is CancellationError {
                // User cancelled — the subprocess was terminated; no error to show.
                lastGemmaLog = generator.lastLog
            } catch {
                lastGemmaLog = generator.lastLog
                generateError = error.localizedDescription
            }
            isGenerating = false
        }
    }
}
