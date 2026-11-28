import AppKit
import SwiftUI

struct GalleryItemDetailView: View {
    let item: GalleryItem
    /// Remix or Apply Settings, for an image of any family.
    let onReplay: (AnySidecar, ReplayMode) -> Void
    /// The active family's source-image item, or nil when it has no source input.
    let sourceImage: SourceImageAction?
    var onEditBoxesOverImage: ((Ideogram4Metadata, NSImage) -> Void)?
    var onShowFullSize: ((NSImage) -> Void)?
    var onSetFlag: ((PickFlag?) -> Void)?
    var onSetRating: ((Int) -> Void)?
    var onUpscale: ((String) -> Void)?

    @State private var image: NSImage?
    @State private var showingLog: Bool = false

    /// Whether the context menu has a replay, source-image or box item, so its
    /// divider never sits next to the Upscale group's own.
    private var hasImageActions: Bool {
        if case .ideogram4 = item.sidecar, image != nil {
            return true
        }
        return item.replaySidecar != nil || sourceImage != nil
    }

    var body: some View {
        let info = ImageMetadataInfo(galleryItem: item)
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.05)
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()
            .onTapGesture(count: 2) {
                if let img = image {
                    onShowFullSize?(img)
                }
            }
            .contextMenu {
                Button("Copy Image") { ImagePasteboard.copyImages(atPaths: [item.path]) }
                if hasImageActions {
                    Divider()
                }
                if let sidecar = item.replaySidecar {
                    Button("Apply Settings") { onReplay(sidecar, .applySettings) }
                    Button("Remix (new seed)") { onReplay(sidecar, .remix) }
                }
                if let sourceImage {
                    Button(sourceImage.input.title) { sourceImage.use(item.path) }
                }
                if case let .ideogram4(meta) = item.sidecar, let img = image {
                    Button("Adjust Boxes…") { onEditBoxesOverImage?(meta, img) }
                }
                if let onUpscale {
                    Divider()
                    Button("Upscale…") { onUpscale(item.path) }
                }
                if info.log != nil {
                    Divider()
                    Button("Show Log") { showingLog = true }
                }
                Divider()
                CopyPathMenu(path: item.path)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                }
            }

            if onSetFlag != nil || onSetRating != nil {
                cullControlRow
                Divider()
            }

            ImageMetadataPanel(
                info: info,
                onApplySettings: replay(.applySettings),
                onRemix: replay(.remix),
                sourceImage: sourceImage,
                onEditBoxes: editBoxesAction,
                onRevealInFinder: {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                },
                onShowLog: info.log != nil ? { showingLog = true } : nil,
                onUpscale: onUpscale.map { fn in { fn(item.path) } }
            )
        }
        .onAppear { loadImage() }
        .onChange(of: item.id) { _, _ in loadImage() }
        .sheet(isPresented: $showingLog) { logSheet(log: info.log ?? "") }
    }

    /// Interactive cull row — pick/reject toggles and 0–5 stars, mirroring the
    /// keyboard shortcuts for mouse users. Clicking the current top star clears down
    /// one; clicking an active flag clears it.
    private var cullControlRow: some View {
        HStack(spacing: 8) {
            Button { onSetFlag?(item.flag == .pick ? nil : .pick) } label: {
                Image(systemName: item.flag == .pick ? "flag.fill" : "flag")
                    .foregroundStyle(item.flag == .pick ? .green : .secondary)
            }
            .buttonStyle(.iconButton).help("Pick (P)")
            .accessibilityLabel("Pick")

            Button { onSetFlag?(item.flag == .reject ? nil : .reject) } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(item.flag == .reject ? .red : .secondary)
            }
            .buttonStyle(.iconButton).help("Reject (X)")
            .accessibilityLabel("Reject")

            Divider().frame(height: 14)

            // Compact and abutting: five 22pt frames give a wider pitch than the old
            // ~13pt glyphs at spacing 3, without stretching the row to 5 × 28pt.
            HStack(spacing: 0) {
                ForEach(1 ... 5, id: \.self) { star in
                    Button { onSetRating?(item.rating == star ? star - 1 : star) } label: {
                        Image(systemName: star <= item.rating ? "star.fill" : "star")
                            .foregroundStyle(star <= item.rating ? .yellow : .secondary)
                    }
                    .buttonStyle(.iconButtonCompact).help("Rate \(star)")
                    .accessibilityLabel("Rate \(star)")
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 2)
    }

    /// "Adjust Boxes" closure — available only for Ideogram images once the image
    /// has loaded, so the boxes can be overlaid on it.
    private var editBoxesAction: (() -> Void)? {
        guard case let .ideogram4(meta) = item.sidecar, let img = image else { return nil }
        return { onEditBoxesOverImage?(meta, img) }
    }

    /// A `mode` replay of this image's settings, when it has some to replay.
    private func replay(_ mode: ReplayMode) -> (() -> Void)? {
        guard let sidecar = item.replaySidecar else { return nil }
        return { onReplay(sidecar, mode) }
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
