import SwiftUI

struct GalleryItemView: View {
    let item: GalleryItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemix: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    let onMoveToBoard: (String) -> Void
    let onDelete: () -> Void
    @Environment(GalleryStore.self) private var gallery

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottom) {
                thumbnailImage
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()

                if item.metadata != nil {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.4)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(height: 36)
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu }
        .onAppear { gallery.loadThumbnail(for: item) }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let data = item.thumbnailData, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let meta = item.metadata {
            Button("Remix (new seed)") { onRemix(meta) }
            Button("Use as Img2Img input") { onUseInImg2Img(item.path) }
            Divider()
        }

        Menu("Move to Board") {
            Button("Default") { onMoveToBoard("Default") }
            if !gallery.boards.isEmpty {
                Divider()
                ForEach(gallery.boards.filter { $0 != "Default" && $0 != item.board }, id: \.self) { board in
                    Button(board) { onMoveToBoard(board) }
                }
            }
        }

        Divider()

        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        }

        Button("Delete", role: .destructive) { onDelete() }
    }
}
