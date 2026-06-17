import AppKit
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

                // No primaryAction: a split-button main click would run Copy and
                // clobber the system clipboard, so pasting external JSON would paste
                // the app's own caption back. Opening the menu must not copy.
                Menu {
                    Button("Copy JSON") { copyJSON() }
                    Button("Paste JSON") { pasteJSON() }
                } label: {
                    Text("JSON")
                        .font(.caption)
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
                    .textFieldStyle(.roundedBorder)
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
            Picker("", selection: Binding<Bool>(
                get: { caption.styleDescription?.isPhotoMode ?? false },
                set: { $0 ? enterPhotoMode() : enterArtStyleMode() }
            )) {
                Text("Photo").tag(true)
                Text("Art Style").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Photo: uses camera/lens field. Art Style: uses style description field. These are mutually exclusive.")

            styleTextField("Aesthetics", keyPath: \.aesthetics)
            styleTextField("Lighting", keyPath: \.lighting)

            if isPhoto {
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
        return styleFieldRow("Camera / Lens", placeholder: "camera / lens…", text: binding)
    }

    /// Hex color palette backed by `[String]?`, edited as inline swatch chips.
    private var colorPaletteField: some View {
        let binding = Binding<[String]>(
            get: { caption.styleDescription?.colorPalette ?? [] },
            set: { values in
                if caption.styleDescription == nil { caption.styleDescription = IdeogramCaptionStyle() }
                caption.styleDescription?.colorPalette = values.isEmpty ? nil : values
            }
        )
        // Label on its own row so the chip grid gets the full column width to wrap
        // into — in a label|field HStack it was boxed into one narrow column.
        return VStack(alignment: .leading, spacing: 6) {
            Text("Color Palette")
                .font(.caption)
                .foregroundStyle(.secondary)
            ColorPaletteEditor(colors: binding)
        }
    }

    private var elementList: some View {
        VStack(spacing: 15) {
            ForEach($caption.compositionalDeconstruction.elements) { $el in
                elementRow(element: $el)
            }
        }
        .padding(.vertical, 8)
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
        return styleFieldRow(label, placeholder: label.lowercased() + "…", text: binding)
    }

    /// A labeled single-line field with a fixed-width label column so every Style
    /// row aligns, using the native rounded-border field style from the Flux panel.
    private func styleFieldRow(
        _ label: String, placeholder: String, text: Binding<String>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func elementRow(element: Binding<IdeogramCaptionElement>) -> some View {
        let el = element.wrappedValue
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(el.type == .text ? "T" : "•")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(el.type == .text ? Color.blue : Color.green)
                    .frame(width: 18, height: 18)
                    .background((el.type == .text ? Color.blue : Color.green).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if el.bbox.count == 4 {
                    // Coordinates are noise in the list — surface them in a tooltip
                    // on a bounding-box icon instead of a cryptic numeric label.
                    Image(systemName: "viewfinder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Bounding box (0–1000): "
                            + "x \(el.bbox[1])–\(el.bbox[3]), y \(el.bbox[0])–\(el.bbox[2])")
                }

                Spacer(minLength: 4)

                Button {
                    caption.compositionalDeconstruction.elements.removeAll { $0.id == el.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove element")
            }

            if el.type == .text {
                GrowingPromptField(
                    text: Binding(
                        get: { element.wrappedValue.text ?? "" },
                        set: { element.wrappedValue.text = $0.isEmpty ? nil : $0 }
                    ),
                    placeholder: "text…",
                    label: "Element text",
                    hint: "The literal text this element renders",
                    minHeight: 38
                )
            }
            GrowingPromptField(
                text: element.desc,
                placeholder: "description…",
                label: "Element description",
                hint: "Describe this element",
                minHeight: 38
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
