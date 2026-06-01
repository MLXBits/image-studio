import SwiftUI

struct CompletedImageView: View {
    let job: FluxJob
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    var onShowFullSize: ((NSImage) -> Void)? = nil

    @State private var image: NSImage? = nil
    @State private var showingLog: Bool = false

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
            .onTapGesture(count: 2) {
                if let img = image { onShowFullSize?(img) }
            }
            .contextMenu {
                if let path = job.outputPath {
                    Button("Copy Image") {
                        guard let img = NSImage(contentsOfFile: path) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([img])
                    }
                }
                if let meta = remixMeta {
                    Divider()
                    Button("Remix (new seed)") { onRemix(meta) }
                    Button("Apply Settings") { onApplySettings(meta) }
                }
                if let path = job.outputPath {
                    Button("Use as Img2Img Input") { onUseInImg2Img(path) }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
                Button("Show Log") { showingLog = true }
            }

            ImageMetadataPanel(
                info: ImageMetadataInfo(job: job),
                onRemix: remixMeta.map { meta in { onRemix(meta) } },
                onApplySettings: remixMeta.map { meta in { onApplySettings(meta) } },
                onUseInImg2Img: job.outputPath.map { path in { onUseInImg2Img(path) } },
                onRevealInFinder: job.outputPath.map { path in {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }},
                onShowLog: { showingLog = true }
            )
        }
        .onAppear { loadImage() }
        .onChange(of: job.outputPath) { _, _ in loadImage() }
        .sheet(isPresented: $showingLog) { logSheet }
    }

    private var remixMeta: GenerationMetadata? {
        guard let path = job.outputPath else { return nil }
        return MetadataSidecar.read(for: path)
    }

    private var logSheet: some View {
        NavigationStack {
            ScrollView {
                Text(job.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Generation Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingLog = false }
                }
            }
        }
        .frame(width: 640, height: 480)
    }

    private func loadImage() {
        guard let path = job.outputPath else { return }
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOfFile: path)
            await MainActor.run { image = img }
        }
    }
}
