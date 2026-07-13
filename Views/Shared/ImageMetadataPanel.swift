import SwiftUI

private enum PromptFullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum PromptLimitedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ImageMetadataInfo {
    var prompt: String
    var negativePrompt: String
    var modelName: String
    var seed: Int?
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Double
    var loras: [LoraEntry]
    var filePath: String?
    var log: String?
    var generationTime: String?
    /// Optional qualifier appended to the resolution field, e.g. "from 1024×1024"
    /// for a SeedVR2 upscale so the original (pre-upscale) size stays visible.
    var resolutionNote: String?

    /// Resolution string shown in the grid, with the optional source-size note.
    var resolutionText: String {
        if let note = resolutionNote { return "\(width)×\(height) (\(note))" }
        return "\(width)×\(height)"
    }

    init(job: FluxJob) {
        prompt = job.prompt
        negativePrompt = job.negativePrompt
        modelName = job.model == .custom ? "Custom" : job.model.displayName
        seed = job.resolvedSeed
        width = job.width
        height = job.height
        steps = job.steps
        guidance = job.guidance
        loras = job.loras
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        if job.seeds.isEmpty, let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init?(item: GalleryItem) {
        guard let meta = item.metadata else { return nil }
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt
        modelName = meta.model == .custom ? "Custom" : meta.model.displayName
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        loras = meta.loras
        filePath = item.path
        log = meta.log
        if let started = meta.startedAt {
            let secs = Int(meta.generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init(ideogram4Job job: Ideogram4Job) {
        prompt = job.usePlainPrompt ? job.plainPrompt : job.caption.highLevelDescription
        negativePrompt = ""
        modelName = "Ideogram 4"
        seed = job.resolvedSeed ?? job.seed
        width = job.width
        height = job.height
        steps = job.preset.stepCount
        guidance = 1.0
        loras = job.loras
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        if let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init(ideogram4Item: GalleryItem) {
        let meta = ideogram4Item.ideogram4Metadata
        if meta?.usePlainPrompt == true {
            prompt = meta?.plainPrompt ?? ""
        } else {
            prompt = meta?.caption.highLevelDescription ?? ""
        }
        negativePrompt = ""
        modelName = "Ideogram 4"
        seed = meta?.seed
        width = meta?.width ?? 0
        height = meta?.height ?? 0
        steps = meta?.preset.stepCount ?? 0
        guidance = 1.0
        loras = meta?.loras ?? []
        filePath = ideogram4Item.path
        log = meta?.log
        if let started = meta?.startedAt, let generatedAt = meta?.generatedAt {
            let secs = Int(generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        } else {
            generationTime = nil
        }
    }

    init(krea2Job job: Krea2Job) {
        prompt = job.prompt
        negativePrompt = job.guidance != 1.0 ? job.negativePrompt : ""
        modelName = "Krea 2 Turbo"
        seed = job.resolvedSeed ?? job.seed
        width = job.width
        height = job.height
        steps = job.steps
        guidance = job.guidance
        loras = job.loras
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        if job.seeds.isEmpty, let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init?(krea2Item: GalleryItem) {
        guard let meta = krea2Item.krea2Metadata else { return nil }
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
        modelName = "Krea 2 Turbo"
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        loras = meta.loras ?? []
        filePath = krea2Item.path
        log = meta.log
        if let started = meta.startedAt {
            let secs = Int(meta.generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init?(seedVR2Item: GalleryItem) {
        guard let meta = seedVR2Item.seedVR2Metadata else { return nil }
        let modelLabel = meta.model == "seedvr2-7b" ? "SeedVR2 7B" : "SeedVR2 3B"
        let upscaleLabel = "\(modelLabel) · \(meta.scale)×"
        width = meta.width
        height = meta.height
        filePath = seedVR2Item.path
        log = meta.log
        // Source-forward: surface the original prompt/loras/recipe (it's the same
        // image, just larger) with the upscale noted in the model line.
        let source = SeedVR2Source(
            flux: meta.sourceFlux, ideogram4: meta.sourceIdeogram4, krea2: meta.sourceKrea2
        )
        if let src = SeedVR2DisplayFields(source: source) {
            prompt = src.prompt
            negativePrompt = src.negativePrompt
            modelName = "\(upscaleLabel) ← \(src.sourceModel)"
            seed = src.seed
            steps = src.steps
            guidance = src.guidance
            loras = src.loras
            resolutionNote = "from \(src.width)×\(src.height)"
        } else {
            // Pre-inheritance sidecar (or a source that carried none): show the
            // upscale parameters directly, as before.
            prompt = "Upscale \(meta.scale)× · softness \(String(format: "%.2f", meta.softness))"
            negativePrompt = ""
            modelName = modelLabel
            seed = meta.seed
            steps = 0
            guidance = 1.0
            loras = []
        }
        if let started = meta.startedAt {
            let secs = Int(meta.generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        } else {
            generationTime = nil
        }
    }

    init(seedVR2Job job: SeedVR2Job) {
        let upscaleLabel = "\(job.modelLabel) · \(job.scale)×"
        width = job.width
        height = job.height
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        let source = SeedVR2Metadata.resolveSource(for: job.sourcePath)
        if let src = SeedVR2DisplayFields(source: source) {
            prompt = src.prompt
            negativePrompt = src.negativePrompt
            modelName = "\(upscaleLabel) ← \(src.sourceModel)"
            seed = src.seed
            steps = src.steps
            guidance = src.guidance
            loras = src.loras
            resolutionNote = "from \(src.width)×\(src.height)"
        } else {
            prompt = "Upscale \(job.scale)× · softness \(String(format: "%.2f", job.softness))"
            negativePrompt = ""
            modelName = job.modelLabel
            seed = job.resolvedSeed ?? job.seed
            steps = 0
            guidance = 1.0
            loras = []
        }
        if let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init(path: String) {
        prompt = ""; negativePrompt = ""; modelName = "Unknown"
        seed = nil; width = 0; height = 0; steps = 0; guidance = 1.0; loras = []
        filePath = path; log = nil; generationTime = nil
    }
}

struct ImageMetadataPanel: View {
    let info: ImageMetadataInfo
    let onApplySettings: (() -> Void)?
    let onRemix: (() -> Void)?
    let onUseInImg2Img: (() -> Void)?
    var onEditBoxes: (() -> Void)?
    let onRevealInFinder: (() -> Void)?
    let onShowLog: (() -> Void)?
    var onUpscale: (() -> Void)?

    @State private var promptExpanded = false
    @State private var promptFullHeight: CGFloat = 0
    @State private var promptLimitedHeight: CGFloat = 0
    private var isPromptTruncated: Bool {
        promptFullHeight > promptLimitedHeight + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptRow
            Divider()
            metadataGrid
            Divider()
            footerRow
        }
        .onChange(of: info.prompt) { promptExpanded = false }
    }

    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text("Prompt")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .leading)
                Text(info.prompt.isEmpty ? "–" : info.prompt)
                    .font(.caption)
                    .lineLimit(promptExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .preference(key: PromptLimitedHeightKey.self, value: g.size.height)
                                .overlay(alignment: .topLeading) {
                                    Text(info.prompt)
                                        .font(.caption)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .hidden()
                                        .background(GeometryReader { g2 in
                                            Color.clear.preference(key: PromptFullHeightKey.self, value: g2.size.height)
                                        })
                                }
                        }
                    )
                    .onPreferenceChange(PromptLimitedHeightKey.self) { promptLimitedHeight = $0 }
                    .onPreferenceChange(PromptFullHeightKey.self) { promptFullHeight = $0 }
                    .overlay {
                        // Intercept taps when collapsed so clicking the text triggers Show More
                        // instead of the native textSelection focus expanding the view.
                        if !promptExpanded && isPromptTruncated {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { promptExpanded = true }
                        }
                    }
                Spacer(minLength: 0)
            }
            if !info.prompt.isEmpty && (isPromptTruncated || promptExpanded) {
                HStack {
                    Spacer()
                    Button(promptExpanded ? "Show less" : "Show more") {
                        promptExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 32) {
                metaField("Model", info.modelName)
                metaField("Resolution", info.resolutionText)
            }
            HStack(alignment: .center, spacing: 32) {
                seedField
                metaField("Steps", "\(info.steps)")
                if info.guidance != 1.0 {
                    metaField("Guidance", String(format: "%.2f", info.guidance))
                }
                if let t = info.generationTime {
                    metaField("Time", t)
                }
            }
            if !enabledLoras.isEmpty {
                loraField
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if let path = info.filePath {
                Text((path as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let fn = onApplySettings {
                Button("Apply Settings") { fn() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Load all generation settings (including seed) without changing the prompt")
            }

            if let fn = onRemix {
                Button("Remix") { fn() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Re-generate this image with a new, random seed.")
            }

            if let fn = onUseInImg2Img {
                Button { fn() } label: { Image(systemName: "photo.on.rectangle.angled") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Use as img2img input")
            }
            if let fn = onEditBoxes {
                Button { fn() } label: { Image(systemName: "square.dashed") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Adjust the bounding boxes over this image. Loads the boxes into "
                        + "the form; fix the seed (or Apply Settings) to re-render this same image.")
            }
            if let path = info.filePath {
                Button {
                    guard let img = NSImage(contentsOfFile: path) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Copy image to clipboard")
            }
            if let fn = onUpscale {
                Button { fn() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Upscale with SeedVR2")
            }
            if let fn = onRevealInFinder {
                Button { fn() } label: { Image(systemName: "folder") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Reveal in Finder")
            }
            if let fn = onShowLog {
                Button { fn() } label: { Image(systemName: "text.alignleft") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Show generation log")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var enabledLoras: [LoraEntry] {
        info.loras.filter { $0.enabled && $0.isValid }
    }

    private var seedField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Seed")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let seed = info.seed {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(seed)", forType: .string)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "dice").font(.caption2)
                        Text("\(seed)").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Click to copy seed")
            } else {
                Text("–").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var loraField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("LoRAs")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(enabledLoras
                .map { "\($0.displayName) (\(String(format: "%.2f", $0.strength)))" }
                .joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func metaField(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }
}
