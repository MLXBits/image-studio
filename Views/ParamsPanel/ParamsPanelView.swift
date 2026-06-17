// swiftlint:disable file_length
import AppKit
import SwiftUI

private struct OverlayScrollerApplicator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            nsView.enclosingScrollView?.scrollerStyle = .overlay
        }
    }
}

struct ParamsPanelView: View {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    @Bindable var params: ParamsPanelState
    @Bindable var ideogramParams: Ideogram4ParamsPanelState
    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery

    @State private var isImageDropTargeted: Bool = false
    @State private var isEditDropTargeted: Bool = false
    @State private var showingTemplatePicker: Bool = false

    private var isDistilled: Bool {
        params.model.isDistilled
    }

    private var unifiedQuantize: Binding<Int> {
        Binding(
            get: { params.model.isIdeogram4 ? ideogramParams.quantize : params.quantize },
            set: { v in
                if params.model.isIdeogram4 {
                    ideogramParams.quantize = v
                } else {
                    params.quantize = v
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Model — single picker covering FLUX.2 variants, Ideogram 4, and Custom
                SectionContainerView(title: "Model", info: nil) {
                    ModelPickerView(
                        model: $params.model,
                        customModelRepo: $params.customModelRepo,
                        customBaseModel: $params.customBaseModel,
                        quantize: unifiedQuantize
                    )
                    .onChange(of: params.model) { _, m in
                        if m.isIdeogram4 {
                            ideogramParams.loras = settings.defaultLoras.filter { $0.modelFamily == .ideogram4 }
                            return
                        }
                        guard m != .custom else { return }
                        let d = settings.resolvedDefaults(for: m)
                        params.steps = d.steps
                        params.guidance = d.guidance
                        params.quantize = d.quantize
                        params.lowRam = d.lowRam
                        params.negativePrompt = d.negativePrompt
                        params.width = d.width
                        params.height = d.height
                        params.loras = d.loras.isEmpty
                            ? settings.defaultLoras.filter { $0.modelFamily == .flux }
                            : d.loras
                        params.isEditMode = false
                        params.editImagePaths = []
                    }

                    if params.model != .custom, !params.model.isIdeogram4 {
                        modePickerRow
                    }
                }

                Divider()

                if params.modelFamily == .flux {
                    fluxContent
                } else {
                    Ideogram4ParamsPanelView(params: ideogramParams)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(OverlayScrollerApplicator())
        }
        .scrollIndicators(.automatic)
        .contentMargins(.trailing, 5, for: .scrollContent)
    }

    // MARK: - Flux content

    @ViewBuilder
    private var fluxContent: some View {
        // Style
        SectionContainerView(
            title: "Style",
            info: "Stacks preset style additions on your prompt — lighting, camera," +
                " detail level, shot type. Select multiple. Applied at generation time;" +
                " your prompt text stays clean."
        ) {
            styleRow
        }

        Divider()

        // Prompt
        SectionContainerView(
            title: "Prompt",
            info: "Describe what you want to generate. Be specific about subjects, " +
                "lighting, style, and mood. More detail generally produces better results."
        ) {
            promptEditor
            if params.model.supportsNegativePrompt {
                negativePromptEditor
            }
        }

        // Image input
        if params.isEditMode {
            SectionContainerView(
                title: "Image Input",
                info: "One or more reference images for editing. Order matters: list the " +
                    "primary subject first. Prompt describes the edit — " +
                    "e.g. \"make her wear the glasses\"."
            ) {
                editImagesSection
            }
        } else {
            SectionContainerView(
                title: "Image Input",
                info: "Optional reference image for image-to-image generation. " +
                    "Drag an image here or click to browse. Higher strength = " +
                    "closer to the original image. Lower strength = more creative, " +
                    "prompt dominates."
            ) {
                img2ImgSection
            }
        }

        Divider()

        SectionContainerView(
            title: "Folder",
            info: "Organizes generated images into named subfolders inside your output " +
                "directory. Leave as Default to keep everything in one place."
        ) {
            boardRow
        }

        Divider()

        SectionContainerView(title: nil, info: nil) {
            DimensionPickerView(width: $params.width, height: $params.height)
        }

        Divider()

        SectionContainerView(title: nil, info: nil) {
            stepsAndSeedRow
        }

        if !isDistilled {
            Divider()
            SectionContainerView(
                title: "Guidance",
                info: "How closely the model follows your prompt. Higher = stricter adherence but" +
                    "can over-saturate. 3–7 is typical for base models. Distilled Klein models always use 1.0."
            ) {
                guidanceRow
            }
        }

        Divider()

        LoraManagerView(
            loras: $params.loras,
            showAdd: false,
            defaultLoras: settings.defaultLoras.filter { $0.modelFamily == .flux }
        ) {
            let d = settings.resolvedDefaults(for: params.model)
            params.loras = d.loras.isEmpty ? settings.defaultLoras.filter { $0.modelFamily == .flux } : d.loras
        }
        .padding(.bottom, 8)
    }

    // MARK: - Style (template) row

    private var styleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            // styleChips is a single stable view at this position so the popover
            // anchor survives the empty → active transition without dismissing.
            styleChips
                .popover(isPresented: $showingTemplatePicker) { templatePickerPopover }
        }
    }

    @ViewBuilder
    private var styleChips: some View {
        let active = settings.activeTemplates
        if active.isEmpty {
            // Entire trailing area is the tap target; + is the visual affordance.
            Button { showingTemplatePicker = true } label: {
                HStack(spacing: 0) {
                    Spacer(minLength: 4)
                    Image(systemName: "plus")
                        .font(.system(size: 9))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 4) {
                Spacer(minLength: 4)
                // Show up to 2 chip names, then +N overflow
                let shown = Array(active.prefix(2))
                let overflow = active.count - shown.count
                ForEach(shown) { template in
                    styleChip(name: template.name, templateID: template.id)
                }
                if overflow > 0 {
                    styleChip(name: "+\(overflow)", templateID: nil)
                }
                Button { showingTemplatePicker = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Edit style selection")
            }
        }
    }

    private var templatePickerPopover: some View {
        PromptTemplatePickerView()
            .environment(settings)
    }

    // MARK: - Prompt editor (auto-expanding)
    //
    // An invisible Text drives the height: it grows with content (fixedSize vertical),
    // and the TextEditor overlays it exactly. .background() would be constrained to the
    // TextEditor's existing height — useless. The overlay approach is the correct pattern.
    //
    // When style templates are active, ghost text (template additions) is appended in
    // tertiaryLabelColor and is non-editable. The height driver includes the ghost text
    // so the field expands to show the full combined content.

    private var promptEditor: some View {
        promptField(
            text: $params.prompt,
            placeholder: "Describe your image…",
            label: "Prompt",
            hint: "Describe the image you want to generate",
            ghostSuffix: resolvedPositiveGhost
        )
    }

    private var negativePromptEditor: some View {
        promptField(
            text: $params.negativePrompt,
            placeholder: "Negative prompt (optional)…",
            label: "Negative prompt",
            hint: "Describe elements to avoid or suppress in the generated image",
            ghostSuffix: resolvedNegativeGhost
        )
    }

    /// Chains active templates on the positive prompt and returns the suffix they add.
    /// Returns "" when templates are inactive or when the result can't be represented
    /// as a simple suffix (e.g. templates that reorder text around {prompt}).
    private var resolvedPositiveGhost: String {
        guard !settings.activeTemplates.isEmpty else { return "" }
        var resolved = params.prompt
        for template in settings.activeTemplates {
            resolved = template.apply(to: resolved, negativePrompt: "", supportsNegativePrompt: false).positive
        }
        guard resolved.hasPrefix(params.prompt) else { return "" }
        return String(resolved.dropFirst(params.prompt.count))
    }

    private var resolvedNegativeGhost: String {
        guard !settings.activeTemplates.isEmpty else { return "" }
        guard params.model.supportsNegativePrompt else { return "" }
        var resolved = params.negativePrompt
        for template in settings.activeTemplates {
            resolved = template.apply(to: "", negativePrompt: resolved, supportsNegativePrompt: true).negative
        }
        guard resolved.hasPrefix(params.negativePrompt) else { return "" }
        return String(resolved.dropFirst(params.negativePrompt.count))
    }

    // MARK: - Steps + Seed (one row, always visible)

    private var stepsAndSeedRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Spacer(minLength: 0)
            // Steps
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("Steps").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                    InfoButton(
                        title: "Denoising Steps",
                        description: "Number of denoising iterations. Distilled models (Klein 4B/9B) work"
                            + " well at 4 steps. Base models need 30–50. More steps = more compute"
                            + " time with diminishing quality returns."
                    )
                }
                Stepper(value: $params.steps, in: 1 ... 150) {
                    TextField("", value: $params.steps, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .onSubmit { params.steps = max(1, min(150, params.steps)) }
                }
                .accessibilityLabel("Steps")
                .accessibilityValue("\(params.steps)")
                .accessibilityHint("Number of denoising iterations")
            }

            Divider().frame(height: 44)

            // Seed
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("Seed").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                    InfoButton(
                        title: "Random Seed",
                        description: "Controls the randomness of generation. The same seed + prompt"
                            + " produces the same image every time — great for iteration."
                            + " Use -1 for a unique result each run."
                    )
                }
                HStack(spacing: 4) {
                    TextField("-1", value: $params.seed, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 100)
                        .accessibilityLabel("Seed")
                        .accessibilityHint("Use -1 for random")
                    Button {
                        params.seed = Int.random(in: 0 ..< 1_000_000_000)
                    } label: {
                        Image(systemName: "dice").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pick random seed")
                    Button {
                        params.seed = -1
                    } label: {
                        Image(systemName: "arrow.counterclockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset to random (-1)")
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Guidance (base models only)

    private var guidanceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Slider(value: $params.guidance, in: 1.0 ... 15.0, step: 0.5)
                    .accessibilityLabel("Guidance")
                    .accessibilityValue(String(format: "%.1f", params.guidance))
                    .accessibilityHint("Higher = follows prompt more strictly")
                Text(String(format: "%.1f", params.guidance))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 28)
            }
        }
    }

