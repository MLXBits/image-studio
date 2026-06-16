import AppKit
import SwiftUI

struct GalleryItemDetailView: View {
    let item: GalleryItem
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    var onShowFullSize: ((NSImage) -> Void)?

    @State private var image: NSImage?
    @State private var showingLog: Bool = false

    var body: some View {
        let info = item.ideogram4Metadata != nil
            ? ImageMetadataInfo(ideogram4Item: item)
            : (ImageMetadataInfo(item: item) ?? ImageMetadataInfo(path: item.path))
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
                Button("Copy Image") {
                    guard let img = NSImage(contentsOfFile: item.path) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                }
                if let meta = item.metadata {
                    Divider()
                    Button("Apply Settings") {
                        var corrected = meta
                        corrected.board = item.board == "Default" ? nil : item.board
                        onApplySettings(corrected)
                    }
                    Button("Remix (new seed)") { onRemix(meta) }
                    Button("Use as Img2Img Input") { onUseInImg2Img(item.path) }
                }
                if info.log != nil {
                    Divider()
                    Button("Show Log") { showingLog = true }
                }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                }
            }

            ImageMetadataPanel(
                info: info,
                onApplySettings: item.metadata.map { meta in {
                    var corrected = meta
                    corrected.board = item.board == "Default" ? nil : item.board
                    onApplySettings(corrected)
                }
                }, onRemix: item.metadata.map { meta in { onRemix(meta) } },
                onUseInImg2Img: item.ideogram4Metadata == nil ? { onUseInImg2Img(item.path) } : nil,
                onRevealInFinder: {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                },
                onShowLog: info.log != nil ? { showingLog = true } : nil
            )
        }
        .onAppear { loadImage() }
        .onChange(of: item.id) { _, _ in loadImage() }
        .sheet(isPresented: $showingLog) { logSheet(log: info.log ?? "") }
    }

    private func logSheet(log: String) -> some View {
        NavigationStack {
            ScrollView {
                Text(log)
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
        image = nil
        let url = item.url
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { image = img }
        }
    }
}
