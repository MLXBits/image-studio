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
    let onRevealInFinder: (() -> Void)?
    let onShowLog: (() -> Void)?

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
                metaField("Resolution", "\(info.width)×\(info.height)")
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
                metaField("LoRAs", enabledLoras.map(\.displayName).joined(separator: ", "))
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
            if let path = info.filePath {
                Button {
                    guard let img = NSImage(contentsOfFile: path) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Copy image to clipboard")
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
