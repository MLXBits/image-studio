import AppKit
import SwiftUI

/// Reads the true pixel dimensions (not point size) of the image at `path`.
private func seedVR2PixelSize(ofImageAt path: String) -> CGSize? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return CGSize(width: w, height: h)
}

/// Sheet for configuring a SeedVR2 upscale of one or more existing images. SeedVR2
/// is prompt-free super-resolution, so the only inputs are scale factor, softness,
/// model size (3B/7B), and quantize. Presented from the "Upscale…" action in the
/// preview pane / gallery detail; a gallery multi-selection passes every selected
/// image, and the chosen settings apply to all of them. On confirm it hands the
/// fully-built ``SeedVR2Job``s back to ``ContentView`` for enqueueing and remembers
/// the choices as defaults.
struct SeedVR2UpscaleSheet: View {
    /// One image to upscale, paired with the gallery board its result should land in.
    struct Source: Identifiable {
        let id = UUID()
        let path: String
        let board: String
    }

    let sources: [Source]
    let settings: AppSettings
    let onConfirm: ([SeedVR2Job]) -> Void
    let onCancel: () -> Void

    @State private var scale: Int
    @State private var softness: Double
    @State private var is7B: Bool
    @State private var quantize: Int
    /// -1 = random seed each run; otherwise a fixed integer seed (matches the
    /// generation param forms' seed convention).
    @State private var seed: Int = -1
    @State private var sourceSize: CGSize?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upscale with SeedVR2").font(.headline)
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                scaleRow
                softnessRow
                modelRow
                quantizeRow
                seedRow
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isBatch ? "Upscale \(sources.count)" : "Upscale") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 440)
        .onAppear(perform: loadSourceSize)
    }

    // MARK: - Rows

    private var scaleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scale").font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(resultDimsLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: $scale) {
                Text("2×").tag(2)
                Text("3×").tag(3)
                Text("4×").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var softnessRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Softness").font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(String(format: "%.2f", softness))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $softness, in: 0 ... 1, step: 0.05)
            Text("0 keeps maximum detail; higher values smooth noise and artifacts.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.subheadline).fontWeight(.medium)
            Picker("", selection: $is7B) {
                Text("3B — fast").tag(false)
                Text("7B — quality").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var quantizeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quantize").font(.subheadline).fontWeight(.medium)
            Picker("", selection: $quantize) {
                Text("None").tag(0)
                Text("8-bit").tag(8)
                Text("4-bit").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var seedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text("Seed").font(.subheadline).fontWeight(.medium)
                InfoButton(
                    title: "Random Seed",
                    description: "The same seed + input image produces the same upscale every time."
                        + " Use -1 for a unique result each run."
                )
            }
            HStack(spacing: 4) {
                TextField("-1", value: $seed, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 100)
                    .accessibilityLabel("Seed")
                    .accessibilityHint("Use -1 for random")
                Button {
                    seed = Int.random(in: 0 ..< 1_000_000_000)
                } label: {
                    Image(systemName: "dice").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pick random seed")
                Button {
                    seed = -1
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset to random (-1)")
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private var isBatch: Bool {
        sources.count > 1
    }

    /// Header subtitle: the single filename, or a count for a multi-selection.
    private var subtitle: String {
        if isBatch { return "\(sources.count) images" }
        return (sources.first?.path as NSString?)?.lastPathComponent ?? ""
    }

    private var resultDimsLabel: String {
        // Per-image dimensions vary across a batch, so only preview them for a
        // single source; a batch just notes how many images will be upscaled.
        if isBatch { return "\(sources.count) images" }
        guard let size = sourceSize else { return "" }
        let w = Int(size.width) * scale
        let h = Int(size.height) * scale
        return "\(Int(size.width))×\(Int(size.height)) → \(w)×\(h)"
    }

    init(
        sources: [Source],
        settings: AppSettings,
        onConfirm: @escaping ([SeedVR2Job]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sources = sources
        self.settings = settings
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _scale = State(initialValue: [2, 3, 4].contains(settings.seedVR2Scale) ? settings.seedVR2Scale : 2)
        _softness = State(initialValue: settings.seedVR2Softness)
        _is7B = State(initialValue: settings.seedVR2Use7B)
        _quantize = State(initialValue: settings.seedVR2Quantize)
    }

    private func loadSourceSize() {
        // Only the single-image case shows source→result dimensions in the header.
        guard !isBatch, let path = sources.first?.path else { return }
        Task.detached(priority: .userInitiated) {
            let size = seedVR2PixelSize(ofImageAt: path)
            await MainActor.run { sourceSize = size }
        }
    }

    private func confirm() {
        // Remember the choices as defaults for next time.
        settings.seedVR2Scale = scale
        settings.seedVR2Softness = softness
        settings.seedVR2Use7B = is7B
        settings.seedVR2Quantize = quantize

        // One job per source, all sharing the chosen settings. A fixed seed applies
        // to every image; seed -1 lets the runner pick a fresh random seed per job.
        let jobs = sources.map { source -> SeedVR2Job in
            let size = seedVR2PixelSize(ofImageAt: source.path)
            let outW = size.map { Int($0.width) * scale } ?? 0
            let outH = size.map { Int($0.height) * scale } ?? 0
            return SeedVR2Job(
                sourcePath: source.path,
                scale: scale,
                softness: softness,
                is7B: is7B,
                quantize: quantize,
                seed: seed,
                board: source.board,
                width: outW,
                height: outH
            )
        }
        onConfirm(jobs)
    }
}
