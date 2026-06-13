import SwiftUI

struct GalleryItemView: View, Equatable {
    let item: GalleryItem
    let isSelected: Bool
    let isInMultiSelection: Bool
    var hasAnySelection: Bool = false
    let onSelect: () -> Void
    let onMultiToggle: () -> Void
    let onRangeSelect: () -> Void
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    let onMoveToBoard: (String) -> Void
    let onDelete: () -> Void
    @Environment(GalleryStore.self) private var gallery

    var body: some View {
        Button {
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                onRangeSelect()
            } else if flags.contains(.command) {
                onMultiToggle()
            } else {
                onSelect()
            }
        } label: {
            ZStack(alignment: .bottom) {
                thumbnailView
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
            .overlay {
                let dimmed = hasAnySelection && !isSelected && !isInMultiSelection
                Color.black.opacity(dimmed ? 0.45 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .allowsHitTesting(false)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor)
                    .blur(radius: 8)
                    .opacity(isSelected ? 0.7 : 0)
                    .padding(-3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected || isInMultiSelection ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topLeading) {
                if isInMultiSelection {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .font(.body)
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu }
        .onAppear { gallery.loadThumbnail(for: item) }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let img = item.thumbnailImage {
            Image(nsImage: img)
                .resizable()
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // Intentionally ignores closure props — they capture reference types by reference so
    // semantically-identical closures from different parent renders behave the same.
    // Compares thumbnailImage presence so re-render fires when the image first loads.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id &&
        (lhs.item.thumbnailImage == nil) == (rhs.item.thumbnailImage == nil) &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isInMultiSelection == rhs.isInMultiSelection &&
        lhs.hasAnySelection == rhs.hasAnySelection
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copy Image") {
            guard let img = NSImage(contentsOfFile: item.path) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([img])
        }

        if let meta = item.metadata {
            Button("Remix (new seed)") { onRemix(meta) }
            Button("Apply Settings") {
                var corrected = meta
                corrected.board = item.board == "Default" ? nil : item.board
                onApplySettings(corrected)
            }
            Button("Use as Img2Img input") { onUseInImg2Img(item.path) }
            Divider()
        }

        Menu("Move to Group") {
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
