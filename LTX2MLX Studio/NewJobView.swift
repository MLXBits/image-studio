internal import SwiftUI
internal import UniformTypeIdentifiers


// MARK: - Aspect ratio presets

enum AspectPreset: String, CaseIterable, Identifiable {
    case free   = "Free"
    case w21h9  = "21:9"
    case w16h9  = "16:9"
    case w3h2   = "3:2"
    case w4h3   = "4:3"
    case sq1h1  = "1:1"
    case w3h4   = "3:4"
    case w2h3   = "2:3"
    case w9h16  = "9:16"
    case w9h21  = "9:21"

    var id: String { rawValue }

    var ratio: Double? {
        switch self {
        case .free:  return nil
        case .w21h9: return 21.0 / 9.0
        case .w16h9: return 16.0 / 9.0
        case .w3h2:  return 3.0 / 2.0
        case .w4h3:  return 4.0 / 3.0
        case .sq1h1: return 1.0
        case .w3h4:  return 3.0 / 4.0
        case .w2h3:  return 2.0 / 3.0
        case .w9h16: return 9.0 / 16.0
        case .w9h21: return 9.0 / 21.0
        }
    }

    var swapped: AspectPreset {
        switch self {
        case .free:  return .free
        case .w21h9: return .w9h21
        case .w16h9: return .w9h16
        case .w3h2:  return .w2h3
        case .w4h3:  return .w3h4
        case .sq1h1: return .sq1h1
        case .w3h4:  return .w4h3
        case .w2h3:  return .w3h2
        case .w9h16: return .w16h9
        case .w9h21: return .w21h9
        }
    }

    // Detect closest preset for given dimensions (within 6% tolerance).
    static func detect(w: Int, h: Int) -> AspectPreset {
        let ratio = Double(w) / Double(h)
        guard let closest = AspectPreset.allCases
            .filter({ $0 != .free })
            .min(by: { abs(($0.ratio ?? 1) - ratio) < abs(($1.ratio ?? 1) - ratio) }),
              let r = closest.ratio,
              abs(r - ratio) / ratio < 0.06
        else { return .free }
        return closest
    }
}

// MARK: - Shared dimension picker (InvokeAI-style)

struct DimensionPickerView: View {
    @Binding var width: Int
    @Binding var height: Int
    var imagePath: String = ""

    @State private var selectedAspect: AspectPreset
    @State private var aspectLocked: Bool

    init(width: Binding<Int>, height: Binding<Int>, imagePath: String = "") {
        _width  = width
        _height = height
        self.imagePath = imagePath
        let asp = AspectPreset.detect(w: width.wrappedValue, h: height.wrappedValue)
        _selectedAspect = State(initialValue: asp)
        _aspectLocked   = State(initialValue: asp != .free)
    }

    // MARK: - Computed helpers

    private var aspectLabel: String {
        if selectedAspect != .free { return selectedAspect.rawValue }
        let g = gcdOf(width, height)
        return "\(width / g):\(height / g)"
    }

    private var effectiveRatio: Double? {
        guard aspectLocked else { return nil }
        return selectedAspect.ratio
    }

    private var canFitToImage: Bool {
        guard !imagePath.isEmpty else { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: imagePath, isDirectory: &isDir)
        return !isDir.boolValue
    }

    // MARK: - Body