    // MARK: - Img2img

    private var img2ImgSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if !params.imagePath.isEmpty {
                    Spacer()
                    Button {
                        params.imagePath = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove reference image")
                }
            }

            if params.imagePath.isEmpty {
                HStack(spacing: 6) {
                    Button { browseImage() } label: {
                        HStack {
                            Image(systemName: "photo.badge.plus")
                            Text("Choose Image…")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Choose reference image")
                    .accessibilityHint("Opens a file picker to select an image for img2img generation")

                    if clipboardHasImage {
                        Button { pasteImage() } label: {
                            Image(systemName: "doc.on.clipboard")
                                .padding(.vertical, 6)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut("v", modifiers: .command)
                        .accessibilityLabel("Paste image from clipboard")
                        .help("Paste image from clipboard (⌘V)")
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if let img = NSImage(contentsOfFile: params.imagePath) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: params.imagePath).lastPathComponent)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text("Strength").font(.caption2).foregroundStyle(.secondary)
                            InfoButton(
                                title: "Image Strength",
                                description: "How faithfully the output follows the original image."
                                    + " High strength (75–95%) = stays close to the original, subtle"
                                    + " changes. Low strength (15–30%) = more creative freedom, prompt"
                                    + " dominates. Think of it as image preservation, not prompt strength."
                            )
                            Slider(value: $params.imageStrength, in: 0.05 ... 0.95)
                                .onChange(of: params.imageStrength) { _, v in params.imageStrength = round(v / 0.05) * 0.05 }
                                .accessibilityLabel("Image strength")
                                .accessibilityValue(String(format: "%.0f%%", params.imageStrength * 100))
                                .accessibilityHint("How much the reference image influences the output. Lower = more faithful to original.")
                            Text(String(format: "%.0f%%", params.imageStrength * 100))
                                .font(.caption2).monospacedDigit().frame(width: 30)
                        }
                    }
                }
            }
        }
        .dropDestination(for: String.self, action: { paths, _ in
            guard let path = paths.first else { return false }
            let ext = (path as NSString).pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else { return false }
            params.imagePath = path
            return true
        }, isTargeted: { isImageDropTargeted = $0 })
        .onDrop(of: [.fileURL], isTargeted: $isImageDropTargeted) { providers in
            providers.first?.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                guard Self.imageExtensions.contains(ext) else { return }
                DispatchQueue.main.async { self.params.imagePath = url.path }
            }
            return true
        }
        .dropHighlight(isImageDropTargeted)
    }

    // MARK: - Board row

    private var boardRow: some View {
        HStack(spacing: 6) {
            FolderComboBox(
                text: $params.board,
                options: gallery.boards.filter { $0 != "Default" },
                placeholder: "Default"
            )
            .accessibilityLabel("Output group")
            .accessibilityHint("Subfolder name for organizing generated images")
        }
    }

    // MARK: - Helpers

    private var clipboardHasImage: Bool {
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
            || pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .compactMap { $0 as? URL }
            .first { Self.imageExtensions.contains($0.pathExtension.lowercased()) } != nil
    }

    // MARK: - Mode picker (Generate vs Edit, Flux.2 only)

    private var modePickerRow: some View {
        let info = "Generate: create or modify images from text + optional reference"
            + " (img2img).\n\nEdit: compose multiple images with instructions — e.g. two"
            + " images plus \"make her wear the glasses\". Works with a single image too."
        return SectionContainerView(title: "Generation Mode", info: info) {
            Picker("", selection: $params.isEditMode) {
                Text("Generate").tag(false)
                Text("Edit").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .onChange(of: params.isEditMode) { _, editing in
                if editing {
                    params.imagePath = ""
                } else {
                    params.editImagePaths = []
                }
            }
        }
    }

    // MARK: - Edit images section (multi-image list)

    private var editImagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if !params.editImagePaths.isEmpty {
                    Button {
                        params.editImagePaths = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove all images")
                }
            }

            if !params.editImagePaths.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(params.editImagePaths.enumerated()), id: \.offset) { idx, path in
                        editImageRow(path: path, index: idx)
                    }
                    .onMove { from, to in params.editImagePaths.move(fromOffsets: from, toOffset: to) }
                }
            }

            HStack(spacing: 6) {
                Button {
                    browseEditImages()
                } label: {
                    HStack {
                        Image(systemName: "photo.badge.plus")
                        Text(params.editImagePaths.isEmpty ? "Choose Image…" : "Add Image…")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Add reference image")

                if clipboardHasImage {
                    Button { pasteEditImage() } label: {
                        Image(systemName: "doc.on.clipboard")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("v", modifiers: .command)
                    .accessibilityLabel("Paste image from clipboard")
                    .help("Paste image from clipboard (⌘V)")
                }
            }
        }
        .dropDestination(for: String.self, action: { paths, _ in
            let valid = paths.filter { Self.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            guard !valid.isEmpty else { return false }
            for path in valid where !params.editImagePaths.contains(path) {
                params.editImagePaths.append(path)
            }
            return true
        }, isTargeted: { isEditDropTargeted = $0 })
        .onDrop(of: [.fileURL], isTargeted: $isEditDropTargeted) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async {
                        if !self.params.editImagePaths.contains(url.path) { self.params.editImagePaths.append(url.path) }
                    }
                }
            }
            return true
        }
        .dropHighlight(isEditDropTargeted)
    }

    private func styleChip(name: String, templateID: UUID?) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(.system(size: 10))
                .lineLimit(1)
            if let id = templateID {
                Button {
                    settings.activeTemplateIDs.removeAll { $0 == id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .foregroundStyle(Color.accentColor)
    }

    private func promptField(
        text: Binding<String>,
        placeholder: String,
        label: String,
        hint: String,
        ghostSuffix: String = ""
    ) -> some View {
        GrowingPromptField(
            text: text,
            placeholder: placeholder,
            label: label,
            hint: hint,
            ghostSuffix: ghostSuffix
        )
    }

    private func sectionHeader(_ title: String, info: String?) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            if let info {
                InfoButton(title: title, description: info)
            }
        }
    }

    /// Resolves an image path from the general pasteboard, preferring an on-disk file
    /// URL and otherwise saving raw image data to a temp PNG named with `tempPrefix`.
    private func imagePathFromPasteboard(tempPrefix: String) -> String? {
        let pb = NSPasteboard.general
        // Prefer a file URL so we keep the original file on disk
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            return url.path
        }
        // Fall back to raw image data — save to a temp PNG
        guard let image = NSImage(pasteboard: pb) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tempPrefix)-\(Int(Date().timeIntervalSince1970)).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: tmp)
        return tmp.path
    }

    private func pasteImage() {
        if let path = imagePathFromPasteboard(tempPrefix: "pasted-image") {
            params.imagePath = path
        }
    }

    private func browseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.title = "Select Reference Image"
        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                params.imagePath = url.path
            }
        }
    }

    private func editImageRow(path: String, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption).foregroundStyle(.tertiary)
                .help("Drag to reorder")
            if let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                params.editImagePaths.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove image")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func browseEditImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.title = "Select Images"
        if panel.runModal() == .OK {
            let valid = panel.urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            for url in valid where !params.editImagePaths.contains(url.path) {
                params.editImagePaths.append(url.path)
            }
        }
    }

    private func pasteEditImage() {
        guard let path = imagePathFromPasteboard(tempPrefix: "pasted-edit") else { return }
        if !params.editImagePaths.contains(path) { params.editImagePaths.append(path) }
    }
}

private extension View {
    /// Highlights a drop target with an accent-colored rounded overlay while `active`.
    func dropHighlight(_ active: Bool) -> some View {
        overlay {
            if active {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.45))
                    .padding(-10)
                    .allowsHitTesting(false)
            }
        }
    }
}
