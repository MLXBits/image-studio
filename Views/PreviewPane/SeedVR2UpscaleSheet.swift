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

/// Sheet for configuring a SeedVR2 upscale of an existing image. SeedVR2 is
/// prompt-free super-resolution, so the only inputs are scale factor, softness,
/// model size (3B/7B), and quantize. Presented from the "Upscale…" action in the
/// preview pane / gallery detail. On confirm it hands a fully-built ``SeedVR2Job``
/// back to ``ContentView`` for enqueueing and remembers the choices as defaults.
struct SeedVR2UpscaleSheet: View {
    let sourcePath: String
    let board: String
    let settings: AppSettings
    let onConfirm: (SeedVR2Job) -> Void
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
                    Text((sourcePath as NSString).lastPathComponent)
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
                Button("Upscale") { confirm() }
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

    private var resultDimsLabel: String {
        guard let size = sourceSize else { return "" }
        let w = Int(size.width) * scale
        let h = Int(size.height) * scale
        return "\(Int(size.width))×\(Int(size.height)) → \(w)×\(h)"
    }

    init(
        sourcePath: String,
        board: String,
        settings: AppSettings,
        onConfirm: @escaping (SeedVR2Job) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sourcePath = sourcePath
        self.board = board
        self.settings = settings
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _scale = State(initialValue: [2, 3, 4].contains(settings.seedVR2Scale) ? settings.seedVR2Scale : 2)
        _softness = State(initialValue: settings.seedVR2Softness)
        _is7B = State(initialValue: settings.seedVR2Use7B)
        _quantize = State(initialValue: settings.seedVR2Quantize)
    }

    private func loadSourceSize() {
        let path = sourcePath
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

        // seed of -1 = random; the runner resolves it to a fresh random seed.
        let outW = sourceSize.map { Int($0.width) * scale } ?? 0
        let outH = sourceSize.map { Int($0.height) * scale } ?? 0
        let job = SeedVR2Job(
            sourcePath: sourcePath,
            scale: scale,
            softness: softness,
            is7B: is7B,
            quantize: quantize,
            seed: seed,
            board: board,
            width: outW,
            height: outH
        )
        onConfirm(job)
    }
}
