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
    @State private var settingsCopied = false
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
        HStack(alignment: .top, spacing: 8) {
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
            Spacer(minLength: 0)
            copySettingsButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var copySettingsButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(settingsSummary, forType: .string)
            settingsCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                settingsCopied = false
            }
        } label: {
            Image(systemName: settingsCopied ? "checkmark" : "list.clipboard")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Copy these settings (everything but the prompt) to the clipboard")
    }

    /// The metadata grid rendered as plain text, one `Label: value` per line.
    private var settingsSummary: String {
        var lines = [
            "Model: \(info.modelName)",
            "Resolution: \(info.resolutionText)",
            "Seed: \(info.seed.map(String.init) ?? "–")",
            "Steps: \(info.steps)",
        ]
        if info.guidance != 1.0 {
            lines.append("Guidance: \(String(format: "%.2f", info.guidance))")
        }
        if let t = info.generationTime {
            lines.append("Time: \(t)")
        }
        if !enabledLoras.isEmpty {
            lines.append("LoRAs: \(loraSummary)")
        }
        return lines.joined(separator: "\n")
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

    private var loraSummary: String {
        enabledLoras
            .map { "\($0.displayName) (\(String(format: "%.2f", $0.strength)))" }
            .joined(separator: ", ")
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
            Text(loraSummary)
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
