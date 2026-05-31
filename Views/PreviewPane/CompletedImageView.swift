import SwiftUI

struct CompletedImageView: View {
    let job: FluxJob
    let onRemix: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void

    @State private var image: NSImage? = nil
    @State private var showingMetadata: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Image
            ZStack {
                Color.black.opacity(0.05)
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()

            // Metadata bar
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    seedChip
                    modelChip
                    dimsChip
                    Spacer()
                    actionButtons
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 16)
        }
        .onAppear { loadImage() }
        .onChange(of: job.outputPath) { _, _ in loadImage() }
    }

    private var seedChip: some View {
        Group {
            if let seed = job.resolvedSeed {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(seed)", forType: .string)
                } label: {
                    Label("\(seed)", systemImage: "dice")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Seed: \(seed) — click to copy")
            }
        }
    }

    private var modelChip: some View {
        Text(job.model == .custom ? "Custom" : job.model.displayName)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.1), in: Capsule())
    }

    private var dimsChip: some View {
        Text("\(job.width)×\(job.height)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.1), in: Capsule())
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if let path = job.outputPath, let meta = MetadataSidecar.read(for: path) {
                Button("Remix") { onRemix(meta) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button {
                    onUseInImg2Img(path)
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Use as img2img input")
            }

            if let path = job.outputPath {
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")
            }
        }
    }

    private func loadImage() {
        guard let path = job.outputPath else { return }
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOfFile: path)
            await MainActor.run { image = img }
        }
    }
}