    var body: some View {
        Group {
            // --- Info badges ---
            HStack(spacing: 6) {
                Text("\(width)×\(height)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
                Text(aspectLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                if aspectLocked && selectedAspect != .free {
                    Text("LOCKED")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
            }

            // --- Controls row ---
            HStack(spacing: 8) {
                Text("Aspect").foregroundStyle(.secondary).font(.callout)

                Picker("", selection: $selectedAspect) {
                    ForEach(AspectPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 88)

                Button(action: swapDimensions) {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Swap width and height")

                Button { aspectLocked.toggle() } label: {
                    Image(systemName: aspectLocked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(.plain)
                .foregroundStyle(aspectLocked && selectedAspect != .free ? Color.orange : Color.secondary)
                .help(aspectLocked ? "Unlock aspect ratio" : "Lock aspect ratio")
                .disabled(selectedAspect == .free)

                Button(action: fitToImage) {
                    Image(systemName: "wand.and.sparkles")
                }
                .buttonStyle(.plain)
                .foregroundStyle(canFitToImage ? Color.accentColor : Color.secondary)
                .help("Fit dimensions to image")
                .disabled(!canFitToImage)

                Spacer()

                // Aspect ratio preview box
                Canvas { ctx, size in
                    let ratio = CGFloat(width) / CGFloat(height)
                    let maxW = size.width, maxH = size.height
                    let bw: CGFloat, bh: CGFloat
                    if ratio > maxW / maxH { bw = maxW; bh = maxW / ratio } else { bh = maxH; bw = maxH * ratio }
                    let ox = (maxW - bw) / 2, oy = (maxH - bh) / 2
                    let rect = CGRect(x: ox, y: oy, width: bw, height: bh)
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 3),
                               with: .color(.secondary), lineWidth: 1.5)
                    for i in 1...2 {
                        let f = CGFloat(i) / 3
                        ctx.stroke(Path { p in
                            p.move(to: CGPoint(x: ox, y: oy + bh * f))
                            p.addLine(to: CGPoint(x: ox + bw, y: oy + bh * f))
                        }, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
                        ctx.stroke(Path { p in
                            p.move(to: CGPoint(x: ox + bw * f, y: oy))
                            p.addLine(to: CGPoint(x: ox + bw * f, y: oy + bh))
                        }, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
                    }
                }
                .frame(width: 52, height: 52)
            }
            .onChange(of: selectedAspect) { _, newVal in applyAspect(newVal) }

            // --- Width ---
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: widthSliderBinding, in: 256...1280, step: 32)
                    TextField("", value: widthTextBinding, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                    Text("px").foregroundStyle(.secondary)
                }
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            } label: {
                Text("Width")
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            }

            // --- Height ---
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: heightSliderBinding, in: 256...1280, step: 32)
                    TextField("", value: heightTextBinding, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                    Text("px").foregroundStyle(.secondary)
                }
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            } label: {
                Text("Height")
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            }
        }
    }

    // MARK: - Slider bindings

    private var widthSliderBinding: Binding<Double> {
        Binding(
            get: { Double(width) },
            set: { newVal in
                width = clampDim(snapTo32(newVal))
                if let ratio = effectiveRatio {
                    height = clampDim(snapTo32(Double(width) / ratio))
                }
            }
        )
    }

    private var heightSliderBinding: Binding<Double> {
        Binding(
            get: { Double(height) },
            set: { newVal in
                height = clampDim(snapTo32(newVal))
                if let ratio = effectiveRatio {
                    width = clampDim(snapTo32(Double(height) * ratio))
                }
            }
        )
    }

    // Int-typed bindings for text fields: snap+clamp on every commit (Enter or focus-loss).
    private var widthTextBinding: Binding<Int> {
        Binding(
            get: { width },
            set: { newVal in
                width = clampDim(snapTo32(Double(newVal)))
                if let ratio = effectiveRatio {
                    height = clampDim(snapTo32(Double(width) / ratio))
                }
            }
        )
    }

    private var heightTextBinding: Binding<Int> {
        Binding(
            get: { height },
            set: { newVal in
                height = clampDim(snapTo32(Double(newVal)))
                if let ratio = effectiveRatio {
                    width = clampDim(snapTo32(Double(height) * ratio))
                }
            }
        )
    }

    // MARK: - Actions

    private func applyAspect(_ preset: AspectPreset) {
        if let ratio = preset.ratio {
            aspectLocked = true
            height = clampDim(snapTo32(Double(width) / ratio))
        } else {
            aspectLocked = false
        }
    }

    private func swapDimensions() {
        Swift.swap(&width, &height)
        if selectedAspect != .free {
            selectedAspect = selectedAspect.swapped
            // onChange fires applyAspect which re-derives height from the swapped width
            // using the new ratio — this produces the same values since width/height are
            // already swapped and both are multiples of 32.
        }
    }

    private func fitToImage() {
        guard canFitToImage, let img = NSImage(contentsOfFile: imagePath) else { return }
        let iw = img.size.width, ih = img.size.height
        guard iw > 0, ih > 0 else { return }
        let scale = min(1280.0 / iw, 1280.0 / ih, 1.0)
        width  = max(256, clampDim(snapTo32(iw * scale)))
        height = max(256, clampDim(snapTo32(ih * scale)))
        let asp = AspectPreset.detect(w: width, h: height)
        aspectLocked = false        // prevent applyAspect from clobbering fitted height
        selectedAspect = asp
        aspectLocked = asp != .free
    }

    // MARK: - Math helpers

    private func snapTo32(_ v: Double) -> Int {
        guard v.isFinite else { return 256 }
        return Int((v / 32).rounded() * 32)
    }

    private func clampDim(_ v: Int) -> Int { max(256, min(1280, v)) }

    private func gcdOf(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcdOf(b, a % b) }
}

// MARK: - Thumbnail / clipboard helpers

func makeThumbnailData(from path: String, maxPixels: CGFloat = 144) -> Data? {
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    let s = img.size
    guard s.width > 0, s.height > 0 else { return nil }
    let r = min(maxPixels / s.width, maxPixels / s.height)
    let newSize = CGSize(width: s.width * r, height: s.height * r)
    let thumb = NSImage(size: newSize)
    thumb.lockFocus()
    img.draw(in: CGRect(origin: .zero, size: newSize))
    thumb.unlockFocus()
    return thumb.tiffRepresentation
        .flatMap { NSBitmapImageRep(data: $0) }
        .flatMap { $0.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) }
}

func pasteImageFromClipboard() -> (path: String, thumbnailData: Data?)? {
    let pb = NSPasteboard.general
    let urlOpts: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier]
    ]
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: urlOpts) as? [URL],
       let url = urls.first {
        return (url.path, makeThumbnailData(from: url.path))
    }
    if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
       let image = images.first,
       let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ltx_paste_\(UUID().uuidString).png")
        try? png.write(to: url)
        return (url.path, makeThumbnailData(from: url.path))
    }
    return nil
}

