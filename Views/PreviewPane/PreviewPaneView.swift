import SwiftUI

enum PreviewState {
    case idle
    case activeJob(FluxJob)
    case galleryItem(GalleryItem)
}

struct PreviewPaneView: View {
    @Environment(FluxJobRunner.self) private var runner

    let state: PreviewState
    let onRemix: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                idleView

            case .activeJob(let job):
                switch job.status {
                case .running:
                    StepwisePreviewView(job: job, onCancel: onCancel)
                case .completed:
                    CompletedImageView(
                        job: job,
                        onRemix: onRemix,
                        onUseInImg2Img: onUseInImg2Img
                    )
                case .failed(let msg):
                    failedView(message: msg)
                case .cancelled:
                    cancelledView
                case .pending:
                    pendingView(job: job)
                }

            case .galleryItem(let item):
                GalleryItemDetailView(
                    item: item,
                    onRemix: { meta in onRemix(meta) },
                    onUseInImg2Img: onUseInImg2Img
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Ready to generate")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Write a prompt and press ⌘↵")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Generation failed")
                .font(.title3)
            ScrollView {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding()
            }
            .frame(maxHeight: 120)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }

    private var cancelledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "stop.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Cancelled")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func pendingView(job: FluxJob) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Waiting in queue")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(job.displayName)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Gallery item detail (in center pane)

private struct GalleryItemDetailView: View {
    let item: GalleryItem
    let onRemix: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void

    @State private var image: NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {
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

            HStack(spacing: 8) {
                if let meta = item.metadata {
                    metaChip("\(meta.width)×\(meta.height)")
                    metaChip(meta.model.displayName)
                    metaChip("seed \(meta.seed)")
                    Spacer()
                    Button("Remix") { onRemix(meta) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button {
                        onUseInImg2Img(item.path)
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Use as img2img input")
                } else {
                    Text(item.filename).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }

                Button {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .onAppear { loadImage() }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.1), in: Capsule())
    }

    private func loadImage() {
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: item.url)
            await MainActor.run { image = img }
        }
    }
}
