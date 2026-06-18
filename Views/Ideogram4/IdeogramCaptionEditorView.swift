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

    @AppStorage("ideogram.caption.styleExpanded") private var styleExpanded = true
    @AppStorage("ideogram.caption.bboxElementsExpanded") private var elementsExpanded = true

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
                    Button("Copy") { copyJSON() }
                    Button("Paste") { pasteJSON() }
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
            generateSection

            SectionCard(title: "Description") {
                GrowingPromptField(
                    text: $caption.highLevelDescription,
                    placeholder: "Describe your image…",
                    label: "Description",
                    hint: "High-level description of the image you want to generate"
                )
            }

            SectionCard(title: "Background") {
                GrowingPromptField(
                    text: $caption.compositionalDeconstruction.background,
                    placeholder: "background description…",
                    label: "Background",
                    hint: "Background description of the image",
                    minHeight: 22
                )
            }

            CollapsibleSectionCard(
                title: "Style",
                isExpanded: $styleExpanded,
                trailing: {
                    if styleIsEmpty {
                        Text("not set")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                },
                content: { styleFields.padding(.leading, 4) }
            )

            elementsSection
        }
    }

    /// Parent "Elements" card: the BBox canvas editor plus the collapsible
    /// per-element list, each visually nested inside the Elements border.
    private var elementsSection: some View {
        SectionCard(title: "Elements") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Editor")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                    BBoxEditorView(
                        elements: $caption.compositionalDeconstruction.elements,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }

                if !caption.compositionalDeconstruction.elements.isEmpty {
                    CollapsibleSectionCard(
                        title: "BBox Elements",
                        isExpanded: $elementsExpanded,
                        trailing: {
                            Text("\(caption.compositionalDeconstruction.elements.count) elements")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        },
                        content: { elementList }
                    )
                }
            }
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
        VStack(spacing: 6) {
            ForEach($caption.compositionalDeconstruction.elements) { $el in
                HStack {
                    elementRow(element: $el)
                }
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }

    private var generateSection: some View {
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

                InfoButton(
                    title: "Generate with Gemma",
                    description: "Runs Gemma on the Description field below and fills in "
                        + "Style, Background, and Elements for you. Edit the Description "
                        + "first, then generate.  Check BBox editor to rearrange, as needed."
                )

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
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
                .padding(.top, 6)
            GrowingPromptField(
                text: text,
                placeholder: placeholder,
                label: label,
                hint: label,
                minHeight: 22
            )
        }
    }

    @ViewBuilder
    private func elementRow(element: Binding<IdeogramCaptionElement>) -> some View {
        let el = element.wrappedValue
        HStack(alignment: .top, spacing: 2) {
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

            VStack {
                // Remove BBox button
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

                // Text / Object label
                Text(el.type == .text ? "T" : "O")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(el.type == .text ? Color.blue : Color.green)
                    .frame(width: 18, height: 18)
                    .background((el.type == .text ? Color.blue : Color.green).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help(el.type == .text ? "Text" : "Object")

                // BBox dimension coordinate icon
                if el.bbox.count == 4 {
                    // Coordinates are noise in the list — surface them in a tooltip
                    // on a bounding-box icon instead of a cryptic numeric label.
                    Image(systemName: "viewfinder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Bounding box (0–1000): "
                            + "x \(el.bbox[1])–\(el.bbox[3]), y \(el.bbox[0])–\(el.bbox[2])")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Private-state actions

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