// MARK: - AdditionalAnchorRow

private struct AdditionalAnchorRow: View {
    @Binding var anchor: AdditionalImageEntry
    let maxFrameIdx: Int
    private var valid: Bool { anchor.frameIdx >= 1 && anchor.frameIdx <= maxFrameIdx }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Image path", text: $anchor.path).textFieldStyle(.roundedBorder)
                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url { anchor.path = url.path }
                }
            }
            HStack(spacing: 12) {
                LabeledContent("Frame") {
                    HStack(spacing: 4) {
                        TextField("", value: $anchor.frameIdx, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(valid ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red))
                        if !valid {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).help("Must be 1–\(maxFrameIdx)")
                        }
                    }
                }
                LabeledContent("Strength") {
                    HStack(spacing: 6) {
                        Slider(value: $anchor.strength, in: 0.0...1.0, step: 0.05).frame(width: 100)
                        TextField("", value: $anchor.strength, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing).frame(width: 48).textFieldStyle(.roundedBorder)
                    }
                }
            }.font(.callout)
        }.padding(.vertical, 2)
    }
}

// MARK: - View

struct NewJobView: View {
    var prefillJob: (any Job)?
    let onAdd: ([any Job]) -> Void
    let onAddAndStart: ([any Job]) -> Void
    let onCancel: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(JobStore.self) private var store

    private static let ud = UserDefaults.standard
    @State private var jobKind: JobKind = .video
    @State private var name             = ""
    @State private var prompt           = ""
    @State private var imagePath        = ""
    @State private var thumbnailData: Data?

    // Dimensions — shared; DimensionPickerView handles aspect locking
    @State private var width  = { let v = Self.ud.integer(forKey: "defaultWidth");  return v > 0 ? v : 704 }()
    @State private var height = { let v = Self.ud.integer(forKey: "defaultHeight"); return v > 0 ? v : 480 }()

    // Video-specific
    @State private var duration  = (ud.object(forKey: "defaultDuration")  as? Double) ?? 5.0
    @State private var frameRate = (ud.object(forKey: "defaultFrameRate") as? Int) ?? 25
    @State private var seed           = (ud.object(forKey: "defaultSeed")      as? Int) ?? -1
    @State private var mode           = GenerationMode(rawValue: ud.string(forKey: "defaultMode") ?? "") ?? .distilled
    @State private var imageStrength: Double = 0.95
    @State private var enableTeacache: Bool = false
    @State private var teacacheThresh: Double = 0.5
    @State private var loras: [LoraEntry] = []
    @State private var additionalImages: [AdditionalImageEntry] = []
    @State private var modelPath: String = ""
    @State private var steps: Int = 8
    @State private var stage1Steps: Int = 30
    @State private var stage2Steps: Int = 3

