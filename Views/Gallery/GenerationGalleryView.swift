import SwiftUI

struct GenerationGalleryView: View {
    @Environment(GalleryStore.self) private var gallery
    @Environment(AppSettings.self) private var settings

    @Binding var selectedItem: GalleryItem?
    let onRemix: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void

    @State private var deleteTarget: GalleryItem? = nil
    @State private var showingDeleteConfirm: Bool = false

    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 4)
    ]

    var body: some View {
        VStack(spacing: 0) {
            boardPicker
                .padding(.horizontal, 8)
                .padding(.top, 8)

            Divider()
                .padding(.vertical, 4)

            if gallery.displayedItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(gallery.displayedItems) { item in
                            GalleryItemView(
                                item: item,
                                isSelected: selectedItem?.id == item.id,
                                onSelect: { selectedItem = item },
                                onRemix: onRemix,
                                onUseInImg2Img: onUseInImg2Img,
                                onMoveToBoard: { board in
                                    gallery.moveItem(item, toBoard: board, outputDir: settings.outputDir)
                                },
                                onDelete: {
                                    deleteTarget = item
                                    showingDeleteConfirm = true
                                }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .confirmationDialog(
            "Delete image?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = deleteTarget {
                    if selectedItem?.id == item.id { selectedItem = nil }
                    gallery.delete(item, outputDir: settings.outputDir)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This will permanently delete the image and its sidecar file.")
        }
    }

    private var boardPicker: some View {
        @Bindable var g = gallery
        return HStack(spacing: 4) {
            boardButton("All")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(gallery.boards, id: \.self) { board in
                        boardButton(board)
                    }
                }
            }
        }
    }

    private func boardButton(_ board: String) -> some View {
        @Bindable var g = gallery
        return Button(board) {
            g.selectedBoard = board
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .foregroundStyle(gallery.selectedBoard == board ? .primary : .secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(gallery.selectedBoard == "All" ? "No images yet" : "No images in \(gallery.selectedBoard)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