    // Image-specific
    @State private var imageSteps: Int = 4
    @State private var imageGuidance: Double = 1.0
    @State private var imageImageStrength: Double = 0.4
    @State private var imageLowRam: Bool = false
    @State private var imageQuantize: Int = 0
    @State private var imageNegativePrompt: String = ""
    @State private var imageLoras: [LoraEntry] = []
    @State private var imageFolder: String = "Default"
    @State private var videoFolder: String = ""

    private var existingImageFolders: [String] {
        Array(Set(store.jobs.compactMap { ($0 as? ImageJob)?.folder }.filter { !$0.isEmpty })).sorted()
    }

    private var existingVideoFolders: [String] {
        Array(Set(store.jobs.compactMap { ($0 as? VideoJob)?.folder }.filter { !$0.isEmpty })).sorted()
    }

    private var frames: Int { (Int(duration * Double(frameRate)) / 8) * 8 + 1 }

    private var isReadyToSubmit: Bool {
        let hasPrompt    = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let mfluxOK      = jobKind == .video || !settings.mfluxPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let fluxModelOK  = jobKind == .video || !settings.fluxModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasPrompt && mfluxOK && fluxModelOK
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Job") {
                    Picker("Type", selection: $jobKind) {
                        Text("Video").tag(JobKind.video)
                        Text("Image").tag(JobKind.image)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    TextField("Name", text: $name, prompt: Text("Name (optional)"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }

                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .writingToolsBehavior(.complete)
                        .frame(minHeight: 80)
                        .padding(.init(top: 8, leading: 3, bottom: 0, trailing: 0))
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("Describe the \(jobKind == .video ? "video" : "image") you want to generate…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 8)
                                    .padding(.top, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section(jobKind == .video ? "First Image — frame 0 (optional)" : "Reference Image (optional)") {
                    HStack(spacing: 8) {
                        if let data = thumbnailData, let img = NSImage(data: data) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 32)
                                .cornerRadius(3)
                        }
                        TextField("", text: $imagePath,
                                  prompt: Text(jobKind == .video ? "Path to image or folder" : "Path to reference image"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Button("Browse") { pickImage() }
                        Button("Paste") {
                            if let result = pasteImageFromClipboard() {
                                imagePath = result.path
                                thumbnailData = result.thumbnailData
                            }
                        }
                        if !imagePath.isEmpty {
                            Button {
                                imagePath = ""
                                thumbnailData = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !imagePath.isEmpty && jobKind == .video && (mode == .twoStage || mode == .twoStageHQ || mode == .distilled) {
                        LabeledContent {
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 8) {
                                    Slider(value: $imageStrength, in: 0.0...1.0, step: 0.05)
                                    TextField("", value: $imageStrength, format: .number.precision(.fractionLength(2)))
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 52)
                                        .textFieldStyle(.roundedBorder)
                                }
                                HStack(spacing: 0) {
                                    Text("Ignore image")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Text("0.95 for AI images")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("True to image")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        } label: {
                            Text("Strength")
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        }
                    }
                    if !imagePath.isEmpty && jobKind == .image {
                        LabeledContent {
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 8) {
                                    Slider(value: $imageImageStrength, in: 0.0...1.0, step: 0.05)
                                    TextField("", value: $imageImageStrength, format: .number.precision(.fractionLength(2)))
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 52)
                                        .textFieldStyle(.roundedBorder)
                                }
                                HStack(spacing: 0) {
                                    Text("No influence")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Text("Default 0.4")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Full influence")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        } label: {
                            Text("Strength")
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        }
                    }
                }

                if jobKind == .video { additionalAnchorsSection }

                Section("Image Size") {
                    DimensionPickerView(width: $width, height: $height, imagePath: imagePath)
                }

                if jobKind == .video {
                    Section("Timing") {
                        LabeledContent {
                            HStack(spacing: 8) {
                                Slider(value: $duration, in: 1...20, step: 0.5)
                                TextField("", value: $duration, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 52)
                                    .textFieldStyle(.roundedBorder)
                                Text("sec").foregroundStyle(.secondary)
                            }
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        } label: {
                            Text("Duration")
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        }
                        LabeledContent {
                            HStack(spacing: 8) {
                                Slider(
                                    value: Binding(
                                        get: { Double(frameRate) },
                                        set: { frameRate = Int($0.rounded()) }
                                    ),
                                    in: 24...60, step: 1
                                )
                                TextField("", value: $frameRate, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 52)
                                    .textFieldStyle(.roundedBorder)
                                Text("fps").foregroundStyle(.secondary)
                            }
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        } label: {
                            Text("Frame rate")
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        }
                        LabeledContent("Frames") {
                            HStack(spacing: 8) {
                                Text("\(frames)").foregroundStyle(.secondary)
                                Text(estimatedTimeLabel)
                                    .foregroundStyle(.tertiary)
                                    .font(.caption)
                            }
                        }
                    }

                    Section("Generation") {
                        if settings.modelPaths.count >= 2 {
                            Picker("Model", selection: $modelPath) {
                                ForEach(settings.modelPaths) { entry in
                                    Text(entry.displayName).tag(entry.path)
                                }
                            }
                        }
                        Picker("Mode", selection: $mode) {
                            ForEach(GenerationMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .onChange(of: mode) { old, new in
                            let oldDefault = (old == .twoStageHQ) ? 15 : 30
                            let newDefault = (new == .twoStageHQ) ? 15 : 30
                            if stage1Steps == oldDefault { stage1Steps = newDefault }
                        }
                        LabeledContent {
                            HStack {
                                TextField("", value: $seed, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 120)
                                if seed != -1 {
                                    Button { seed = -1 } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Text("-1 = random")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        } label: {
                            Text("Seed")
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                        }
                    }
                    if mode == .oneStage {
                        Section("Steps") {
                            LabeledContent {
                                HStack(spacing: 8) {
                                    Slider(value: Binding(get: { Double(steps) }, set: { steps = max(1, Int($0)) }),
                                           in: 1...100, step: 1)
                                    TextField("", value: $steps, format: .number)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 52)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                            } label: {
                                Text("Steps")
                                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                            }
                        }
                    }
                    if mode == .twoStage || mode == .twoStageHQ {
                        Section("Steps") {
                            LabeledContent {
                                HStack(spacing: 8) {
                                    Slider(value: Binding(get: { Double(stage1Steps) }, set: { stage1Steps = max(1, Int($0)) }),
                                           in: 1...60, step: 1)
                                    TextField("", value: $stage1Steps, format: .number)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 52)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                            } label: {
                                Text("Stage 1")
                                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                            }
                            LabeledContent {
                                HStack(spacing: 8) {
                                    Slider(value: Binding(get: { Double(stage2Steps) }, set: { stage2Steps = max(1, Int($0)) }),
                                           in: 1...10, step: 1)
                                    TextField("", value: $stage2Steps, format: .number)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 52)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                            } label: {
                                Text("Stage 2")
                                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                            }
                        }
                    }
                    if mode == .twoStage || mode == .twoStageHQ {
                        Section("Performance") {
                            Toggle("TeaCache", isOn: $enableTeacache)
                            if enableTeacache {
                                LabeledContent {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Slider(value: $teacacheThresh, in: 0.1...1.5, step: 0.05)
                                            TextField("", value: $teacacheThresh, format: .number.precision(.fractionLength(2)))
                                                .multilineTextAlignment(.trailing)
                                                .frame(width: 52)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                        HStack(spacing: 0) {
                                            Text("Conservative")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Spacer()
                                            Text("~1.5× at 0.5 · ~2× at 1.0")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text("Aggressive")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                                } label: {
                                    Text("Threshold")
                                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                                }
                            }
                        }
                    }
                    GalleryFolderSectionView(folder: $videoFolder, existingFolders: existingVideoFolders)
                    LoraSectionView(loras: $loras)
                } else {
                    NewImageJobFormSections(
                        steps: $imageSteps, guidance: $imageGuidance, seed: $seed,
                        quantize: $imageQuantize, lowRam: $imageLowRam, loras: $imageLoras,
                        folder: $imageFolder, existingFolders: existingImageFolders
                    )
                }
            }
            .formStyle(.grouped)
            .onAppear {
                duration   = settings.defaultDuration
                frameRate  = settings.defaultFrameRate
                seed       = settings.defaultSeed
                if let m = GenerationMode(rawValue: settings.defaultMode) { mode = m }
                imageSteps          = settings.defaultImageSteps
                imageGuidance       = settings.defaultImageGuidance
                imageLowRam         = settings.defaultImageLowRam
                imageQuantize       = settings.defaultImageQuantize
                imageNegativePrompt = settings.defaultImageNegativePrompt
                imageFolder         = settings.defaultImageFolder
                imageLoras          = settings.defaultImageLoras
                if jobKind == .image { seed = settings.defaultImageSeed }
                loras               = settings.defaultLoras
                modelPath  = settings.modelPaths.first?.path ?? ""
                if let job = prefillJob { applyPrefill(job) }
            }
            .onChange(of: settings.defaultLoras) { _, newLoras in
                var stateByPath: [String: (enabled: Bool, strength: Double)] = [:]
                for lora in loras { stateByPath[lora.path] = (lora.enabled, lora.strength) }
                loras = newLoras.map { lora in
                    var entry = lora
                    if let saved = stateByPath[lora.path] {
                        entry.enabled = saved.enabled
                        entry.strength = saved.strength
                    }
                    return entry
                }
            }
            .onChange(of: settings.defaultImageLoras) { _, newLoras in
                var stateByPath: [String: (enabled: Bool, strength: Double)] = [:]
                for lora in imageLoras { stateByPath[lora.path] = (lora.enabled, lora.strength) }
                imageLoras = newLoras.map { lora in
                    var entry = lora
                    if let saved = stateByPath[lora.path] {
                        entry.enabled = saved.enabled
                        entry.strength = saved.strength
                    }
                    return entry
                }
            }

            Divider()

            ZStack {
                HStack {
                    Button("Cancel") { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                }
                HStack(spacing: 8) {
                    if jobKind == .video {
                        Menu {
                            Button("Add 3 to Queue") {
                                saveDefaults()
                                onAdd((0..<3).flatMap { _ in expandedJobs() })
                            }
                            Button("Add 5 to Queue") {
                                saveDefaults()
                                onAdd((0..<5).flatMap { _ in expandedJobs() })
                            }
                            Button("Add 10 to Queue") {
                                saveDefaults()
                                onAdd((0..<10).flatMap { _ in expandedJobs() })
                            }
                        } label: {
                            Text("Add to Queue")
                        } primaryAction: {
                            saveDefaults()
                            onAdd(expandedJobs())
                        }
                        .disabled(!isReadyToSubmit)
                    } else {
                        Button("Add to Queue") {
                            saveDefaults()
                            onAdd(expandedJobs())
                        }
                        .disabled(!isReadyToSubmit)
                    }
                    Button("Start Job") {
                        saveDefaults()
                        onAddAndStart(expandedJobs())
                    }
                    .keyboardShortcut(.defaultAction)
                    .tint(.green)
                    .disabled(!isReadyToSubmit)
                }
            }
            .padding()
        }
        .onPasteCommand(of: [.image, .fileURL]) { _ in
            if let result = pasteImageFromClipboard() {
                imagePath = result.path
                thumbnailData = result.thumbnailData
            }
        }
    }

    // MARK: - Job creation

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "webp", "bmp", "gif"
    ]

    private func makeJob(imagePath: String? = nil, thumbnailData: Data? = nil, nameSuffix: String? = nil) -> any Job {
        let resolvedPath  = imagePath ?? self.imagePath
        let resolvedThumb = thumbnailData ?? self.thumbnailData
        var jobName = name
        if let suffix = nameSuffix {
            jobName = name.isEmpty ? suffix : "\(name) – \(suffix)"
        }
        switch jobKind {
        case .video:
            let job = VideoJob(
                name: jobName, prompt: prompt, imagePath: resolvedPath,
                width: width, height: height,
                durationSeconds: duration, frameRate: frameRate,
                seed: seed, mode: mode, lowRam: settings.defaultLowRam,
                imageStrength: imageStrength,
                enableTeacache: enableTeacache,
                teacacheThresh: teacacheThresh,
                loras: loras,
                additionalImages: additionalImages.filter { !$0.path.isEmpty },
                modelPath: modelPath,
                steps: steps,
                stage1Steps: stage1Steps,
                stage2Steps: stage2Steps,
                folder: videoFolder
            )
            job.thumbnailData = resolvedThumb
            return job
        case .image:
            let job = ImageJob(
                name: jobName, prompt: prompt,
                negativePrompt: imageNegativePrompt,
                imagePath: resolvedPath,
                width: width, height: height,
                seed: seed, steps: imageSteps,
                guidance: imageGuidance,
                imageStrength: imageImageStrength,
                lowRam: imageLowRam,
                quantize: imageQuantize,
                loras: imageLoras,
                folder: imageFolder
            )
            job.thumbnailData = resolvedThumb
            return job
        }
    }

    private func expandedJobs() -> [any Job] {
        // Folder expansion (batch I2V) only applies to video jobs
        guard jobKind == .video else { return [makeJob()] }

        var isDir: ObjCBool = false
        guard !imagePath.isEmpty,
              FileManager.default.fileExists(atPath: imagePath, isDirectory: &isDir),
              isDir.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: URL(fileURLWithPath: imagePath),
                  includingPropertiesForKeys: nil
              ) else { return [makeJob()] }

        let images = contents
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !images.isEmpty else { return [makeJob()] }

        return images.map { url in
            makeJob(
                imagePath: url.path,
                thumbnailData: makeThumbnailData(from: url.path),
                nameSuffix: url.deletingPathExtension().lastPathComponent
            )
        }
    }

    private func saveDefaults() {
        Self.ud.set(width, forKey: "defaultWidth")
        Self.ud.set(height, forKey: "defaultHeight")
        switch jobKind {
        case .video:
            settings.defaultDuration  = duration
            settings.defaultFrameRate = frameRate
            settings.defaultSeed      = seed
            settings.defaultMode      = mode.rawValue
        case .image:
            settings.defaultImageSteps          = imageSteps
            settings.defaultImageGuidance       = imageGuidance
            settings.defaultImageLowRam         = imageLowRam
            settings.defaultImageQuantize       = imageQuantize
            settings.defaultImageNegativePrompt = imageNegativePrompt
            settings.defaultImageFolder         = imageFolder
            settings.defaultImageSeed           = seed
        }
    }

    private func applyPrefill(_ job: any Job) {
        jobKind = job.jobKind
        name = job.name
        prompt = job.prompt
        imagePath = job.imagePath
        thumbnailData = job.thumbnailData
        width = job.width
        height = job.height
        seed = job.resolvedSeed ?? job.seed
        switch job.jobKind {
        case .video:
            guard let vj = job as? VideoJob else { return }
            duration = vj.durationSeconds
            frameRate = vj.frameRate
            mode = vj.mode
            imageStrength = vj.imageStrength
            enableTeacache = vj.enableTeacache
            teacacheThresh = vj.teacacheThresh
            loras = vj.loras
            modelPath = vj.modelPath
            steps     = vj.steps
            stage1Steps = vj.stage1Steps
            stage2Steps = vj.stage2Steps
            videoFolder = vj.folder
        case .image:
            guard let ij = job as? ImageJob else { return }
            imageSteps          = ij.steps
            imageGuidance       = ij.guidance
            imageImageStrength  = ij.imageStrength
            imageLowRam         = ij.lowRam
            imageQuantize       = ij.quantize
            imageNegativePrompt = ij.negativePrompt
            imageLoras          = ij.loras
            imageFolder         = ij.folder
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = jobKind == .video
        if panel.runModal() == .OK, let url = panel.url {
            imagePath = url.path
            if url.hasDirectoryPath {
                thumbnailData = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil
                ))?
                .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
                .flatMap { makeThumbnailData(from: $0.path) }
            } else {
                thumbnailData = makeThumbnailData(from: url.path)
            }
        }
    }

}

// MARK: - Time estimate helpers (extracted to keep NewJobView under the line limit)

private extension NewJobView {
    /// Seconds per denoising step as a function of token count.
    /// Calibrated to Q4 model on M5 Pro (307 GB/s): 3185 tokens → 7.96 s/step, 12740 → 45.7 s/step.
    static func stepSeconds(_ nv: Int) -> Double {
        let n = Double(nv)
        return 1.516e-7 * n * n + 2.00e-3 * n
    }

    var estimatedSeconds: Double {
        let latentT = (frames - 1) / 8 + 1
        let hHalf = (height / 2) / 32
        let wHalf = (width / 2) / 32
        let nvHalf = hHalf * wHalf * latentT
        let nvStage2 = (hHalf * 2) * (wHalf * 2) * latentT
        let nvFull = (height / 32) * (width / 32) * latentT

        let path = (modelPath.isEmpty ? settings.modelPaths.first?.path ?? "" : modelPath).lowercased()
        let variantFactor: Double = path.contains("q8") ? 2.0 : path.contains("bf16") ? 3.5 : 1.0

        let transformer: Double
        switch mode {
        case .distilled:
            transformer = 8.0 * Self.stepSeconds(nvHalf) + 3.0 * Self.stepSeconds(nvStage2)
        case .twoStage:
            transformer = Double(stage1Steps) * 2 * Self.stepSeconds(nvHalf)
                + Double(stage2Steps) * Self.stepSeconds(nvStage2)
        case .twoStageHQ:
            transformer = Double(stage1Steps) * 4 * Self.stepSeconds(nvHalf)
                + Double(stage2Steps) * Self.stepSeconds(nvStage2)
        case .oneStage:
            transformer = Double(steps) * 2 * Self.stepSeconds(nvFull)
        }

        let vae = 3.96e-7 * Double(frames) * Double(width) * Double(height)
        return (transformer * variantFactor) + vae + 5.3
    }

    var estimatedTimeLabel: String {
        let secs = estimatedSeconds
        guard secs > 0 else { return "" }
        let mins = Int(secs) / 60
        let sec = Int(secs) % 60
        if mins == 0 { return "~\(sec)s" }
        if sec == 0 { return "~\(mins) min" }
        return "~\(mins)m \(sec)s"
    }
}

// MARK: - Additional anchors section (extracted to keep NewJobView body under the line limit)

private extension NewJobView {
    @ViewBuilder var additionalAnchorsSection: some View {
        Section(header: HStack {
            Text("Additional Anchors (optional)")
            Spacer()
            Button {
                additionalImages.append(AdditionalImageEntry(frameIdx: frames - 1))
            } label: {
                Label("Add", systemImage: "plus.circle").labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }) {
            if additionalImages.isEmpty {
                Text("Use \"+\" to anchor a frame other than 0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($additionalImages) { $anchor in
                AdditionalAnchorRow(anchor: $anchor, maxFrameIdx: frames - 1)
            }
            .onDelete { additionalImages.remove(atOffsets: $0) }
        }
    }
}

// MARK: - Image job form sections (extracted to keep NewJobView under the line limit)

private struct NewImageJobFormSections: View {
    @Binding var steps: Int
    @Binding var guidance: Double
    @Binding var seed: Int
    @Binding var quantize: Int
    @Binding var lowRam: Bool
    @Binding var loras: [LoraEntry]
    @Binding var folder: String
    var existingFolders: [String]

    var body: some View {
        GalleryFolderSectionView(folder: $folder, existingFolders: existingFolders)
        Section("Generation") {
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(steps) }, set: { steps = max(1, Int($0)) }),
                           in: 1...50, step: 1)
                    TextField("", value: $steps, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .textFieldStyle(.roundedBorder)
                }
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            } label: {
                Text("Steps").alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: $guidance, in: 1.0...15.0, step: 0.5)
                    TextField("", value: $guidance, format: .number.precision(.fractionLength(1)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .textFieldStyle(.roundedBorder)
                }
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            } label: {
                Text("Guidance").alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            }
            LabeledContent {
                HStack {
                    TextField("", value: $seed, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                    if seed != -1 {
                        Button { seed = -1 } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("-1 = random").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            } label: {
                Text("Seed").alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            }
            Picker("Quantize", selection: $quantize) {
                Text("None").tag(0)
                Text("3-bit").tag(3)
                Text("4-bit").tag(4)
                Text("5-bit").tag(5)
                Text("6-bit").tag(6)
                Text("8-bit").tag(8)
            }
            Toggle("Low RAM (--low-ram)", isOn: $lowRam)
        }
        LoraSectionView(loras: $loras)
    }
}
